import AppKit
import QuartzCore

/// The screensaver's picture, used by both the preview app and the `.saver`.
///
/// Layout on a wide screen (`layout()`):
/// ```
/// ┌──────────────┬──────────────────┐
/// │              │  magnified map   │  ← framed around the home stations
/// │  full map    │  (zoomPanel)     │
/// │ (fullPanel)  │                  │
/// │  dashed box  ├──────────────────┤
/// │  = zoom area │  next trains     │  ← as tall as its content; tram button = home-station picker
/// └──────────────┴──────────────────┘     (preview app only)
/// ```
/// On a narrow view only the full map is shown.
///
/// Close-up layout (`SubwaySettings.Layout.closeUp`):
/// ```
/// ┌──────────────────────────────────┐
/// │                       ┌────────┐ │
/// │   one section of the  │overview│ │  ← the whole map, outlining the section shown
/// │   map at a readable   └────────┘ │
/// │   zoom (zoomPanel)               │
/// │ ┌─────────────┐                  │
/// │ │ next trains │                  │
/// │ └─────────────┘                  │
/// └──────────────────────────────────┘
/// ```
///
/// Motion: once a second MotionPlanner checks every train against its predicted timetable and, when one
/// sets off, hands Core Animation the whole hop as a single glide along the track (on the graphics chip). The feeds are downloaded
/// every 30 s in the background, shared by all views (FeedHub; `start()` / `stop()`).
final class SubwayView: NSView {
    /// Where the bundled resources live: the app's bundle in the preview app, the `.saver` bundle in the
    /// screensaver. (`Bundle.main` would be macOS's screensaver host in the second case, not ours.)
    static let resources = Bundle(for: SubwayView.self)

    // ---- Settings ----
    /// Seconds between position updates (Core Animation fills in the motion in between).
    var tick: TimeInterval = 1.0
    /// For testing: feeds treated as failed in every round after the first ("all" = every feed).
    var simulatedOutage: Set<String> = []
    /// For testing: replay recorded history (the time-lapse) even while live data is available. Otherwise the
    /// time-lapse only takes over when live data is unavailable (every feed failing), as a backup.
    var forceTimeLapse = false {
        didSet { if tickTimer != nil { startTicking() } }
    }
    /// The magnified map is at least this many map units wide (a station circle is 8.2), for context.
    var zoomMinWidth: CGFloat = 300
    /// Show the status line (time, counts, data age, CPU): useful in the preview app; off in the screensaver.
    var showsStatus = false { didSet { statusLayer.isHidden = !showsStatus } }

    // ---- Parts ----
    let settings: SubwaySettings
    private let document: MapDocument?
    private let network: SubwayNetwork?
    private let locator: Locator?
    private let planner: MotionPlanner?
    /// What actually happened over the last half hour (recorded from every download), and its replay.
    private let history: TripHistory?
    private let timeLapse: TimeLapse?
    /// True while the time-lapse (not the live planner) is moving the dots.
    private var showingTimeLapse = false
    private var fullPanel: MapPanel?
    private var zoomPanel: MapPanel?
    private let nextTrains = NextTrainsView()
    private let statusLayer = CATextLayer()
    /// "Live data unavailable since …": shown only when every feed fails (also in the screensaver).
    private let offlineLayer = CATextLayer()
    /// "Time-lapse 20× (testing) · 2:41 PM": which moment a forced time-lapse is showing.
    private let modeLayer = CATextLayer()
    private var pickerButton: NSButton?

    // ---- Live state ----
    /// Each feed's last good download (see FeedCache): a feed that fails briefly keeps its trains on screen.
    private var feedCache: FeedCache?
    private var liveTrips: [Trip] = []
    private var fetchedAt: Double = 0
    private var tickTimer: Timer?
    /// This view's subscription to the shared downloads (FeedHub), while started.
    private var feedSubscription: UUID?
    /// Forces the pixel scale (for snapshots without a window); nil = use the screen's.
    private var forcedScale: CGFloat?
    private var cpuSample = (cpu: SubwayView.processCPUSeconds(), wall: CFAbsoluteTimeGetCurrent())

    /// - Parameters:
    ///   - settings: where home stations are stored.
    ///   - allowsInteraction: show the home-station picker button (the screensaver can't be clicked, so it's off there).
    init(frame: NSRect, settings: SubwaySettings = SubwaySettings(), allowsInteraction: Bool = false) {
        self.settings = settings
        document = SubwayView.resources.url(forResource: "map_black", withExtension: "pdf").flatMap(MapDocument.init)
        do {
            let net = try SubwayNetwork.loadBundled()
            network = net
            let loc = Locator(network: net)
            locator = loc
            planner = MotionPlanner(locator: loc)
            let lapse = TimeLapse(locator: loc)
            timeLapse = lapse
            history = TripHistory(platforms: net.platforms, keep: lapse.window + 120)
        } catch {
            NSLog("SubwayView: couldn't load network.json: %@", error.localizedDescription)
            network = nil
            locator = nil
            planner = nil
            timeLapse = nil
            history = nil
        }
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        if let document {
            let full = MapPanel(document: document), zoom = MapPanel(document: document)
            full.dotRange = 6...10  // base marker size in points (2...3 when it is the close-up's overview)
            zoom.dotRange = 8...14  // a little bigger when magnified
            if let units = network?.settings.trainDotUnits { full.dotUnits = units; zoom.dotUnits = units }
            layer?.insertSublayer(full.root, at: 0)  // below the subviews (next-train panel, button)
            layer?.insertSublayer(zoom.root, at: 1)
            fullPanel = full
            zoomPanel = zoom
        } else {
            NSLog("SubwayView: map_black.pdf not found in %@. Run the notebook's §8 export, then rebuild.",
                  SubwayView.resources.bundlePath)
        }
        if let network {
            nextTrains.routeColors = network.routes.mapValues { (NSColor(hex: $0.color), NSColor(hex: $0.textColor)) }
        }
        addSubview(nextTrains)

        statusLayer.fontSize = 11
        statusLayer.foregroundColor = NSColor.white.cgColor
        statusLayer.backgroundColor = NSColor(white: 0, alpha: 0.7).cgColor
        statusLayer.isHidden = true
        statusLayer.zPosition = 10
        layer?.addSublayer(statusLayer)

        for note in [offlineLayer, modeLayer] {  // small notes in the top-right corner
            note.fontSize = 12
            note.foregroundColor = NSColor(white: 0.8, alpha: 1).cgColor
            note.backgroundColor = NSColor(white: 0, alpha: 0.7).cgColor
            note.cornerRadius = 4
            note.alignmentMode = .center
            note.anchorPoint = CGPoint(x: 1, y: 1)  // positioned by its top-right corner
            note.isHidden = true
            note.zPosition = 10
            layer?.addSublayer(note)
        }

        if let network {
            feedCache = FeedCache(feeds: network.settings.feeds, keepFor: network.settings.staleAfterS)
        }

        if allowsInteraction { addPickerButton() }
    }

    required init?(coder: NSCoder) {
        fatalError("SubwayView is created in code only")
    }

    // ---- Start / stop (the screensaver calls these from startAnimation/stopAnimation) ----

    /// Starts receiving feed downloads (shared with any other SubwayView, see FeedHub) and moving trains.
    func start() {
        guard let network, feedSubscription == nil else { return }
        var round = 0
        feedSubscription = FeedHub.shared.subscribe(settings: network.settings) { [weak self] fresh, at in
            guard let self else { return }
            var fresh = fresh
            if round > 0, !self.simulatedOutage.isEmpty {
                fresh = fresh.filter { !self.simulatedOutage.contains($0.key) && !self.simulatedOutage.contains("all") }
            }
            round += 1
            self.receive(fresh, at: at)
            if self.tickTimer == nil { self.startTicking() }
        }
    }

    /// Takes in a download round: fresh feeds replace their old data, failed ones keep it for a while.
    private func receive(_ fresh: [String: [Trip]], at: Double) {
        guard var cache = feedCache else { return }
        cache.receive(fresh, at: at)
        feedCache = cache
        liveTrips = cache.trips
        fetchedAt = cache.lastSuccess ?? at
        if !fresh.isEmpty {  // a round where nothing downloaded tells us nothing about what happened
            history?.observe(cache.trips, at: at, downloaded: Set(fresh.keys))
        }
        if !cache.failed.isEmpty {
            NSLog("SubwayView: holding previous data for %@", cache.failed.joined(separator: ", "))
        }
        updateOfflineNote()
    }

    private func updateOfflineNote() {
        guard let cache = feedCache, cache.isOffline else {
            offlineLayer.isHidden = true
            return
        }
        if let since = cache.lastSuccess {
            let time = DateFormatter.localizedString(from: Date(timeIntervalSince1970: since), dateStyle: .none,
                                                     timeStyle: .short)
            offlineLayer.string = "Live data unavailable since \(time)"
        } else {
            offlineLayer.string = "Live data unavailable"
        }
        if showingTimeLapse, let timeLapse {
            offlineLayer.string = (offlineLayer.string as? String ?? "")
                + String(format: "  ·  replaying the last %.0f min", min(timeLapse.window, timeLapse.recorded(history!)) / 60)
        }
        offlineLayer.isHidden = false
        fitNote(offlineLayer)
    }

    /// Sizes a note to its text.
    private func fitNote(_ note: CATextLayer) {
        let text = NSAttributedString(string: note.string as? String ?? "",
                                      attributes: [.font: NSFont.systemFont(ofSize: note.fontSize)])
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        note.bounds = CGRect(x: 0, y: 0, width: ceil(text.size().width) + 14, height: note.fontSize + 6)
        CATransaction.commit()
    }

    /// Stops all work: no timers, no downloads (important for a screensaver: nothing may keep running).
    func stop() {
        if let feedSubscription { FeedHub.shared.unsubscribe(feedSubscription) }
        feedSubscription = nil
        tickTimer?.invalidate()
        tickTimer = nil
    }

    /// (Re)starts the update timer at the rate the current mode needs; `updateNow` also updates straight away.
    private func startTicking(updateNow: Bool = true) {
        tickTimer?.invalidate()
        if updateNow { updateTrains(now: Date().timeIntervalSince1970) }
        // The time-lapse runs 20 times faster, so it checks four times a second (a station stop lasts ~1.5 s).
        let interval = showingTimeLapse ? tick / 4 : tick
        tickTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateTrains(now: Date().timeIntervalSince1970) }
        }
        tickTimer?.tolerance = interval * 0.1  // lets macOS batch timer wake-ups (saves energy)
    }

    /// Whether the time-lapse should be showing: forced for testing, or because live data is unavailable.
    private var wantsTimeLapse: Bool {
        forceTimeLapse || feedCache?.isOffline == true
    }

    // ---- Each tick ----

    /// Asks the planner (live) or the time-lapse what changed and passes the commands to both map panels.
    /// The time-lapse is a backup: it takes over when live data is unavailable (or when forced for testing),
    /// provided it has recorded enough history; otherwise the live trains keep moving on their last predictions.
    ///
    /// - Parameter animated: false for snapshots (dots are drawn where they are, without animations).
    private func updateTrains(now: Double, animated: Bool = true) {
        guard let planner, let timeLapse, let history else { return }
        let replay = wantsTimeLapse && timeLapse.recorded(history) >= timeLapse.minimumHistory
        var commands: [TrainCommand] = []
        var modeChanged = false
        if replay != showingTimeLapse {  // fade one set of dots out as the other fades in
            commands += replay ? planner.reset() : timeLapse.reset()
            showingTimeLapse = replay
            modeChanged = true
            updateOfflineNote()
        }
        commands += replay ? timeLapse.update(history: history, wall: now) : planner.update(trips: liveTrips, now: now)
        updateModeNote(now: now)
        fullPanel?.apply(commands, animated: animated)
        zoomPanel?.apply(commands, animated: animated)
        if !nextTrains.isHidden { updateBoards(now: now) }
        if showsStatus { updateStatus() }
        if modeChanged, tickTimer != nil { startTicking(updateNow: false) }  // the tick rate follows the mode
    }

    /// The note for a forced (testing) time-lapse: the moment being replayed, or how long until it can start.
    /// (When the time-lapse is a backup, the offline note says so instead.)
    private func updateModeNote(now: Double) {
        guard forceTimeLapse, let timeLapse, let history else {
            modeLayer.isHidden = true
            return
        }
        let text: String
        if showingTimeLapse, let moment = timeLapse.clock(wall: now) {
            let time = DateFormatter.localizedString(from: Date(timeIntervalSince1970: moment), dateStyle: .none,
                                                     timeStyle: .short)
            text = String(format: "Time-lapse %.0f× (testing)  ·  %@", timeLapse.speed, time)
        } else {
            text = String(format: "Time-lapse starts after %.0f min of data (%.0f so far)",
                          timeLapse.minimumHistory / 60, timeLapse.recorded(history) / 60)
        }
        if modeLayer.string as? String != text {
            modeLayer.string = text
            fitNote(modeLayer)
        }
        modeLayer.isHidden = false
    }

    private func updateBoards(now: Double) {
        guard let network else { return }
        nextTrains.boards = settings.homeStations.compactMap {
            StationBoard.make(station: $0, trips: liveTrips, network: network, now: now,
                              perDirection: nextTrains.perDirection)
        }
    }

    // ---- Layout ----

    /// Screen pixels per point: 2 on Retina displays, 1 on most external monitors.
    private var backingScale: CGFloat {
        forcedScale ?? window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    /// The map region around the home stations (all their circles, plus some margin), at least
    /// `zoomMinWidth` wide. Falls back to Midtown when no home stations are chosen.
    private var homeRegion: CGRect? {
        guard let network else { return nil }
        var ids = settings.homeStations.filter { network.stations[$0] != nil }
        if ids.isEmpty { ids = network.focusViews["Midtown"] ?? [] }
        let boxes = ids.compactMap { network.stations[$0]?.extent }
        guard !boxes.isEmpty else { return nil }
        let pad: CGFloat = 30
        var rect = CGRect(x: boxes.map { $0[0] }.min()! - pad, y: boxes.map { $0[1] }.min()! - pad, width: 0, height: 0)
        rect.size = CGSize(width: boxes.map { $0[2] }.max()! + pad - rect.minX,
                           height: boxes.map { $0[3] }.max()! + pad - rect.minY)
        if rect.width < zoomMinWidth { rect = rect.insetBy(dx: (rect.width - zoomMinWidth) / 2, dy: 0) }
        return rect
    }

    /// Switches between the split layout and the close-up (saved in the settings).
    func setLayout(_ layout: SubwaySettings.Layout) {
        settings.layout = layout
        needsLayout = true
    }

    /// The magnification being shown (a multiple of the whole map fitted to the screen), set by layout().
    private(set) var shownMagnification: Double = 4

    /// Sets the magnification (nil = "Fit stations") and re-frames the magnified map.
    func setMagnification(_ magnification: Double?) {
        settings.magnification = magnification
        needsLayout = true
    }

    /// Steps to the next larger (+1) or smaller (-1) magnification choice from the one being shown.
    func stepMagnification(_ direction: Int) {
        let choices = SubwaySettings.magnifications
        let next = direction > 0 ? choices.first { $0 > shownMagnification + 0.01 } : choices.last { $0 < shownMagnification - 0.01 }
        setMagnification(next ?? (direction > 0 ? choices.last : choices.first))
    }

    /// The part of the map the magnified view shows in a panel of `size` points: `magnification` times the whole-map
    /// scale, or (automatic) framed on the home stations at a scale kept within `autoRange` (multiples); centred on
    /// the home stations and kept inside the map. Also records the magnification shown.
    private func magnifiedRegion(size: CGSize, document: MapDocument, autoRange: ClosedRange<Double>) -> CGRect {
        let map = document.bounds
        let base = Double(min(bounds.width / map.width, bounds.height / map.height))  // whole map fitted to the screen
        let home = homeRegion!
        let fitting = Double(min(size.width / home.width, size.height / home.height)) / base
        let multiple = settings.magnification ?? min(max(fitting, autoRange.lowerBound), autoRange.upperBound)
        shownMagnification = multiple
        let zoom = CGFloat(multiple * base)  // points per map unit
        let shown = CGSize(width: min(size.width / zoom, map.width), height: min(size.height / zoom, map.height))
        let x = min(max(home.midX - shown.width / 2, map.minX), map.maxX - shown.width)
        let y = min(max(home.midY - shown.height / 2, map.minY), map.maxY - shown.height)
        return CGRect(origin: CGPoint(x: x, y: y), size: shown)
    }

    /// The next-train board's height for this width: as tall as its content, with 3 trains each way for one
    /// station and 2 for more, fewer if that would be taller than `maxHeight`. Sets the board's row count.
    private func boardHeight(width: CGFloat, maxHeight: CGFloat) -> CGFloat {
        let stations = settings.homeStations.filter { network?.stations[$0] != nil }.count
        var perDirection = stations <= 1 ? 3 : 2
        func needs(_ rows: Int) -> CGFloat {
            NextTrainsView.height(stations: stations, perDirection: rows, width: width)
        }
        while perDirection > 1, needs(perDirection) > maxHeight { perDirection -= 1 }
        nextTrains.perDirection = perDirection
        return min(needs(perDirection), maxHeight).rounded()
    }

    /// Gives a panel or the board the look of a card floating over the map (close-up), or none (split).
    private func styleAsCard(_ layer: CALayer?, _ on: Bool) {
        layer?.cornerRadius = on ? 8 : 0
        layer?.borderWidth = on ? 1 : 0
        layer?.borderColor = NSColor(white: 1, alpha: 0.25).cgColor
        layer?.masksToBounds = true
    }

    override func layout() {
        super.layout()
        guard let document, let fullPanel, bounds.width > 0, bounds.height > 0 else { return }
        let w = bounds.width, h = bounds.height
        let mapAspect = document.bounds.width / document.bounds.height  // ≈ 0.84 (taller than wide)
        let scale = backingScale
        let closeUp = settings.layout == .closeUp && homeRegion != nil
        let split = !closeUp && w / h >= 1.2 && homeRegion != nil
        nextTrains.wantsLayer = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        styleAsCard(fullPanel.root, closeUp)
        styleAsCard(nextTrains.layer, closeUp)
        // The overview card sits above the close-up map; in the split layout the full map goes back underneath.
        if let zoom = zoomPanel?.root {
            fullPanel.root.removeFromSuperlayer()
            if closeUp { layer?.insertSublayer(fullPanel.root, above: zoom) } else { layer?.insertSublayer(fullPanel.root, below: zoom) }
        }
        CATransaction.commit()

        if closeUp {
            // One section of the map fills the window at the chosen magnification (automatic: framed on the home
            // stations, between 2× and 4×), centred on them. The overview (top right) outlines the section shown.
            zoomPanel?.root.isHidden = false
            zoomPanel?.layout(frame: bounds, showing: magnifiedRegion(size: bounds.size, document: document, autoRange: 2...4),
                              scale: scale)

            let margin: CGFloat = 12
            let overviewWidth = min(max(w * 0.14, 120), 220)
            let overviewHeight = (overviewWidth / mapAspect).rounded()
            fullPanel.dotRange = 2...3
            fullPanel.layout(frame: CGRect(x: w - overviewWidth - margin, y: h - overviewHeight - margin,
                                           width: overviewWidth, height: overviewHeight),
                             showing: document.bounds, scale: scale)
            fullPanel.setOutline(zoomPanel?.mapRect)

            let boardWidth = min(max(w * 0.32, 300), 440)
            let boardBottom: CGFloat = showsStatus ? 32 : margin  // above the status line
            nextTrains.isHidden = false
            nextTrains.frame = CGRect(x: margin, y: boardBottom, width: boardWidth,
                                      height: boardHeight(width: boardWidth, maxHeight: h * 0.45))
        } else if split {
            let fullWidth = min(h * mapAspect, w * 0.6)
            let gap: CGFloat = 2  // thin black divider
            let rightX = fullWidth + gap, rightWidth = w - rightX
            // The board is as tall as its content (at most half the column); the magnified map gets the rest.
            let board = boardHeight(width: rightWidth, maxHeight: h * 0.5)
            fullPanel.dotRange = 6...10
            fullPanel.layout(frame: CGRect(x: 0, y: 0, width: fullWidth, height: h), showing: document.bounds, scale: scale)
            zoomPanel?.root.isHidden = false
            let zoomFrame = CGRect(x: rightX, y: board + gap, width: rightWidth, height: h - board - gap)
            // At the chosen magnification, or (automatic) framed on the home stations, up to 10×.
            zoomPanel?.layout(frame: zoomFrame, showing: magnifiedRegion(size: zoomFrame.size, document: document,
                                                                         autoRange: 1...10), scale: scale)
            fullPanel.setOutline(zoomPanel?.mapRect)
            nextTrains.isHidden = false
            nextTrains.frame = CGRect(x: rightX, y: 0, width: rightWidth, height: board)
        } else {
            fullPanel.dotRange = 6...10
            fullPanel.layout(frame: bounds, showing: document.bounds, scale: scale)
            fullPanel.setOutline(nil)
            zoomPanel?.root.isHidden = true
            nextTrains.isHidden = true
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        statusLayer.contentsScale = scale
        statusLayer.frame = CGRect(x: 8, y: 8, width: 560, height: 16)
        // Notes go in the top-right corner (below the overview card in the close-up).
        let noteTop = closeUp ? fullPanel.root.frame.minY - 8 : h - 8
        for (i, note) in [modeLayer, offlineLayer].enumerated() {
            note.contentsScale = scale
            note.position = CGPoint(x: w - 12, y: noteTop - CGFloat(i) * 22)
        }
        CATransaction.commit()
        pickerButton?.frame = CGRect(x: w - 40, y: 8, width: 32, height: 32)
        // The panels' coordinates changed: recreate every dot and restart glides in the new coordinates.
        if let planner, tickTimer != nil {
            let now = Date().timeIntervalSince1970
            let commands = showingTimeLapse ? [] : planner.resync(now: now)
            for panel in [fullPanel, zoomPanel].compactMap({ $0 }) {
                panel.clearTrains()
                panel.apply(commands)
            }
            if showingTimeLapse {
                timeLapse?.redraw()
                updateTrains(now: now)
            }
        }
    }

    // ---- Home-station picker (preview app) ----

    private func addPickerButton() {
        let image = NSImage(systemSymbolName: "tram.fill", accessibilityDescription: "Choose home stations")
        let button = NSButton(image: image ?? NSImage(), target: self, action: #selector(showPicker(_:)))
        button.isBordered = false
        button.contentTintColor = .white
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor(white: 0.18, alpha: 0.9).cgColor
        button.layer?.cornerRadius = 16
        button.toolTip = "Choose home stations"
        addSubview(button)
        pickerButton = button
    }

    /// The settings panel (home stations, magnification), wired to this view: used by the picker popover in the
    /// preview app and by the screensaver's Options sheet.
    func makeSettingsController() -> StationPickerController? {
        guard let network else { return nil }
        return StationPickerController(network: network, selected: settings.homeStations,
                                       magnification: settings.magnification,
                                       onMagnification: { [weak self] in self?.setMagnification($0) }) { [weak self] ids in
            guard let self else { return }
            self.settings.homeStations = ids
            self.needsLayout = true  // re-frame the magnified map around the new stations
            self.updateBoards(now: Date().timeIntervalSince1970)
        }
    }

    @objc private func showPicker(_ sender: NSButton) {
        guard let picker = makeSettingsController() else { return }
        let popover = NSPopover()
        popover.contentViewController = picker
        popover.behavior = .transient  // closes when you click elsewhere
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    // ---- Status line ----

    private func updateStatus() {
        let now = CFAbsoluteTimeGetCurrent(), cpu = SubwayView.processCPUSeconds()
        let cpuPercent = (cpu - cpuSample.cpu) / max(now - cpuSample.wall, 1e-3) * 100
        cpuSample = (cpu, now)
        let (moving, atStations) = planner?.counts ?? (0, 0)
        let clock = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let failed = feedCache?.failed ?? []
        let retrying = failed.isEmpty ? "" : String(format: "  ·  retrying %d feed%@", failed.count, failed.count == 1 ? "" : "s")
        statusLayer.string = String(format: "  %@  ·  %d moving, %d at stations  ·  data %.0f s old%@  ·  CPU %.1f%%  ",
                                    clock, moving, atStations, Date().timeIntervalSince1970 - fetchedAt, retrying, cpuPercent)
    }

    /// CPU time this process has used so far, in seconds (all threads).
    static func processCPUSeconds() -> Double {
        var ts = timespec()
        clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &ts)
        return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9
    }

    // ---- Testing without a screen ----

    /// Renders exactly what the view shows (layout, trains, next-train panel) into a PNG,
    /// using `trips` placed at time `now`, without a window.
    func snapshotPNG(size: CGSize, scale: CGFloat, trips: [Trip], now: Double) -> Data? {
        forcedScale = scale
        frame = CGRect(origin: .zero, size: size)
        liveTrips = trips
        fetchedAt = now
        if !simulatedOutage.isEmpty {
            // Show the outage handling: these trips were downloaded 2 minutes ago, and the latest round failed.
            receive(Dictionary(grouping: trips, by: \.feed), at: now - 120)
            receive(Dictionary(grouping: trips, by: \.feed).filter {
                !simulatedOutage.contains($0.key) && !simulatedOutage.contains("all")
            }, at: now)
        }
        layout()
        updateTrains(now: now, animated: false)
        guard let layer,
              let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        layer.render(in: ctx)
        // AppKit-drawn views aren't captured by layer.render, so draw the next-train panel explicitly.
        if !nextTrains.isHidden, let rep = nextTrains.bitmapImageRepForCachingDisplay(in: nextTrains.bounds) {
            nextTrains.cacheDisplay(in: nextTrains.bounds, to: rep)
            if let image = rep.cgImage { ctx.draw(image, in: nextTrains.frame) }
        }
        if !offlineLayer.isHidden {  // it sits above the panel on screen, so draw it again on top here
            ctx.saveGState()
            ctx.translateBy(x: offlineLayer.frame.minX, y: offlineLayer.frame.minY)
            offlineLayer.render(in: ctx)
            ctx.restoreGState()
        }
        guard let image = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    /// For tests: the loaded network and locator (nil if network.json is missing).
    var testHooks: (network: SubwayNetwork, locator: Locator)? {
        guard let network, let locator else { return nil }
        return (network, locator)
    }
}

extension NSColor {
    /// A colour from "#RRGGBB".
    convenience init(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let value = UInt32(digits, radix: 16) ?? 0x888888
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}

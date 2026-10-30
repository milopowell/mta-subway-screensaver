import AppKit
import QuartzCore

/// The sandbox window's content: the map on the left, controls on the right.
///
/// ```
/// ┌──────────────────────────────┬────────────┐
/// │                              │ Send       │  route, from, to, pace
/// │  the map (one MapPanel),     │ Trains     │  delay, jump ahead, remove
/// │  click to center it there    │ View       │  magnification
/// │                              │ Feed       │  update interval, counts
/// └──────────────────────────────┴────────────┘
/// ```
///
/// Trains come from SimulatedFeed instead of the MTA: no downloads, and nothing is shared with the preview app or
/// the screensaver (no saved settings). Once a second the app's own MotionPlanner decides what every train does, and
/// the app's own MapPanel draws it, exactly as in SubwayView.
final class SandboxView: NSView {
    private let network: SubwayNetwork
    private let locator: Locator
    private let planner: MotionPlanner
    private let feed: SimulatedFeed
    private let document: MapDocument
    private let panel: MapPanel
    private let colors: [String: (NSColor, NSColor)]

    /// What the map shows: its center (map units) and magnification (1 = the whole map).
    private var center: CGPoint
    private var magnification: CGFloat = 4
    /// Seconds between pretend downloads (30 like the live feed; 1 for instant updates).
    private var downloadInterval: Double = 30
    private var lastDownload = -Double.infinity
    private var trips: [Trip] = []
    private var timer: Timer?
    /// The map's frame and region when last laid out: the sidebar's text changing also lays the view out, and the map
    /// is only redrawn (and the dots recreated) when one of these changes.
    private var laidOut: (frame: CGRect, region: CGRect)?

    private let sidebarWidth: CGFloat = 290
    private let sidebar = NSStackView()
    private let routePopup = NSPopUpButton()
    private let fromPopup = NSPopUpButton()
    private let toPopup = NSPopUpButton()
    private let pacePopup = NSPopUpButton()
    private let trainPopup = NSPopUpButton()
    private let feedPopup = NSPopUpButton()
    private let zoomSlider = NSSlider()
    private let zoomLabel = NSTextField(labelWithString: "")
    private let note = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private var listedTrains: [Int] = []
    private let themePopup = NSPopUpButton()

    init?(size: NSSize) {
        guard let url = SubwayView.resources.url(forResource: "map_black", withExtension: "pdf"),
              let document = MapDocument(url: url),
              let network = try? SubwayNetwork.loadBundled() else { return nil }
        self.document = document
        self.network = network
        locator = Locator(network: network)
        planner = MotionPlanner(locator: locator)
        feed = SimulatedFeed(network: network)
        panel = MapPanel(document: document)
        panel.dotRange = 8...14
        panel.dotUnits = network.settings.trainDotUnits
        colors = network.routes.mapValues { (NSColor(hex: $0.color), NSColor(hex: $0.textColor)) }
        // Start on Columbus Circle, where trains pass under the A/C/E and B/D lines.
        center = network.stations.values.first { $0.name.hasPrefix("59 St-Columbus") }.map { CGPoint($0.center) }
            ?? CGPoint(x: document.bounds.midX, y: document.bounds.midY)
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(panel.root)
        panel.overpasses = { [weak locator = self.locator] path in locator?.overpasses(path: path) ?? [] }
        panel.routeColors = colors  // trains waiting at stations show their route's bullet
        buildSidebar()
    }

    required init?(coder: NSCoder) {
        fatalError("created in code only")
    }

    // ---- Running ----

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        tick()
    }

    /// Once a second: a pretend download when one is due, then the planner moves the trains.
    private func tick(downloadNow: Bool = false) {
        let now = Date().timeIntervalSince1970
        if downloadNow || now - lastDownload >= downloadInterval {
            trips = feed.snapshot(now: now)
            lastDownload = now
        }
        panel.apply(planner.update(trips: trips, now: now))
        let counts = planner.counts
        status.stringValue = "\(counts.moving) moving, \(counts.stopped) stopped; next update in "
            + "\(max(Int((lastDownload + downloadInterval - now).rounded()), 0)) s"
        refreshTrainList()
    }

    // ---- Map ----

    override func layout() {
        super.layout()
        let mapFrame = CGRect(x: 0, y: 0, width: max(bounds.width - sidebarWidth, 1), height: bounds.height)
        sidebar.frame = CGRect(x: mapFrame.maxX, y: 0, width: sidebarWidth, height: bounds.height)
        let size = CGSize(width: document.bounds.width / magnification, height: document.bounds.height / magnification)
        let region = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
        if let laidOut, laidOut.frame == mapFrame, laidOut.region == region { return }
        laidOut = (mapFrame, region)
        panel.layout(frame: mapFrame, showing: region, scale: window?.backingScaleFactor ?? 2)
        // The map's coordinates changed: redraw every dot, glides continuing from where they are.
        panel.clearTrains()
        panel.apply(planner.resync(now: Date().timeIntervalSince1970))
    }

    /// A click on the map centers it there.
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard p.x < bounds.width - sidebarWidth else { return }
        let rect = panel.mapRect, scale = panel.pointsPerUnit
        center = CGPoint(x: rect.minX + p.x / scale, y: rect.minY + p.y / scale)
        needsLayout = true
    }

    @objc private func zoomChanged() {
        magnification = CGFloat(zoomSlider.doubleValue.rounded())
        zoomLabel.stringValue = "Magnification: \(Int(magnification))×"
        needsLayout = true
    }

    @objc private func showWholeMap() {
        center = CGPoint(x: document.bounds.midX, y: document.bounds.midY)
        zoomSlider.doubleValue = 1
        zoomChanged()
    }

    /// Centers the map on the station a train leaves from (keeping the magnification), to watch it set off.
    private func centerOn(_ train: SimulatedFeed.Train) {
        guard let first = train.platforms.first, let station = network.platforms[first] else { return }
        center = locator.stationPoint(route: train.route, station: station)
        needsLayout = true
    }

    // ---- Sending and changing trains ----

    private var pace: Double { [1, 2, 4][max(pacePopup.indexOfSelectedItem, 0)] }

    @objc private func send() {
        guard let route = routePopup.selectedItem?.representedObject as? String,
              let from = fromPopup.selectedItem?.representedObject as? String,
              let to = toPopup.selectedItem?.representedObject as? String else { return }
        guard from != to else { return show("From and To are the same station.") }
        guard let train = feed.send(route: route, from: from, to: to, pace: pace, now: Date().timeIntervalSince1970) else {
            return show("No \(RouteSymbolsView.label(for: route)) service runs from that station to that one. "
                        + "Try swapping them, or a different route.")
        }
        show("Sent \(train.label).")
        centerOn(train)
        tick(downloadNow: true)  // appears at once rather than at the next update
    }

    /// Sends whatever the pickers show (for the --snapshot test).
    func sendDefault() {
        send()
    }

    @objc private func sendRandom() {
        let now = Date().timeIntervalSince1970
        let sent = (0..<10).compactMap { _ in feed.sendRandom(stops: Int.random(in: 4...10), pace: pace, now: now) }
        show("Sent \(sent.count) trains on random routes. Show the whole map to see them all.")
        tick(downloadNow: true)
    }

    private var selectedTrain: Int? { trainPopup.selectedItem?.representedObject as? Int }

    @objc private func delayTrain() { changeTrain(by: 30, "is now running 30 s late") }
    @objc private func jumpTrain() { changeTrain(by: -60, "is now 60 s further along") }

    /// Shifts the selected train's timetable: the next update reports the change, as a real download would.
    private func changeTrain(by seconds: Double, _ what: String) {
        guard let id = selectedTrain else { return }
        feed.shift(id, by: seconds, now: Date().timeIntervalSince1970)
        show("Train \(trainPopup.titleOfSelectedItem ?? "") \(what); the change arrives with the next update.")
    }

    @objc private func removeTrain() {
        guard let id = selectedTrain else { return }
        feed.remove(id)
        show("Removed; it leaves with the next update.")
    }

    @objc private func removeAll() {
        feed.removeAll()
        tick(downloadNow: true)
        show("Removed every train.")
    }

    /// Switches between the dark and the light map (the app's Appearance setting, without the automatic choices).
    @objc private func themeChanged() {
        let theme: Theme = themePopup.indexOfSelectedItem == 1 ? .light : .dark
        guard let url = SubwayView.resources.url(forResource: theme.mapResource, withExtension: "pdf"),
              let map = MapDocument(url: url) else { return show("The light map isn't bundled: re-run the notebook's §8.") }
        panel.document = map
        panel.theme = theme
        layer?.backgroundColor = theme.background.cgColor
        laidOut = nil
        needsLayout = true
    }

    @objc private func feedChanged() {
        downloadInterval = feedPopup.indexOfSelectedItem == 0 ? 30 : 1
    }

    @objc private func routeChanged() {
        guard let route = routePopup.selectedItem?.representedObject as? String else { return }
        let stations = feed.stations(of: route)
        for (popup, pick) in [(fromPopup, stations.first), (toPopup, stations.last)] {
            popup.removeAllItems()
            for id in stations {  // menu items directly: a popup's addItem(withTitle:) drops repeated names
                let item = NSMenuItem(title: network.stations[id]?.name ?? id, action: nil, keyEquivalent: "")
                item.representedObject = id
                popup.menu?.addItem(item)
            }
            if let pick, let i = stations.firstIndex(of: pick) { popup.selectItem(at: i) }
        }
    }

    private func show(_ message: String) {
        note.stringValue = message
    }

    /// Keeps the Trains popup in step with the trains still in the feed.
    private func refreshTrainList() {
        let ids = feed.trains.map(\.id)
        guard ids != listedTrains else { return }
        let selected = selectedTrain
        listedTrains = ids
        trainPopup.removeAllItems()
        for train in feed.trains {
            let item = NSMenuItem(title: "#\(train.id) \(train.label)", action: nil, keyEquivalent: "")
            item.representedObject = train.id
            item.image = symbol(train.route)
            trainPopup.menu?.addItem(item)
        }
        if let selected, let i = ids.firstIndex(of: selected) { trainPopup.selectItem(at: i) }
        trainPopup.isEnabled = !ids.isEmpty
    }

    // ---- Sidebar ----

    private func symbol(_ route: String) -> NSImage {
        NSImage(size: NSSize(width: 18, height: 18), flipped: false) { [colors] rect in
            RouteSymbolsView.draw(route, center: CGPoint(x: rect.midX, y: rect.midY), diameter: 16, colors: colors)
            return true
        }
    }

    private func buildSidebar() {
        sidebar.orientation = .vertical
        sidebar.alignment = .leading
        sidebar.spacing = 8
        sidebar.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        sidebar.wantsLayer = true
        sidebar.layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
        sidebar.appearance = NSAppearance(named: .darkAqua)
        addSubview(sidebar)

        func header(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 13, weight: .semibold)
            return label
        }
        func row(_ title: String, _ control: NSView) -> NSView {
            let label = NSTextField(labelWithString: title)
            label.widthAnchor.constraint(equalToConstant: 44).isActive = true
            control.widthAnchor.constraint(equalToConstant: sidebarWidth - 32 - 52).isActive = true
            return NSStackView(views: [label, control])
        }
        func button(_ title: String, _ action: Selector) -> NSButton {
            NSButton(title: title, target: self, action: action)
        }
        func gap() -> NSView {
            let box = NSBox()
            box.boxType = .separator
            box.widthAnchor.constraint(equalToConstant: sidebarWidth - 32).isActive = true
            return box
        }

        let routes = network.routes.keys.filter { !feed.stations(of: $0).isEmpty }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        for route in routes {
            let item = NSMenuItem(title: network.routes[route]?.name ?? route, action: nil, keyEquivalent: "")
            item.representedObject = route
            item.image = symbol(route)
            routePopup.menu?.addItem(item)
        }
        routePopup.target = self
        routePopup.action = #selector(routeChanged)
        if let i = routes.firstIndex(of: "1") { routePopup.selectItem(at: i) }
        routeChanged()
        // To start: a short run on the 1 through Columbus Circle, where it passes under the A/C/E and B/D lines.
        for (popup, name) in [(fromPopup, "59 St-Columbus Circle"), (toPopup, "14 St")] {
            if let i = popup.itemArray.firstIndex(where: { $0.title == name }) { popup.selectItem(at: i) }
        }
        pacePopup.addItems(withTitles: ["As scheduled", "2× faster", "4× faster"])
        pacePopup.selectItem(at: 1)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = sidebarWidth - 32
        note.stringValue = "Choose a route and two of its stations, then Send."

        zoomSlider.minValue = 1
        zoomSlider.maxValue = 10
        zoomSlider.doubleValue = Double(magnification)
        zoomSlider.numberOfTickMarks = 10
        zoomSlider.allowsTickMarkValuesOnly = true
        zoomSlider.target = self
        zoomSlider.action = #selector(zoomChanged)
        zoomSlider.widthAnchor.constraint(equalToConstant: sidebarWidth - 32).isActive = true
        zoomLabel.stringValue = "Magnification: \(Int(magnification))×"
        let help = NSTextField(wrappingLabelWithString: "Click the map to center it there.")
        help.textColor = .secondaryLabelColor

        trainPopup.widthAnchor.constraint(equalToConstant: sidebarWidth - 32).isActive = true
        trainPopup.isEnabled = false
        feedPopup.addItems(withTitles: ["Update every 30 s (like the live feed)", "Update every second"])
        feedPopup.widthAnchor.constraint(equalToConstant: sidebarWidth - 32).isActive = true
        feedPopup.target = self
        feedPopup.action = #selector(feedChanged)
        status.textColor = .secondaryLabelColor
        themePopup.addItems(withTitles: ["Dark map", "Light map"])
        themePopup.target = self
        themePopup.action = #selector(themeChanged)

        let views: [NSView] = [
            header("Send a train"),
            row("Route", routePopup), row("From", fromPopup), row("To", toPopup), row("Pace", pacePopup),
            NSStackView(views: [button("Send", #selector(send)), button("Send 10 random", #selector(sendRandom))]),
            note,
            gap(), header("Trains"),
            trainPopup,
            NSStackView(views: [button("Delay 30 s", #selector(delayTrain)), button("Jump ahead 60 s", #selector(jumpTrain))]),
            NSStackView(views: [button("Remove", #selector(removeTrain)), button("Remove all", #selector(removeAll))]),
            gap(), header("View"),
            zoomLabel, zoomSlider, help, NSStackView(views: [button("Whole map", #selector(showWholeMap)), themePopup]),
            gap(), header("Feed"),
            feedPopup, status,
        ]
        for view in views { sidebar.addArrangedSubview(view) }
        sidebar.setHuggingPriority(.defaultHigh, for: .vertical)
        // Top-aligned: a flexible space at the bottom takes up the rest of the column.
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .vertical)
        sidebar.addArrangedSubview(spacer)
    }
}

import AppKit

// Entry point of the sandbox: a separate app for sending trains by hand and trying out new features, with no live
// data. It shares the drawing and motion code (Shared/) with the preview app and the screensaver, but no settings.

/// Opens one window with SandboxView, and a menu with Quit.
final class SandboxAppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1512, height: 945)
        let size = NSSize(width: screen.width * 0.75, height: screen.height * 0.8)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "MTA Subway — Sandbox"
        window.backgroundColor = .black
        window.contentMinSize = NSSize(width: 700, height: 560)
        guard let view = SandboxView(size: size) else {
            let alert = NSAlert()
            alert.messageText = "The map or network.json isn't bundled."
            alert.informativeText = "Run the notebook's §8 export, then rebuild."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        window.contentView = view
        view.start()
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)  // come to the front even when launched from Terminal
        self.window = window

        let main = NSMenu(), appItem = NSMenuItem(), appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Subway Sandbox", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        NSApp.mainMenu = main
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

/// `--check`: runs the pretend feed through the motion planner on a simulated clock, without a window, and prints how
/// the trains moved (every glide of one 1 train, then totals for 10 random trains with a delay and a jump ahead).
func check() {
    guard let network = try? SubwayNetwork.loadBundled() else { print("network.json isn't bundled"); exit(1) }
    let locator = Locator(network: network)
    let name = { (s: String) in network.stations[s]?.name ?? s }
    func run(_ feed: SimulatedFeed, from start: Double, seconds: Int, events: [Int: () -> Void] = [:]) -> MotionPlanner {
        let planner = MotionPlanner(locator: locator)
        planner.glideLog = []
        var trips: [Trip] = []
        for t in 0..<seconds {
            events[t]?()
            if t % 30 == 0 { trips = feed.snapshot(now: start + Double(t)) }
            _ = planner.update(trips: trips, now: start + Double(t))
        }
        return planner
    }
    let start = Date().timeIntervalSince1970
    let one = SimulatedFeed(network: network)
    let columbus = network.stations.first { $0.value.name.hasPrefix("59 St-Columbus") && $0.value.routes.contains("1") }!.key
    let fourteenth = one.stations(of: "1").first { name($0) == "14 St" }!
    guard let train = one.send(route: "1", from: columbus, to: fourteenth, pace: 2, now: start) else {
        print("FAIL: couldn't send a 1 train"); exit(1)
    }
    print("\(train.label): \(train.platforms.count) stops, timetable \(Int(train.departures.last! - start)) s")
    let planner = run(one, from: start, seconds: Int(train.departures.last! - start) + 30)
    for g in planner.glideLog! {
        print(String(format: "  %4.0f-%4.0f s  %@  %@ to %@  (arrive %+.0f s vs timetable)", g.start - start, g.end - start,
                     g.kind.rawValue, name(g.from), name(g.to), g.end - g.predictedArrival))
    }
    print("  \(planner.stats.catchUps) catch-ups, \(planner.stats.teleports) fades; gone at the end: \(planner.counts.moving + planner.counts.stopped == 0)")

    let many = SimulatedFeed(network: network)
    for _ in 0..<10 { many.sendRandom(stops: Int.random(in: 4...10), pace: 2, now: start) }
    let ids = many.trains.map(\.id)
    let busy = run(many, from: start, seconds: 600, events: [
        100: { many.shift(ids[0], by: 30, now: start + 100) },
        130: { many.shift(ids[1], by: -60, now: start + 130) },
    ])
    print("10 random trains, 600 s: \(busy.glideLog!.count) glides, \(busy.stats.catchUps) catch-ups, "
          + "\(busy.stats.teleports) fades \(busy.stats.teleportReasons); left on the map: \(busy.counts.moving + busy.counts.stopped)")
    exit(0)
}
if CommandLine.arguments.contains("--check") { check() }

/// `--check-recording`: downloads the live feed once, saves it as a recording and reads it back, then replays it
/// through the motion planner for 25 simulated seconds (a one-download recording ends after 30).
if CommandLine.arguments.contains("--check-recording") {
    guard let network = try? SubwayNetwork.loadBundled() else { print("network.json isn't bundled"); exit(1) }
    var result: (feeds: [String: [Trip]], fetchedAt: Double)?
    Task { result = await FeedClient.fetchEach(settings: network.settings) }
    while result == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    var recording = Recording()
    let live = result!.feeds.values.flatMap { $0 }
    recording.add(live, at: result!.fetchedAt)
    let data = try! JSONEncoder().encode(recording)
    let back = try! JSONDecoder().decode(Recording.self, from: data)
    let trips = back.trips(at: back.start + 10)
    print("one download: \(live.count) trips, \(data.count / 1000) KB as JSON; read back \(trips.count) trips")
    let planner = MotionPlanner(locator: Locator(network: network))
    var commands = 0
    for t in 0..<25 { commands += planner.update(trips: back.trips(at: back.start + Double(t)), now: back.start + Double(t)).count }
    print("replayed 25 s: \(commands) commands, \(planner.counts.moving) moving, \(planner.counts.stopped) stopped")
    exit(0)
}

/// `--snapshot out.png`: opens the sandbox without a window, sends a train, and renders the view after 20 s.
if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
    _ = NSApplication.shared
    let size = NSSize(width: 1400, height: 860)
    guard let view = SandboxView(size: size) else { print("the map or network.json isn't bundled"); exit(1) }
    view.appearance = NSAppearance(named: .darkAqua)
    view.layoutSubtreeIfNeeded()
    view.start()
    view.sendDefault()
    RunLoop.main.run(until: Date().addingTimeInterval(20))
    view.layoutSubtreeIfNeeded()
    let ctx = CGContext(data: nil, width: Int(size.width * 2), height: Int(size.height * 2), bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    ctx.scaleBy(x: 2, y: 2)
    view.layer?.render(in: ctx)  // the map and trains, then the sidebar's controls on top
    for sub in view.subviews {
        if let rep = sub.bitmapImageRepForCachingDisplay(in: sub.bounds) {
            NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance { sub.cacheDisplay(in: sub.bounds, to: rep) }
            if let image = rep.cgImage { ctx.draw(image, in: sub.frame) }
        }
    }
    try! NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
    exit(0)
}

let app = NSApplication.shared
let delegate = SandboxAppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()

import AppKit

// Entry point of the preview app: a normal Mac app showing SubwayView in a window, for development.
//
// Command-line options (handy for testing from Terminal):
//   --fullscreen                         start in full screen
//   --snapshot <file.png>                render the map (and trains, see below) to a PNG and quit; no window
//       [--width W --height H]           view size in points (default: a 14" MacBook Pro screen, 1512×982)
//       [--home ID,ID…]                  home stations for this snapshot only (the saved choice is unchanged)
//       [--layout split|closeUp]         layout for this snapshot only
//       [--magnification M]              magnification (2, 3, 4, 6, 8; omit = Fit stations) for this snapshot only
//   --dump-placements <file.json>        write every trip's placement (feed, trip_id, x, y, how) and quit
//   Train data for --snapshot / --dump-placements:
//       --live                           download the feeds now
//       --feeds-dir <dir> --now <unix>   read saved feeds <dir>/<feed>.pb and place trains at time <unix>
//                                        (used to compare with the notebook on identical data)
//   --plan-report [--seconds S]          run the motion planner on live data and report how trains move
//   --timing-report [--seconds S]        compare the dots' station arrivals/departures with the real trains
//   --time-lapse-report [--record S --seconds S]  record live history, replay it, and check the replay is smooth
//   --path-report <file>                 check the track every hop is drawn along; writes <file>.png
//   --picker-snapshot <file.png> [--home IDs --line ROUTE]  render the home-station picker
//   --time-lapse                         force the time-lapse (normally a backup when live data is unavailable)
//   --simulate-outage FEED[,FEED…]|all   treat those feeds as failed after the first download
//                                        (in the window, or in --plan-report)

let arguments = CommandLine.arguments

func value(after flag: String) -> String? {
    guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
    return arguments[i + 1]
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

/// Trips + the time to place them at, from --live or --feeds-dir/--now (nil if neither was given).
func commandLineTrips(network: SubwayNetwork) -> (trips: [Trip], now: Double)? {
    if let dir = value(after: "--feeds-dir") {
        guard let now = value(after: "--now").flatMap(Double.init) else { fail("--feeds-dir needs --now <unix time>") }
        do {
            return (try FeedClient.load(fromDirectory: URL(fileURLWithPath: dir), settings: network.settings), now)
        } catch {
            fail("couldn't read feeds from \(dir): \(error.localizedDescription)")
        }
    }
    if arguments.contains("--live") {
        // Download on a background task and wait for it here (the main thread has nothing else to do).
        var result: (trips: [Trip], fetchedAt: Double)?
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            result = await FeedClient.fetchAll(settings: network.settings)
            done.signal()
        }
        done.wait()
        return (result!.trips, result!.fetchedAt)
    }
    return nil
}

if let output = value(after: "--picker-snapshot") {
    // Renders the home-station picker to a PNG (dark appearance), with --home stations chosen and, with --line,
    // that line's stations listed.
    _ = NSApplication.shared  // AppKit controls only draw once the application object exists
    NSApp.setActivationPolicy(.prohibited)  // no Dock icon: this mode never shows a window
    guard let network = SubwayView(frame: .zero).testHooks?.network else { fail("network.json isn't bundled") }
    let chosen = value(after: "--home")?.split(separator: ",").map(String.init) ?? SubwaySettings.defaultHomeStations
    let picker = StationPickerController(network: network, selected: chosen, magnification: nil, onMagnification: { _ in }) { _ in }
    picker.view.appearance = NSAppearance(named: .darkAqua)
    picker.view.wantsLayer = true
    picker.view.layer?.backgroundColor = NSColor(white: 0.16, alpha: 1).cgColor  // the popover's dark background
    picker.browseLine(value(after: "--line"))
    let size = picker.view.fittingSize
    picker.view.frame = CGRect(origin: .zero, size: size)
    picker.view.layoutSubtreeIfNeeded()
    guard let rep = picker.view.bitmapImageRepForCachingDisplay(in: picker.view.bounds) else { fail("no bitmap") }
    NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
        picker.view.cacheDisplay(in: picker.view.bounds, to: rep)
    }
    let backed = NSImage(size: size)
    backed.lockFocus()
    rep.draw(in: NSRect(origin: .zero, size: size))
    backed.unlockFocus()
    guard let tiff = backed.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    else { fail("png failed") }
    try png.write(to: URL(fileURLWithPath: output))
    print("wrote \(output) (\(Int(size.width))×\(Int(size.height)) pt)")
    exit(0)
}

if let output = value(after: "--path-report") {
    // Checks the track every hop is drawn along (Locator.hopLine), for every pair of neighboring stations in every
    // stop pattern: hops that fall back to a straight line, and hops whose path is much longer than the direct
    // distance (wandering along the wrong stretch of line). Writes <output>.png: the map with straight hops in red
    // and long ones in yellow, and prints the worst, weighted by how many trips a day use them.
    let view = SubwayView(frame: .zero)
    guard let hooks = view.testHooks, let document = MapDocument(url: SubwayView.resources.url(forResource: "map_black",
                                                                                                 withExtension: "pdf")!)
    else { fail("network.json or map_black.pdf isn't bundled") }
    let network = hooks.network, locator = hooks.locator
    struct Hop { let route: String, from: String, to: String; var trips: Int; let line: Polyline; let followed: Bool; let ratio: CGFloat }
    var hops: [String: Hop] = [:]
    for pattern in network.patterns {
        var stations: [String] = []
        for stop in pattern.stops { if let s = locator.stationOf(stop), stations.last != s { stations.append(s) } }
        for (a, b) in zip(stations, stations.dropFirst()) {
            let key = "\(pattern.route)|\(a)|\(b)"
            if hops[key] != nil { hops[key]!.trips += pattern.trips; continue }
            let (line, followed) = locator.hopLine(route: pattern.route, from: a, to: b)
            let pa = locator.stationPoint(route: pattern.route, station: a), pb = locator.stationPoint(route: pattern.route, station: b)
            let direct = max(hypot(pb.x - pa.x, pb.y - pa.y), 1)
            hops[key] = Hop(route: pattern.route, from: a, to: b, trips: pattern.trips, line: line, followed: followed,
                            ratio: line.length / direct)
        }
    }
    let straight = hops.values.filter { !$0.followed }, long = hops.values.filter { $0.followed && $0.ratio > 1.5 }
    func name(_ id: String) -> String { network.stations[id]?.name ?? id }
    print("\(hops.count) hops: \(hops.count - straight.count - long.count) follow the track, \(straight.count) straight lines, \(long.count) more than 1.5× the direct distance")
    print("trips a day on straight hops: \(straight.map(\.trips).reduce(0, +)), on long hops: \(long.map(\.trips).reduce(0, +))")
    for hop in straight.sorted(by: { $0.trips > $1.trips }).prefix(12) {
        print(String(format: "  straight %@  %@ → %@  (%d trips/day, %.0f units)", hop.route, name(hop.from), name(hop.to), hop.trips, hop.line.length))
    }
    for hop in long.sorted(by: { $0.ratio * CGFloat($0.trips) > $1.ratio * CGFloat($1.trips) }).prefix(12) {
        print(String(format: "  long %.1f×  %@  %@ → %@  (%d trips/day)", hop.ratio, hop.route, name(hop.from), name(hop.to), hop.trips))
    }
    // The map at 2 pixels per unit with the problem hops drawn on top.
    let scale: CGFloat = 2
    let size = CGSize(width: document.bounds.width * scale, height: document.bounds.height * scale)
    guard let map = document.renderImage(mapRect: document.bounds, pixelSize: size),
          let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                  | CGBitmapInfo.byteOrder32Little.rawValue) else { fail("render failed") }
    ctx.draw(map, in: CGRect(origin: .zero, size: size))
    ctx.scaleBy(x: scale, y: scale)
    ctx.translateBy(x: -document.bounds.minX, y: -document.bounds.minY)
    for (hop, color) in straight.map({ ($0, CGColor(red: 1, green: 0.1, blue: 0.1, alpha: 0.9)) })
        + long.map({ ($0, CGColor(red: 1, green: 0.9, blue: 0, alpha: 0.9)) }) {
        ctx.setStrokeColor(color)
        ctx.setLineWidth(3)
        ctx.addLines(between: hop.line.points)
        ctx.strokePath()
    }
    guard let image = ctx.makeImage(), let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    else { fail("png failed") }
    try png.write(to: URL(fileURLWithPath: output + ".png"))
    print("wrote \(output).png")
    exit(0)
}

if arguments.contains("--time-lapse-report") {
    // Records live history like the app (a download every 30 s) for --record seconds (default 420), then runs the
    // time-lapse over it for --seconds of wall time (default 60) and checks the replay is smooth: every glide must
    // start where its dot already is, and dots should not vanish mid-loop.
    let view = SubwayView(frame: .zero)
    guard let hooks = view.testHooks else { fail("network.json isn't bundled") }
    let network = hooks.network
    let record = Double(value(after: "--record") ?? "420") ?? 420
    let seconds = Double(value(after: "--seconds") ?? "60") ?? 60
    let history = TripHistory(platforms: network.platforms, keep: 2000)
    var cache = FeedCache(feeds: network.settings.feeds, keepFor: network.settings.staleAfterS)
    let recordStart = Date().timeIntervalSince1970
    var next = recordStart
    while next <= recordStart + record {
        Thread.sleep(forTimeInterval: max(0, next - Date().timeIntervalSince1970))
        var result: (feeds: [String: [Trip]], fetchedAt: Double)?
        let done = DispatchSemaphore(value: 0)
        Task.detached { result = await FeedClient.fetchEach(settings: network.settings); done.signal() }
        done.wait()
        cache.receive(result!.feeds, at: result!.fetchedAt)
        history.observe(cache.trips, at: result!.fetchedAt)
        next += 30
    }
    let visits = history.records.values.map(\.visits.count)
    print(String(format: "recorded %.0f s: %d trips, %d station visits (%d from 'stopped at', %d from predictions)",
                 record, history.records.count, visits.reduce(0, +), history.arrivalsFromStopped, history.arrivalsFromPrediction))

    let lapse = TimeLapse(locator: hooks.locator)
    lapse.minimumHistory = min(lapse.minimumHistory, record - 30)
    var position: [String: CGPoint] = [:]  // where each dot is (or is heading)
    var shownCounts: [Int] = [], glideSeconds: [Double] = []
    var glides = 0, places = 0, removes = 0, loops = 0, jumps = 0
    var worstJump: CGFloat = 0
    var jumpExamples: [(distance: CGFloat, text: String)] = []
    func noteJump(_ key: String, _ kind: String, from p: CGPoint, to q: CGPoint, clock: Double?) {
        let d = hypot(p.x - q.x, p.y - q.y)
        jumps += 1
        worstJump = max(worstJump, d)
        let visits = history.records[key]?.visits.map { v in
            String(format: "%@ %.0f–%.0f", v.station, v.arrive - (clock ?? 0), v.depart - (clock ?? 0)) } ?? []
        jumpExamples.append((d, String(format: "%@ %@ by %.0f units; visits (s from now): %@", key, kind, d,
                                       visits.joined(separator: ", "))))
    }
    let start = Date().timeIntervalSince1970
    var wall = start
    var lastClock: Double?
    while wall < start + seconds {
        let commands = lapse.update(history: history, wall: wall)
        if let clock = lapse.clock(wall: wall), let previous = lastClock, clock < previous { loops += 1 }
        lastClock = lapse.clock(wall: wall)
        for command in commands {
            switch command {
            case .place(let key, let point, _):
                if let p = position[key], hypot(p.x - point.x, p.y - point.y) > 2 {
                    noteJump(key, "stop", from: p, to: point, clock: lapse.clock(wall: wall))
                }
                position[key] = point; places += 1
            case .travel(let key, let path, let duration):
                if let p = position[key], let first = path.first, hypot(p.x - first.x, p.y - first.y) > 2 {
                    noteJump(key, "glide", from: p, to: first, clock: lapse.clock(wall: wall))
                }
                position[key] = path.last; glides += 1; glideSeconds.append(duration)
            case .remove(let key):
                position[key] = nil; removes += 1
            }
        }
        shownCounts.append(position.count)
        wall += 0.25
    }
    let sorted = glideSeconds.sorted()
    print(String(format: "replayed %.0f s of wall time at %.0f× (%.0f min of history per %.0f s loop), %d loop restart(s)",
                 seconds, lapse.speed, min(record, lapse.window) / 60, min(record, lapse.window) / lapse.speed, loops))
    print(String(format: "trains on screen: mean %.0f, max %d;  glides %d (median %.1f s on screen), stops %d, fades out %d",
                 Double(shownCounts.reduce(0, +)) / Double(max(shownCounts.count, 1)), shownCounts.max() ?? 0, glides,
                 sorted.isEmpty ? 0 : sorted[sorted.count / 2], places, removes))
    print(String(format: "jumps (a dot told to start somewhere other than where it is): %d, worst %.1f map units", jumps, worstJump))
    let sizes = jumpExamples.map(\.distance)
    print("jump sizes: under 10 units \(sizes.filter { $0 < 10 }.count), 10–50 \(sizes.filter { $0 >= 10 && $0 < 50 }.count), 50+ \(sizes.filter { $0 >= 50 }.count)")
    for example in jumpExamples.sorted(by: { $0.distance > $1.distance }).prefix(4) { print("  " + example.text) }
    for example in jumpExamples.filter({ $0.distance < 10 }).prefix(2) { print("  " + example.text) }
    exit(0)
}

if arguments.contains("--timing-report") {
    // How close is the animation to the real trains? Runs the app's motion (MotionPlanner, fed every 30 s like the
    // app) for --seconds (default 180), and compares each dot's arrival at, and departure from, a station with
    // when the real train got there.
    //
    // "Actual" times come from the feeds themselves, downloaded every 15 s, as worked out by TripHistory (the same
    // record the time-lapse replays): the first "stopped at" report for arrivals, the last report for departures.
    let view = SubwayView(frame: .zero)
    guard let hooks = view.testHooks else { fail("network.json isn't bundled") }
    let network = hooks.network
    let seconds = Double(value(after: "--seconds") ?? "180") ?? 180
    let tail = 120.0  // keep watching the feeds afterwards, to see the last trains reach their stations
    let planner = MotionPlanner(locator: hooks.locator)
    planner.glideLog = []
    var cache = FeedCache(feeds: network.settings.feeds, keepFor: network.settings.staleAfterS)

    let history = TripHistory(platforms: network.platforms, keep: seconds + tail + 600)

    let start = Date().timeIntervalSince1970
    var downloads = 0, tick = start, trips: [Trip] = []
    while tick < start + seconds + tail {
        Thread.sleep(forTimeInterval: max(0, tick - Date().timeIntervalSince1970))
        if Int(tick - start) % 15 == 0 {
            var result: (feeds: [String: [Trip]], fetchedAt: Double)?
            let done = DispatchSemaphore(value: 0)
            Task.detached { result = await FeedClient.fetchEach(settings: network.settings); done.signal() }
            done.wait()
            history.observe(network.settings.feeds.flatMap { result!.feeds[$0] ?? [] }, at: result!.fetchedAt)
            if downloads % 2 == 0 {  // the app downloads every 30 s
                cache.receive(result!.feeds, at: result!.fetchedAt)
                trips = cache.trips
            }
            downloads += 1
        }
        if tick < start + seconds { _ = planner.update(trips: trips, now: tick) }
        tick += 1
    }

    // Match glides with actual times. Positive = the dot is late (after the real train).
    var arrivalError: [Double] = [], catchUpArrivalError: [Double] = [], departureError: [Double] = []
    var predictionError: [Double] = [], aimError: [Double] = []
    var matchedArrivals = Set<String>(), matchedDepartures = Set<String>()
    for glide in planner.glideLog ?? [] where glide.end <= start + seconds {
        if glide.from != glide.to, let real = history.visit(trip: glide.key, station: glide.from), matchedDepartures.insert("\(glide.key)|\(glide.from)").inserted {
            departureError.append(glide.start - real.depart)
        }
        guard let real = history.visit(trip: glide.key, station: glide.to), matchedArrivals.insert("\(glide.key)|\(glide.to)").inserted else { continue }
        if glide.catchUp {
            catchUpArrivalError.append(glide.end - real.arrive)
        } else {
            arrivalError.append(glide.end - real.arrive)
            predictionError.append(glide.predictedArrival - real.arrive)
            aimError.append(glide.end - glide.predictedArrival)
        }
    }
    func summary(_ name: String, _ v: [Double]) {
        guard !v.isEmpty else { print("\(name): no data"); return }
        let sorted = v.sorted(), n = Double(v.count)
        func q(_ f: Double) -> Double { sorted[min(v.count - 1, Int(f * n))] }
        let within = { (s: Double) in Double(v.filter { abs($0) <= s }.count) / n * 100 }
        print(String(format: "%@ (n=%d)\n    median %+.0f s, middle 80%% %+.0f to %+.0f s, worst %+.0f / %+.0f s;"
                     + "  within 15 s: %.0f%%, 30 s: %.0f%%, 60 s: %.0f%%",
                     name, v.count, q(0.5), q(0.1), q(0.9), sorted.first!, sorted.last!, within(15), within(30), within(60)))
    }
    let glides = planner.glideLog ?? []
    print(String(format: "%.0f s of motion, %d glides, %d feed downloads (every 15 s for the actual times; every 30 s for the app)",
                 seconds, glides.count, downloads))
    print("Actual arrivals: \(history.arrivalsFromStopped) from the first 'stopped at' report, \(history.arrivalsFromPrediction) from the last prediction before arriving")
    print("Positive = the dot is later than the real train; negative = earlier.\n")
    summary("Arrival at a station: dot vs real train", arrivalError)
    summary("Arrival after a catch-up glide: dot vs real train", catchUpArrivalError)
    summary("Departure from a station: dot vs real train", departureError)
    print("\nWhere the arrival difference comes from:")
    summary("  MTA prediction (when the glide started) vs actual", predictionError)
    summary("  Dot vs the prediction it aimed for", aimError)
    exit(0)
}

if arguments.contains("--plan-report") {
    // Runs MotionPlanner on live data for --seconds (default 90), once a second, across real feed refreshes
    // (every 30 s, like the app), and reports how trains move: glide speeds, how many move at once, and how
    // often the planner had to catch up or (worst case) fade a train to a new place.
    // With --simulate-outage FEED[,FEED…] (or "all"), those feeds count as failed in every download after the
    // first, to check that FeedCache keeps their trains on screen.
    let view = SubwayView(frame: .zero)
    guard let hooks = view.testHooks else { fail("network.json isn't bundled") }
    let outage = Set((value(after: "--simulate-outage") ?? "").split(separator: ",").map(String.init))
    var cache = FeedCache(feeds: hooks.network.settings.feeds, keepFor: hooks.network.settings.staleAfterS)
    var downloads = 0
    func download() -> [Trip] {
        var result: (feeds: [String: [Trip]], fetchedAt: Double)?
        let done = DispatchSemaphore(value: 0)
        Task.detached { result = await FeedClient.fetchEach(settings: hooks.network.settings); done.signal() }
        done.wait()
        var fresh = result!.feeds
        if downloads > 0 { fresh = fresh.filter { !outage.contains($0.key) && !outage.contains("all") } }
        downloads += 1
        cache.receive(fresh, at: result!.fetchedAt)
        return cache.trips
    }
    let planner = MotionPlanner(locator: hooks.locator)
    let seconds = Double(value(after: "--seconds") ?? "90") ?? 90
    let start = Date().timeIntervalSince1970
    var trips = download(), lastDownload = start
    var speeds: [Double] = [], durations: [Double] = [], movingCounts: [Int] = []
    var removed = 0
    var tick = start
    while tick < start + seconds {
        Thread.sleep(forTimeInterval: max(0, tick - Date().timeIntervalSince1970))
        if tick - lastDownload >= 30 { trips = download(); lastDownload = tick }
        for command in planner.update(trips: trips, now: tick) {
            if case .travel(_, let path, let duration) = command {
                durations.append(duration)
                speeds.append(Double(Polyline(path).length) / duration)
            }
            if case .remove = command { removed += 1 }
        }
        movingCounts.append(planner.counts.moving)
        tick += 1
    }
    func pct(_ v: [Double], _ q: Double) -> Double { v.isEmpty ? 0 : v.sorted()[min(v.count - 1, Int(q * Double(v.count)))] }
    let s = planner.stats
    print(String(format: "%.0f s, %d feed downloads: %d glides started", seconds, Int(seconds / 30) + 1, s.travels))
    print(String(format: "glide speed (map units/s): median %.2f, 10%% %.2f, 90%% %.2f, max %.2f   (real trains ≈ 0.38)",
                 pct(speeds, 0.5), pct(speeds, 0.1), pct(speeds, 0.9), speeds.max() ?? 0))
    print(String(format: "glide duration (s): median %.1f, 10%% %.1f, 90%% %.1f", pct(durations, 0.5), pct(durations, 0.1), pct(durations, 0.9)))
    print(String(format: "trains gliding at once: mean %.0f, min %d, max %d", Double(movingCounts.reduce(0, +)) / Double(max(movingCounts.count, 1)),
                 movingCounts.min() ?? 0, movingCounts.max() ?? 0))
    print("catch-ups: \(s.catchUps), waits because ahead: \(s.waitsAhead), fades to a new place (jumps): \(s.teleports)")
    print("jump reasons: \(s.teleportReasons)")
    print("dots removed (trip ended, left the feed, or a jump): \(removed)")
    if !outage.isEmpty { print("simulated outage of \(outage.sorted()) after the first download; failed in last round: \(cache.failed)") }
    exit(0)
}

let wantsSnapshot = value(after: "--snapshot"), wantsDump = value(after: "--dump-placements")
if wantsSnapshot != nil || wantsDump != nil {
    let size = CGSize(width: value(after: "--width").flatMap(Double.init) ?? 1512,
                      height: value(after: "--height").flatMap(Double.init) ?? 982)
    // --home ID[,ID…]: snapshot with these home stations, without changing the saved choice.
    // --layout split|closeUp: snapshot in that layout (also without changing the saved choice).
    let settings = SubwaySettings(
        homeStations: value(after: "--home")?.split(separator: ",").map(String.init) ?? SubwaySettings().homeStations,
        layout: value(after: "--layout").flatMap(SubwaySettings.Layout.init) ?? .split)
    settings.magnification = value(after: "--magnification").flatMap(Double.init)  // --magnification 3 (omit = Fit stations)
    let view = SubwayView(frame: CGRect(origin: .zero, size: size), settings: settings)
    guard let hooks = view.testHooks else { fail("network.json isn't bundled: run the notebook's §8 export and rebuild") }
    if let feeds = value(after: "--simulate-outage") {
        view.simulatedOutage = Set(feeds.split(separator: ",").map(String.init))  // snapshot as if those just failed
    }

    let data = commandLineTrips(network: hooks.network)  // nil = no trains (map only)
    var placements: [(trip: Trip, placement: Placement)] = []
    let start = CFAbsoluteTimeGetCurrent()
    if let (trips, now) = data {
        placements = trips.map { ($0, hooks.locator.locate($0, now: now)) }
    }
    let placeSeconds = CFAbsoluteTimeGetCurrent() - start

    if let path = wantsDump {
        let rows: [[String: Any]] = placements.map { trip, p in
            ["feed": trip.feed, "trip_id": trip.tripID, "how": p.how,
             "x": p.point.map { Double($0.x) } ?? NSNull(), "y": p.point.map { Double($0.y) } ?? NSNull()]
        }
        let data = try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])
        try data.write(to: URL(fileURLWithPath: path))
        print("wrote \(placements.count) placements to \(path)")
    }
    if let path = wantsSnapshot {
        let snapStart = CFAbsoluteTimeGetCurrent()
        guard let png = view.snapshotPNG(size: size, scale: 2, trips: data?.trips ?? [],
                                         now: data?.now ?? Date().timeIntervalSince1970)
        else { fail("snapshot failed: is map_black.pdf in the app bundle?") }
        try png.write(to: URL(fileURLWithPath: path))
        print(String(format: "wrote %@ (%.0f×%.0f px, %d trains) in %.0f ms", path, size.width * 2, size.height * 2,
                     placements.filter { $0.placement.point != nil }.count, (CFAbsoluteTimeGetCurrent() - snapStart) * 1000))
    }
    if !placements.isEmpty {
        print(String(format: "placed %d trips in %.1f ms", placements.count, placeSeconds * 1000))
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = PreviewAppDelegate(startFullScreen: arguments.contains("--fullscreen"))
app.delegate = delegate
app.setActivationPolicy(.regular)  // a normal app: Dock icon, menu bar, can be frontmost
app.run()

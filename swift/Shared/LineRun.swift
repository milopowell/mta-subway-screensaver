import CoreGraphics
import Foundation

// Line runs: one train at a time along each of a route's stop patterns, from its first station to its last, moved by
// the app's own MotionPlanner (fed by SimulatedFeed, as in the sandbox), with every move its dot makes checked
// against the map. The preview app's --line-runs runs every pattern on a simulated clock and prints what it finds;
// the sandbox's Line runs section plays the same runs on the map, one after another, and lists the problems.

/// Checks one train's run along a whole stop pattern: give it every command the planner sends (`observe(_:now:)`) and
/// every glide the planner logs (`observe(glide:)`), then call `finish(now:)`. Problems collects what looked wrong.
final class LineRunCheck {
    /// What can go wrong on a run.
    enum Kind: String, CaseIterable {
        case skipped = "skips a station"  // a glide passes a station the train stops at, or a station is never reached
        case outOfOrder = "out of order"  // a glide from or to a station that isn't next in the pattern
        case jump = "jumps"  // the dot moves without gliding (a slide or a glide starting away from the dot)
        case fade = "fades out"  // the dot disappears before the run ends
        case standsOff = "stands off its circle"  // standing at a station away from the route's circle there
        case straight = "straight line"  // a glide that doesn't follow the drawn track
        case offTrack = "off the track"  // a glide away from every drawn line (on its own line or the one it shares)
        case longWay = "long way round"  // a glide much longer than the distance between the two stations
        case doublesBack = "doubles back"  // a glide that turns back on itself
        case hiddenOnTop = "hidden on top"  // hidden though the map draws no line over it there
        case shownUnder = "shown under a line"  // drawn on top of a line the map draws over it
        case offTimetable = "off the timetable"  // a catch-up, or arriving well before or after the timetable
    }

    struct Problem {
        let kind: Kind
        let route: String
        /// The hop (station IDs); the same station twice for a problem standing at a station.
        let from: String, to: String
        /// Where on the map (map units).
        let at: CGPoint
        let detail: String
    }

    let route: String
    /// The pattern's stations, in travel order.
    let stations: [String]
    /// The planner's key for this train (SimulatedFeed trains are "sandbox|T<id>").
    let key: String
    private(set) var problems: [Problem] = []
    /// Every glide the dot made, in order (for drawing the run).
    private(set) var glides: [MotionPlanner.Glide] = []
    /// True once the dot has left the map.
    private(set) var ended = false
    /// The planner's reason for the last time it stood this train somewhere new (MotionPlanner.standTrace), added to
    /// a jump's details.
    var plannerReason: String?

    private let locator: Locator
    /// When the train leaves the data (its last departure): removing the dot before then is a fade.
    private let leavesAt: Double
    /// Where the dot is, or is gliding to; nil before it first appears (the sandbox follows it).
    private(set) var position: CGPoint?
    /// Index (in `stations`) of the last station the dot reached.
    private var reached = 0
    /// When the dot's current glide ends: a new position before then cuts the glide short.
    private var glideEnds = -Double.infinity

    init(route: String, stations: [String], key: String, leavesAt: Double, locator: Locator) {
        self.route = route
        self.stations = stations
        self.key = key
        self.leavesAt = leavesAt
        self.locator = locator
    }

    private func add(_ kind: Kind, _ from: String, _ to: String, at: CGPoint, _ detail: String) {
        problems.append(Problem(kind: kind, route: route, from: from, to: to, at: at, detail: detail))
    }

    /// The station the dot is at or just left (for problems that happen standing).
    private var here: String { stations[min(reached, stations.count - 1)] }

    // ---- What the dot does ----

    /// One tick of the run: the planner decides what every train does, and the check looks at what it decided for this
    /// train (its commands, its new glides, and the planner's reasons for any move or fade). Returns every command,
    /// for drawing. The planner needs `glideLog` on.
    func step(_ planner: MotionPlanner, trips: [Trip], now: Double) -> [TrainCommand] {
        // Before: the planner's fade reasons and glides so far.
        let fadesBefore = planner.stats.teleportReasons
        let logged = planner.glideLog?.count ?? 0
        // The planner's reasons for standing a train somewhere new.
        planner.standTrace = { [weak self] key, why, before in
            if key == self?.key { self?.plannerReason = "\(why), was \(before)" }
        }
        let commands = planner.update(trips: trips, now: now)
        // A new fade reason (the planner counts them by reason).
        if let reason = planner.stats.teleportReasons.first(where: { $0.value != fadesBefore[$0.key] })?.key {
            plannerReason = reason
        }
        // This train's commands and new glides.
        observe(commands, now: now)
        for glide in planner.glideLog?[logged...] ?? [] { observe(glide: glide) }
        return commands
    }

    /// Looks at the planner's commands for this train: where it stands, where each glide starts, and when it leaves.
    func observe(_ commands: [TrainCommand], now: Double) {
        for command in commands {
            switch command {
            case .place(let key, let point, let look, _, _) where key == self.key:
                // Jump: placed while still gliding (the dot snaps to the glide's end, or elsewhere).
                if now < glideEnds - 0.5, let position {
                    add(.jump, here, here, at: position, String(format: "cut a glide short %.0f s before its end", glideEnds - now)
                        + (plannerReason.map { " (planner: \($0))" } ?? ""))
                    glideEnds = -.infinity
                } else if let position, position.distance(to: point) > 3 {
                    // Jump: the dot moved without a glide.
                    add(.jump, here, here, at: point, String(format: "moved %.0f units without gliding", position.distance(to: point))
                        + (plannerReason.map { " (planner: \($0))" } ?? ""))
                }
                // Standing at a station: on the route's circle there (or the circle it borrows on a reroute).
                if look == .stopped {
                    let circle = locator.standPoint(route: route, station: here)
                    if circle.distance(to: point) > 3 {
                        add(.standsOff, here, here, at: point, String(format: "%.0f units from its circle", circle.distance(to: point))
                            + (plannerReason.map { " (planner: \($0))" } ?? ""))
                    }
                }
                // Back after leaving: it faded out and came back.
                if ended { add(.fade, here, here, at: point, "came back after leaving the map") }
                ended = false
                position = point
            case .travel(let key, let path, let duration) where key == self.key:
                glideEnds = now + duration
                // Jump: the glide starts somewhere other than the dot.
                if let position, let first = path.first, position.distance(to: first) > 3 {
                    add(.jump, here, here, at: first, String(format: "glide starts %.0f units from the dot", position.distance(to: first)))
                }
                position = path.last
            case .remove(let key) where key == self.key:
                glideEnds = -.infinity
                // Fade: gone before the train left the data.
                if now < leavesAt - 1, let position {
                    add(.fade, here, here, at: position, String(format: "removed %.0f s before the run ended", leavesAt - now)
                        + (plannerReason.map { " (planner: \($0))" } ?? ""))
                }
                ended = true
                position = nil
            default:
                break
            }
        }
    }

    /// Checks one glide: which hop it is, the track it follows, and where it hides under other lines.
    func observe(glide g: MotionPlanner.Glide) {
        guard g.key == key else { return }
        glides.append(g)
        let path = g.path
        let start = path.first ?? .zero

        // Order: each glide should be the next hop of the pattern.
        if let i = stations[reached...].firstIndex(of: g.from), let j = stations[(i + 1)...].firstIndex(of: g.to) {
            if i != reached {
                add(.skipped, stations[reached], g.from, at: start, "jumped ahead to \(name(g.from)) without a glide")
            }
            if j > i + 1 {
                let missed = stations[(i + 1)..<j].map(name).joined(separator: ", ")
                add(.skipped, g.from, g.to, at: start, "glides past \(missed)")
            }
            reached = j
        } else if g.kind != .placeholder {
            add(.outOfOrder, g.from, g.to, at: start, "expected a glide from \(name(here))")
        }

        // Timing: a catch-up or placeholder means the dot fell behind; otherwise it should arrive on time.
        if g.kind == .catchUp || g.kind == .placeholder {
            add(.offTimetable, g.from, g.to, at: start, "a \(g.kind.rawValue) glide")
        } else if abs(g.end - g.predictedArrival) > 20 {
            add(.offTimetable, g.from, g.to, at: path.last ?? start,
                String(format: "arrives %+.0f s from the timetable", g.end - g.predictedArrival))
        }

        // Track: along the drawn track, on its own colored line or on another line's where it shares the track (the 4
        // to New Lots Av runs on the 3's red line, the late-night E on the M and R's).
        if !g.followsTrack {
            add(.straight, g.from, g.to, at: start, String(format: "%.0f units in a straight line", g.length))
        } else if locator.distanceFromOwnLine(route: route, path: path) > 3 {
            let distance = locator.distanceFromAnyLine(path: path)
            if distance > 3 {
                add(.offTrack, g.from, g.to, at: start, String(format: "%.0f units from the nearest line on average", distance))
            }
        }

        // Shape: not much longer than the straight distance, and never turning back on itself.
        if let first = path.first, let last = path.last {
            let direct = first.distance(to: last)
            if g.length > 1.6 * direct + 15 {
                add(.longWay, g.from, g.to, at: start, String(format: "%.0f units for %.0f apart", g.length, direct))
            }
        }
        if let turn = LineRunCheck.turnBack(path) {
            add(.doublesBack, g.from, g.to, at: turn, "turns back on itself")
        }

        // Over and under: where the app hides the dot against where the map draws another line over it, one map unit
        // at a time. Only a stretch of 6 units or more in a row counts (about a dot across): shorter ones are the seams
        // where two pieces of one line meet, or the edge of a band, where nothing shows.
        let check = locator.visibilityCheck(route: route, path: path)
        if let run = LineRunCheck.longestRun(check.map { $0.actual && !$0.expected }), run.count >= 6 {
            add(.hiddenOnTop, g.from, g.to, at: check[run.first].point, "hidden for \(run.count) units with no line over it")
        }
        if let run = LineRunCheck.longestRun(check.map { !$0.actual && $0.expected }), run.count >= 6 {
            add(.shownUnder, g.from, g.to, at: check[run.first].point, "drawn over a line for \(run.count) units")
        }
    }

    /// At the end of the run: every station reached, and the dot gone.
    func finish(now: Double) {
        if reached < stations.count - 1 {
            let at = locator.standPoint(route: route, station: stations[reached])
            add(.skipped, stations[reached], stations[stations.count - 1], at: at,
                "never got past \(name(stations[reached])) (\(stations.count - 1 - reached) stations short)")
        }
        if !ended, let position {
            add(.fade, here, here, at: position, "still on the map after the run ended")
        }
    }

    // ---- Helpers ----

    private func name(_ station: String) -> String { locator.stationName(station) }

    /// The longest stretch of `true` in a row: where it starts and how long it is (nil if there's none).
    static func longestRun(_ flags: [Bool]) -> (first: Int, count: Int)? {
        var best: (first: Int, count: Int)?, start = 0
        for (i, flag) in flags.enumerated() {
            if !flag { start = i + 1; continue }
            let count = i - start + 1
            if count > (best?.count ?? 0) { best = (start, count) }
        }
        return best
    }

    /// Where a path turns back on itself (a U-turn of more than 120° over a few map units), or nil. The path is
    /// walked 2 units at a time, comparing the way it heads over the 4 units before each point with the 4 after.
    static func turnBack(_ path: [CGPoint]) -> CGPoint? {
        let line = Polyline(path)
        guard line.length > 10 else { return nil }
        var along: CGFloat = 4
        while along <= line.length - 4 {
            let p = line.point(at: along)
            let before = line.point(at: along - 4), after = line.point(at: along + 4)
            let a = CGVector(dx: p.x - before.x, dy: p.y - before.y), b = CGVector(dx: after.x - p.x, dy: after.y - p.y)
            let la = hypot(a.dx, a.dy), lb = hypot(b.dx, b.dy)
            // cos(120°) = -0.5: sharper than that is turning back.
            if la > 1, lb > 1, (a.dx * b.dx + a.dy * b.dy) / (la * lb) < -0.5 { return p }
            along += 2
        }
        return nil
    }
}

/// Runs patterns one at a time on a simulated clock, without a window (the preview app's --line-runs).
enum LineRunner {
    /// One finished run: which pattern, and its check.
    struct Run {
        let pattern: SubwayNetwork.Pattern
        let check: LineRunCheck
    }

    /// Runs a train along `pattern` from its first station to its last, as scheduled, with a pretend download every
    /// 30 s (like the live feed) and the planner deciding once a second, and returns the check.
    static func run(_ pattern: SubwayNetwork.Pattern, network: SubwayNetwork, locator: Locator) -> Run? {
        // A fixed start time, so every run is the same each time.
        let start: Double = 1_800_000_000
        let feed = SimulatedFeed(network: network)
        guard let train = feed.send(pattern: pattern, pace: 1, now: start) else { return nil }
        let planner = MotionPlanner(locator: locator)
        planner.glideLog = []
        let check = LineRunCheck(route: pattern.route, stations: train.stations, key: "sandbox|T\(train.id)",
                                 leavesAt: train.departures[train.departures.count - 1], locator: locator)
        // Simulated clock: a download every 30 s, the planner every second, until the train has left (plus a margin).
        var trips: [Trip] = [], t = start
        let end = train.departures[train.departures.count - 1] + 60
        while t <= end {
            if Int(t - start) % 30 == 0 { trips = feed.snapshot(now: t) }
            _ = check.step(planner, trips: trips, now: t)
            t += 1
        }
        check.finish(now: t)
        return Run(pattern: pattern, check: check)
    }
}

extension CGPoint {
    /// Straight-line distance to another point.
    func distance(to other: CGPoint) -> CGFloat { hypot(x - other.x, y - other.y) }
}

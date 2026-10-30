import CoreGraphics
import Foundation

/// Replays what really happened (TripHistory) faster than real time, in a loop: the last `window` seconds at
/// `speed` times real speed. With the defaults, 30 minutes play in 90 seconds, then the loop starts again with
/// the newest 30 minutes.
///
/// Every time is known, so there is nothing to predict or correct: at replay time τ a train is either standing
/// at a station (arrived ≤ τ ≤ departed) or on the hop between two stations, which is handed to Core Animation as
/// one glide lasting the real hop time ÷ `speed`. It produces the same TrainCommands as MotionPlanner.
final class TimeLapse {
    /// Times faster than real time.
    var speed: Double = 20
    /// Seconds of history replayed in each loop.
    var window: Double = 1800
    /// History needed before the first loop can start.
    var minimumHistory: Double = 300

    private enum Phase {
        case at(index: Int)  // standing at visits[index]
        case gliding(to: Int)  // on the hop to visits[to]
    }
    private var phases: [String: Phase] = [:]
    private var loop: (wallStart: Double, from: Double, to: Double)?
    private let locator: Locator

    init(locator: Locator) {
        self.locator = locator
    }

    /// The moment being shown (history time), or nil before enough history has been recorded.
    func clock(wall: Double) -> Double? {
        loop.map { $0.from + (wall - $0.wallStart) * speed }
    }

    /// Seconds of history recorded so far.
    func recorded(_ history: TripHistory) -> Double {
        guard let first = history.firstObserved, let last = history.lastObserved else { return 0 }
        return last - first
    }

    /// Forgets the replay (e.g. when switching back to live), so the next update starts a fresh loop.
    func reset() -> [TrainCommand] {
        defer { phases = [:]; loop = nil }
        return phases.keys.map { .remove(key: $0) }
    }

    /// Forgets where the dots are but keeps the loop running: after the view is resized and its dots removed,
    /// the next update draws every train again at the current replay time.
    func redraw() {
        phases = [:]
    }

    /// What every train does now (`wall` = the real time). Empty while there isn't enough history yet.
    func update(history: TripHistory, wall: Double) -> [TrainCommand] {
        var commands: [TrainCommand] = []
        if loop == nil || clock(wall: wall)! > loop!.to {
            // Start a loop with the newest history (fading out the trains of the previous one).
            guard let last = history.lastObserved, recorded(history) >= minimumHistory else { return [] }
            commands += reset()
            loop = (wall, max(history.firstObserved!, last - window), last)
        }
        let tau = clock(wall: wall)!
        var shown = Set<String>()
        for (key, record) in history.records {
            let visits = record.visits
            guard let first = visits.first, tau >= first.arrive else { continue }  // not reached a station yet
            let lastVisit = visits[visits.count - 1]
            if record.ended, tau > lastVisit.depart + 60 { continue }  // run finished a minute ago
            shown.insert(key)
            // Where is the train at τ? The last visit that has begun.
            let i = visits.lastIndex { $0.arrive <= tau }!
            let next = i + 1 < visits.count ? i + 1 : nil
            if tau <= visits[i].depart || next == nil {
                // Standing at a station (or the latest station recorded).
                if case .at(let j)? = phases[key], j == i { continue }
                phases[key] = .at(index: i)
                commands.append(.place(key: key, point: locator.standPoint(route: record.route, station: visits[i].station,
                                                                           from: i > 0 ? visits[i - 1].station : nil,
                                                                           to: next.map { visits[$0].station }),
                                       look: .stopped, route: record.route))
            } else if let n = next {
                // On the hop from visit i to visit n: one glide to the station, lasting what remains of the real hop.
                if case .gliding(let j)? = phases[key], j == n { continue }
                let line = hopPath(route: record.route, from: visits[i].station, to: visits[n].station)
                var path = line.points
                if phases[key] == nil {  // appearing mid-hop (start of a loop): start from where it is now
                    let done = (tau - visits[i].depart) / max(visits[n].arrive - visits[i].depart, 1)
                    path = line.piece(from: CGFloat(done) * line.length, to: line.length).points
                }
                phases[key] = .gliding(to: n)
                commands.append(.travel(key: key, path: path, duration: max((visits[n].arrive - tau) / speed, 0.2)))
            }
        }
        for key in phases.keys where !shown.contains(key) {
            phases[key] = nil
            commands.append(.remove(key: key))
        }
        return commands
    }

    /// The track between two recorded stations: the route's line if they're neighbors, else the hops along one
    /// of its stop patterns (a station can be missing from the record), else a straight line. It always starts and
    /// ends exactly at the two station points, where the dot stands before and after (the colored line can pass
    /// a few map units from a station's circle).
    private func hopPath(route: String, from a: String, to b: String) -> Polyline {
        let start = locator.standPoint(route: route, station: a, to: b), end = locator.standPoint(route: route, station: b, from: a)
        func ending(_ points: [CGPoint]) -> Polyline {
            var points = points
            if let first = points.first, hypot(first.x - start.x, first.y - start.y) > 0.5 { points.insert(start, at: 0) }
            if let last = points.last, hypot(last.x - end.x, last.y - end.y) > 0.5 { points.append(end) }
            return Polyline(points)
        }
        let direct = locator.hopLine(route: route, from: a, to: b)
        if direct.followed { return ending(direct.line.points) }
        var points: [CGPoint] = []
        var here = a
        for _ in 0..<6 {
            guard let leg = locator.catchUpLeg(route: route, from: here, toward: b, maxHops: 6) else { break }
            points += points.isEmpty ? leg.line.points : Array(leg.line.points.dropFirst())
            here = leg.to
            if here == b { return ending(points) }
        }
        return ending(direct.line.points)
    }
}

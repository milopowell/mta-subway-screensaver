import CoreGraphics
import Foundation

/// How a train dot looks. Always the same size, so nothing jumps when a train stops or starts.
enum TrainLook {
    case moving  // bright white with a soft glow
    case stopped  // gray: standing at a station
    case parked  // dim gray: finished its run, or about to start one
}

/// What a train's dot should do, as decided by MotionPlanner. Positions and paths are in map units.
enum TrainCommand {
    /// Stand still at `point` (a station, or a parked position).
    case place(key: String, point: CGPoint, look: TrainLook)
    /// Glide along `path` (the track, from where the train is now to the next station) for `duration`
    /// seconds: one continuous animation that speeds up out of the station and slows into the next.
    case travel(key: String, path: [CGPoint], duration: Double)
    /// The train is gone (finished, or no longer in the feed).
    case remove(key: String)
}

/// Turns each train's predicted timetable into smooth, believable motion.
///
/// Each train is either **stopped** at a station or **traveling** one hop. A hop is handed to Core
/// Animation as a single animation along the track (see `TrainLayers`), so the dot moves continuously
/// with no steps. The planner checks every train once a second and only acts at decision points:
///
/// * **Departing.** A stopped train sets off when its next hop must start so that it arrives at the
///   predicted time while traveling at about `cruiseSpeed` (faster than real trains, so motion is visible).
///   The extra time is spent waiting at the station, so arrival times still match the predictions.
/// * **Arriving.** When a hop's animation ends, the train is stopped at that station.
/// * **Ahead of the predictions** (we arrived before the data says the train does): it simply waits longer.
/// * **Behind** (fresh data says the train is further along): it leaves at once and travels the next hop
///   faster (up to `catchUpSpeed`), one hop at a time, until it has caught up. It never jumps or reverses.
/// * **Lost** (the data puts the train somewhere unconnected, e.g. after a reroute): it fades to the new spot.
final class MotionPlanner {
    /// Average travel speed while moving, in map units per second. Real trains average ~0.4; 1.5 is about
    /// four times faster, so a typical hop takes ~25 s and about twice as many trains move at once as at 2.5.
    /// Higher = brisker motion and longer station waits; lower = dots closer to the real trains mid-hop.
    var cruiseSpeed: Double = 1.5
    /// Fastest a train may travel when catching up with fresh data.
    var catchUpSpeed: Double = 6
    /// Shortest a hop's glide may be, so short hops don't flick past.
    var minTravelSeconds: Double = 4

    /// Counters, for checking behavior (e.g. from the preview app's --plan-report).
    struct Stats { var travels = 0, catchUps = 0, teleports = 0, waitsAhead = 0, teleportReasons: [String: Int] = [:] }
    private(set) var stats = Stats()

    /// One glide, as recorded for the timing report: which hop, and when the dot leaves and arrives.
    struct Glide {
        let key: String, from: String, to: String
        let start: Double, end: Double
        /// The arrival time the predictions gave for this hop when the glide started.
        let predictedArrival: Double
        let catchUp: Bool
    }
    /// When non-nil, every glide is appended here (off by default: the screensaver doesn't need it).
    var glideLog: [Glide]?

    private enum Phase {
        case stopped(station: String?, point: CGPoint, look: TrainLook)
        case traveling(leg: Locator.Leg, start: Double, duration: Double, path: [CGPoint])
    }
    private var phases: [String: Phase] = [:]
    private let locator: Locator

    init(locator: Locator) {
        self.locator = locator
    }

    /// How many trains are traveling / stopped right now (for the status line).
    var counts: (moving: Int, stopped: Int) {
        var moving = 0, stopped = 0
        for phase in phases.values {
            if case .traveling = phase { moving += 1 } else { stopped += 1 }
        }
        return (moving, stopped)
    }

    /// How long a hop's glide takes: the cruise-speed time, but never shorter than `minTravelSeconds` and
    /// never longer than the predictions allow for the hop.
    private func travelTime(_ leg: Locator.Leg) -> Double {
        let cruise = max(Double(leg.line.length) / cruiseSpeed, minTravelSeconds)
        return min(cruise, max(leg.arrive - leg.depart, minTravelSeconds))
    }

    /// Decides what every train does now. Returns commands only for trains whose plan changed.
    func update(trips: [Trip], now: Double) -> [TrainCommand] {
        var commands: [TrainCommand] = []
        var seen = Set<String>()
        for trip in trips {
            let key = "\(trip.feed)|\(trip.tripID)"
            let base = locator.locate(trip, now: now)  // the notebook's rules decide whether it's shown
            guard let basePoint = base.point else { continue }
            seen.insert(key)

            guard base.kind != .parked, let legs = locator.legs(for: trip, now: now) else {
                // Parked, or no timeline: stand where the notebook places it.
                let look: TrainLook = base.kind == .parked ? .parked : .stopped
                commands += stop(key, station: nil, point: basePoint, look: look)
                continue
            }
            // The hop the predictions say the train is on (or about to start); nil = past its last prediction.
            guard let current = legs.first(where: { now <= $0.arrive }) else {
                let last = legs[legs.count - 1]
                commands += stop(key, station: last.to, point: locator.stationPoint(route: last.route, station: last.to),
                                 look: .stopped)
                continue
            }
            commands += advance(key, legs: legs, current: current, now: now)
        }
        for key in phases.keys where !seen.contains(key) {
            phases[key] = nil
            commands.append(.remove(key: key))
        }
        return commands
    }

    /// The state machine for one train with a timeline (see the class description).
    private func advance(_ key: String, legs: [Locator.Leg], current: Locator.Leg, now: Double) -> [TrainCommand] {
        let departAt = current.arrive - travelTime(current)  // when it must leave to arrive on time at cruise speed

        switch phases[key] {
        case nil:
            // First time we see this train: start it in the right place.
            if now < departAt {
                return stop(key, station: current.from, point: stationPoint(current, at: current.from), look: .stopped)
            }
            let done = (now - departAt) / max(current.arrive - departAt, 1e-6)  // fraction of the glide already done
            let line = current.line
            let rest = line.piece(from: CGFloat(done) * line.length, to: line.length)
            return travel(key, leg: current, path: rest.points, duration: max(current.arrive - now, 1), now: now)

        case .traveling(let leg, let start, let duration, _)?:
            if now < start + duration { return [] }  // still gliding: never interrupt a hop
            // Arrived: now stopped at the station; decide what's next in the same tick.
            phases[key] = .stopped(station: leg.to, point: stationPoint(leg, at: leg.to), look: .stopped)
            return [.place(key: key, point: stationPoint(leg, at: leg.to), look: .stopped)]
                + advance(key, legs: legs, current: current, now: now)

        case .stopped(var station, let point, _)?:
            if station == nil {
                // A parked train (or one that had no timeline) isn't tied to a station yet: recognize the station
                // from where its dot is, so it simply sets off from there instead of fading out and back in.
                func near(_ s: String, _ leg: Locator.Leg) -> Bool {
                    let p = stationPoint(leg, at: s)
                    return hypot(p.x - point.x, p.y - point.y) < 3
                }
                station = legs.first(where: { near($0.from, $0) })?.from ?? (near(current.to, current) ? current.to : nil)
                if let station { phases[key] = .stopped(station: station, point: point, look: .stopped) }
            }
            if station == nil {
                // Still unknown but close by: glide straight to where the train should be.
                let target = stationPoint(current, at: current.from)
                let distance = Double(hypot(target.x - point.x, target.y - point.y))
                if distance < 60 {
                    stats.catchUps += 1
                    let hop = Locator.Leg(route: current.route, from: current.from, to: current.from, depart: now,
                                          arrive: now, line: Polyline([point, target]))
                    let duration = max(distance / catchUpSpeed, minTravelSeconds / 2)
                    return travel(key, leg: hop, path: hop.line.points, duration: duration, now: now, catchUp: true)
                }
            }
            if station == current.from {
                if now >= departAt {  // time to go
                    let duration = max(current.arrive - now, Double(current.line.length) / catchUpSpeed, minTravelSeconds / 2)
                    return travel(key, leg: current, path: current.line.points, duration: duration, now: now)
                }
                return stop(key, station: station, point: stationPoint(current, at: current.from), look: .stopped)
            }
            if let station, station == current.to
                || legs.contains(where: { $0.from == station && $0.arrive > current.arrive }) {
                stats.waitsAhead += 1
                return []  // we're ahead of the predictions: keep waiting here until they catch up
            }
            // Fresh data says the train is further along: leave now and catch up, one hop at a time.
            if let station, let behind = legs.first(where: { $0.from == station && $0.arrive < current.arrive })
                ?? locator.catchUpLeg(route: current.route, from: station, toward: current.from, maxHops: 4) {
                stats.catchUps += 1
                let duration = max(Double(behind.line.length) / catchUpSpeed, minTravelSeconds / 2)
                return travel(key, leg: behind, path: behind.line.points, duration: duration, now: now, catchUp: true)
            }
            // Somewhere unconnected (e.g. a reroute or a brand-new prediction): fade to the right place.
            stats.teleports += 1
            let reason = station == nil ? "parked placeholder matched to a train elsewhere"
                : (legs.contains { $0.to == station } ? "station is a hop's destination"
                   : (locator.catchUpLeg(route: current.route, from: station!, toward: current.from, maxHops: 40) != nil
                      ? "behind by more than 4 stops" : "not on this route's patterns"))
            stats.teleportReasons[reason, default: 0] += 1
            phases[key] = nil
            return [.remove(key: key)] + advance(key, legs: legs, current: current, now: now)
        }
    }

    private func stationPoint(_ leg: Locator.Leg, at station: String) -> CGPoint {
        locator.stationPoint(route: leg.route, station: station)
    }

    /// Stand still; only emits a command if the position or look actually changes.
    private func stop(_ key: String, station: String?, point: CGPoint, look: TrainLook) -> [TrainCommand] {
        if case .stopped(_, let p, let l)? = phases[key], l == look, hypot(p.x - point.x, p.y - point.y) < 0.01 {
            return []
        }
        phases[key] = .stopped(station: station, point: point, look: look)
        return [.place(key: key, point: point, look: look)]
    }

    private func travel(_ key: String, leg: Locator.Leg, path: [CGPoint], duration: Double, now: Double,
                        catchUp: Bool = false) -> [TrainCommand] {
        stats.travels += 1
        // Start and end exactly at the station dots: the colored line can pass a few map units from a station's
        // circle, and the dot stands at the circle before and after the glide (otherwise it would snap).
        var path = path
        if leg.from != leg.to {
            let start = stationPoint(leg, at: leg.from), end = stationPoint(leg, at: leg.to)
            if path.first == leg.line.points.first, let first = path.first, hypot(first.x - start.x, first.y - start.y) > 0.5 {
                path.insert(start, at: 0)
            }
            if let last = path.last, hypot(last.x - end.x, last.y - end.y) > 0.5 { path.append(end) }
        }
        glideLog?.append(Glide(key: key, from: leg.from, to: leg.to, start: now, end: now + duration,
                               predictedArrival: leg.arrive, catchUp: catchUp))
        phases[key] = .traveling(leg: leg, start: now, duration: duration, path: path)
        return [.travel(key: key, path: path, duration: duration)]
    }

    /// Forgets every train (e.g. when the time-lapse takes over), returning commands that fade their dots out.
    func reset() -> [TrainCommand] {
        defer { phases = [:] }
        return phases.keys.map { .remove(key: $0) }
    }

    /// Commands that recreate every train's current state from scratch: used after the view is resized, when
    /// animations must be restarted in the new coordinates. Traveling trains continue from where they are.
    func resync(now: Double) -> [TrainCommand] {
        phases.compactMap { key, phase -> TrainCommand? in
            switch phase {
            case .stopped(_, let point, let look):
                return .place(key: key, point: point, look: look)
            case .traveling(_, let start, let duration, let path):
                let t = min(max((now - start) / duration, 0), 1)
                let line = Polyline(path)
                let rest = line.piece(from: CGFloat(MotionPlanner.easeInOut(t)) * line.length, to: line.length)
                return .travel(key: key, path: rest.points, duration: max(start + duration - now, 0.1))
            }
        }
    }

    /// Core Animation's ease-in-ease-out curve (cubic Bézier 0.42, 0, 0.58, 1): time fraction → distance fraction.
    static func easeInOut(_ t: Double) -> Double {
        // Solve x(s) = t for the curve parameter s by bisection, then return y(s).
        func bezier(_ s: Double, _ p1: Double, _ p2: Double) -> Double {
            3 * (1 - s) * (1 - s) * s * p1 + 3 * (1 - s) * s * s * p2 + s * s * s
        }
        var lo = 0.0, hi = 1.0
        for _ in 0..<30 {
            let mid = (lo + hi) / 2
            if bezier(mid, 0.42, 0.58) < t { lo = mid } else { hi = mid }
        }
        return bezier((lo + hi) / 2, 0, 1)
    }
}

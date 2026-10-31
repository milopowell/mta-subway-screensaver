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
    /// Stand still at `point` (a station, or a parked position). `route`: the train's route, so a train standing at a
    /// station can light up that route's bullet there; `heading`: the way it will leave (a unit vector in map units,
    /// along the track toward its next stop), which the bullet points, or nil when not known.
    case place(key: String, point: CGPoint, look: TrainLook, route: String? = nil, heading: CGVector? = nil)
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
    /// Fastest a train may travel when catching up with fresh data (a little over twice the cruise speed).
    var catchUpSpeed: Double = 3.5
    /// Corrections (catching up, fading to a new place, moving a parked dot) wait a delay of up to this many seconds,
    /// fixed per train, so after each download they trickle out instead of all happening at once.
    var correctionSpread: Double = 12
    /// Shortest a hop's glide may be, so short hops don't flick past.
    var minTravelSeconds: Double = 4
    /// Longest a hop's glide may be: a hop drawn long on the map (96 St to 110 St on the 2 and 3, around Central
    /// Park) glides faster instead of crawling for minutes; it still arrives on time.
    var maxTravelSeconds: Double = 40

    /// Counters, for checking behavior (e.g. from the preview app's --plan-report).
    struct Stats { var travels = 0, catchUps = 0, teleports = 0, waitsAhead = 0, teleportReasons: [String: Int] = [:] }
    private(set) var stats = Stats()

    /// One glide, as recorded for the timing report: which hop, and when the dot leaves and arrives.
    /// Why a glide happened.
    enum GlideKind: String {
        case normal  // the next hop of the timetable
        case firstSight = "first sight"  // a train seen for the first time, already part-way along a hop
        case catchUp = "catch-up"  // behind the predictions: hurrying along a hop it should have finished
        case placeholder  // a parked dot that wasn't at a station, gliding straight to where the train is
    }

    struct Glide {
        let key: String, route: String, from: String, to: String
        let start: Double, end: Double
        /// The arrival time the predictions gave for this hop when the glide started.
        let predictedArrival: Double
        let kind: GlideKind
        /// Length of the path in map units, and whether it follows the drawn track (false = a straight line).
        let length: Double, followsTrack: Bool
        /// The path itself (map units).
        let path: [CGPoint]
        var catchUp: Bool { kind == .catchUp || kind == .placeholder }
    }
    /// When non-nil, every glide is appended here (off by default: the screensaver doesn't need it).
    var glideLog: [Glide]?

    private enum Phase {
        case stopped(station: String?, point: CGPoint, look: TrainLook, route: String?, heading: CGVector?)
        case traveling(leg: Locator.Leg, start: Double, duration: Double, path: [CGPoint])
    }
    private var phases: [String: Phase] = [:]
    /// Corrections waiting for their train's delay: what the correction is, and when it may happen.
    private var pendingCorrections: [String: (what: String, due: Double)] = [:]
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
        return min(cruise, max(leg.arrive - leg.depart, minTravelSeconds), maxTravelSeconds)
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
                // Parked, or no timeline: stand where the notebook places it (a move waits for its turn).
                let look: TrainLook = base.kind == .parked ? .parked : .stopped
                commands += stop(key, station: nil, point: basePoint, look: look, now: now, route: trip.routeID)
                continue
            }
            // The hop the predictions say the train is on (or about to start); nil = past its last prediction.
            guard let current = legs.first(where: { now <= $0.arrive }) else {
                let last = legs[legs.count - 1]
                commands += stop(key, station: last.to, point: locator.standPoint(route: last.route, station: last.to, from: last.from),
                                 look: .stopped, now: now, route: last.route)
                continue
            }
            commands += advance(key, legs: legs, current: current, now: now)
        }
        // Trains no longer in the data (run finished, or reassigned) fade out, each in its turn.
        for key in phases.keys where !seen.contains(key) && correctionDue(key, "gone", now: now) {
            phases[key] = nil
            pendingCorrections[key] = nil
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
                return stop(key, station: current.from, point: stationPoint(current, at: current.from), look: .stopped, now: now,
                            route: current.route, heading: departure(current))
            }
            let done = (now - departAt) / max(current.arrive - departAt, 1e-6)  // fraction of the glide already done
            let line = current.line
            let rest = line.piece(from: CGFloat(done) * line.length, to: line.length)
            return travel(key, leg: current, path: rest.points, duration: min(max(current.arrive - now, 1), maxTravelSeconds),
                          now: now, kind: .firstSight)

        case .traveling(let leg, let start, let duration, _)?:
            if now < start + duration { return [] }  // still gliding: never interrupt a hop
            // Arrived: now stopped at the station; decide what's next in the same tick.
            // Its next hop is the one after this (the timeline's legs are in order): the way it will leave.
            let next = legs.first { $0.from == leg.to && $0.to != leg.to && $0.arrive > leg.arrive }
            let heading = next.flatMap { departure($0) }
            phases[key] = .stopped(station: leg.to, point: stationPoint(leg, at: leg.to), look: .stopped, route: leg.route,
                                   heading: heading)
            return [.place(key: key, point: stationPoint(leg, at: leg.to), look: .stopped, route: leg.route, heading: heading)]
                + advance(key, legs: legs, current: current, now: now)

        case .stopped(var station, let point, _, let route, let heading)?:
            if station == nil {
                // A parked train (or one that had no timeline) isn't tied to a station yet: recognize the station
                // from where its dot is, so it simply sets off from there instead of fading out and back in.
                func near(_ s: String, _ leg: Locator.Leg) -> Bool {
                    let p = stationPoint(leg, at: s)
                    return hypot(p.x - point.x, p.y - point.y) < 3
                }
                station = legs.first(where: { near($0.from, $0) })?.from ?? (near(current.to, current) ? current.to : nil)
                if let station {
                    phases[key] = .stopped(station: station, point: point, look: .stopped, route: route, heading: heading)
                }
            }
            if station == nil {
                // Still unknown but very close (another circle of the same station): glide straight there. Further
                // away it fades across below, rather than cutting across the map in a straight line.
                let target = stationPoint(current, at: current.from)
                let distance = Double(hypot(target.x - point.x, target.y - point.y))
                if distance < 12 {
                    stats.catchUps += 1
                    let hop = Locator.Leg(route: current.route, from: current.from, to: current.from, depart: now,
                                          arrive: now, line: Polyline([point, target]))
                    let duration = max(distance / catchUpSpeed, minTravelSeconds / 2)
                    return travel(key, leg: hop, path: hop.line.points, duration: duration, now: now, kind: .placeholder)
                }
            }
            if station == current.from {
                pendingCorrections[key] = nil  // on schedule
                if now >= departAt {  // time to go
                    let duration = min(max(current.arrive - now, Double(current.line.length) / catchUpSpeed, minTravelSeconds / 2),
                                       maxTravelSeconds)
                    return travel(key, leg: current, path: current.line.points, duration: duration, now: now)
                }
                return stop(key, station: station, point: stationPoint(current, at: current.from), look: .stopped, now: now,
                            route: current.route, heading: departure(current))
            }
            if let station, station == current.to
                || legs.contains(where: { $0.from == station && $0.arrive > current.arrive }) {
                stats.waitsAhead += 1
                pendingCorrections[key] = nil
                return []  // we're ahead of the predictions: keep waiting here until they catch up
            }
            // Fresh data says the train is further along or somewhere else: correct it, but only when this train's
            // turn comes (meanwhile it waits where it is).
            guard correctionDue(key, "from \(station ?? "parked") toward \(current.from)", now: now) else { return [] }
            // Further along: leave now and catch up, one hop at a time.
            if let station, let behind = legs.first(where: { $0.from == station && $0.arrive < current.arrive })
                ?? locator.catchUpLeg(route: current.route, from: station, toward: current.from, maxHops: 4) {
                stats.catchUps += 1
                let duration = max(Double(behind.line.length) / catchUpSpeed, minTravelSeconds / 2)
                return travel(key, leg: behind, path: behind.line.points, duration: duration, now: now, kind: .catchUp)
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

    /// True when a correction for this train may happen now: each train waits its own fixed delay (up to
    /// `correctionSpread` seconds) after a correction first becomes needed; a different correction starts the wait
    /// again.
    private func correctionDue(_ key: String, _ what: String, now: Double) -> Bool {
        if let pending = pendingCorrections[key], pending.what == what {
            guard now >= pending.due else { return false }
            pendingCorrections[key] = nil
            return true
        }
        // A stable per-train delay (FNV-1a hash of the train's key), the same on every run.
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in key.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        let delay = Double(hash % 1000) / 1000 * correctionSpread
        if delay < 0.5 { return true }
        pendingCorrections[key] = (what, now + delay)
        return false
    }

    private func stationPoint(_ leg: Locator.Leg, at station: String) -> CGPoint {
        // A rerouted train stands on the circle of a line making the same hop (Locator.standPoint).
        locator.standPoint(route: leg.route, station: station, from: station == leg.to && leg.from != leg.to ? leg.from : nil,
                           to: station == leg.from && leg.from != leg.to ? leg.to : nil)
    }

    /// The way a train standing at the start of `leg` will leave (Locator.departureHeading).
    private func departure(_ leg: Locator.Leg) -> CGVector? {
        leg.from == leg.to ? nil : locator.departureHeading(route: leg.route, from: leg.from, to: leg.to)
    }

    /// Stand still; only emits a command if the position, look or heading actually changes. Moving a standing dot
    /// elsewhere (more than 3 map units) is a correction, so it waits for this train's turn.
    private func stop(_ key: String, station: String?, point: CGPoint, look: TrainLook, now: Double,
                      route: String?, heading: CGVector? = nil) -> [TrainCommand] {
        switch phases[key] {
        case .stopped(_, let p, let l, _, let h)?:
            let moved = hypot(p.x - point.x, p.y - point.y)
            if l == look, moved < 0.01, h == heading { return [] }
            if moved > 3, !correctionDue(key, "move to \(Int(point.x)),\(Int(point.y))", now: now) { return [] }
        case .traveling(_, _, _, let path)?:
            // Mid-glide, and the data now has it standing somewhere: unless that's where it's heading, it's a
            // correction too (meanwhile it keeps gliding).
            if let end = path.last, hypot(end.x - point.x, end.y - point.y) > 3,
               !correctionDue(key, "move to \(Int(point.x)),\(Int(point.y))", now: now) { return [] }
        case nil:
            break
        }
        phases[key] = .stopped(station: station, point: point, look: look, route: route, heading: heading)
        return [.place(key: key, point: point, look: look, route: route, heading: heading)]
    }

    private func travel(_ key: String, leg: Locator.Leg, path: [CGPoint], duration: Double, now: Double,
                        kind: GlideKind = .normal) -> [TrainCommand] {
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
        if glideLog != nil {
            let follows = kind != .placeholder && locator.hopLine(route: leg.route, from: leg.from, to: leg.to).followed
            glideLog?.append(Glide(key: key, route: leg.route, from: leg.from, to: leg.to, start: now, end: now + duration,
                                   predictedArrival: leg.arrive, kind: kind, length: Double(Polyline(path).length),
                                   followsTrack: follows, path: path))
        }
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
            case .stopped(_, let point, let look, let route, let heading):
                return .place(key: key, point: point, look: look, route: route, heading: heading)
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

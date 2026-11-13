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
    /// A standing train moves elsewhere only once the data has put it there for this many seconds (longer than a
    /// download): the predictions for a parked or unscheduled train sometimes put it at one station, then the next,
    /// then back, and following each change made it shuttle between the two.
    var settleSeconds: Double = 40
    /// Shortest a hop's glide may be, so short hops don't flick past.
    var minTravelSeconds: Double = 4
    /// Longest a hop's glide may be: a hop drawn long on the map (96 St to 110 St on the 2 and 3, around Central
    /// Park) glides faster instead of crawling for minutes; it still arrives on time.
    var maxTravelSeconds: Double = 40
    /// A train missing from the data keeps its dot this long (a little over one download) before it fades out: the MTA
    /// sometimes leaves a train out of one download, and removing it at once made the dot start again from the station
    /// the next download gave, behind where it already was (a G held at 4 Av-9 St, its dot already at 7 Av).
    var goneAfter: Double = 35

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
    /// For testing: called with each train standing somewhere new, the reason, and the phase it was in before.
    var standTrace: ((_ key: String, _ why: String, _ before: String) -> Void)?
    private var why = ""
    /// Corrections waiting for their train's delay: what the correction is, and when it may happen.
    private var pendingCorrections: [String: (what: String, due: Double)] = [:]
    /// Each trip's key (see TripKeys), and the latest keys by trip ID (for the test tools).
    private let tripKeys = TripKeys()
    private(set) var keyOfTrip: [String: String] = [:]
    /// The way the train being planned is going ("N" or "S").
    private var direction: Character?
    /// Trains missing from the data, and since when (see `goneAfter`).
    private var missingSince: [String: Double] = [:]
    /// Where the data has been asking a standing train to move, and since when (see `settleSeconds`).
    private var standingMoves: [String: (point: CGPoint, since: Double)] = [:]
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
        // Keyed by the MTA's trip code, so a live train continues as the same dot as its scheduled twin when live data
        // returns (Trip.identity); by the whole ID for a second trip with the same code (TripKeys).
        let keys = tripKeys.keys(for: trips, now: now)
        if tripKeys.changed { keyOfTrip = Dictionary(zip(trips.map(\.tripID), keys), uniquingKeysWith: { a, _ in a }) }
        for (listed, key) in zip(trips, keys) {
            // Only the stops that are stations on the map, without passed ones at the front (Locator.onMap).
            let trip = locator.onMap(listed, now: now)
            // The way it's going ("N" or "S", from its platforms), for catching up on a pattern going the same way.
            direction = trip.upcoming.first?.stop.last
            let base = locator.locate(trip, now: now)  // the notebook's rules decide whether it's shown
            guard let basePoint = base.point else { continue }
            seen.insert(key)

            // Where the dot is on the line: the station it stands at, or the one its glide left from (which comes before
            // the train's next stop even while the glide is still on its way there). It settles which hop the train is on.
            var dotStation: String?
            switch phases[key] {
            case .stopped(let station, _, _, _, _)?: dotStation = station
            case .traveling(let leg, _, _, _)?: dotStation = leg.from
            case nil: dotStation = nil
            }
            // Parked trains have no timeline, unless the dot is already running this trip (Locator.legs decides).
            let timeline = base.kind == .parked && dotStation == nil ? nil : locator.legs(for: trip, now: now, after: dotStation, base: base)
            if timeline == nil, trip.status == "STOPPED_AT", let glide = finishRun(key, trip: trip, now: now) {
                commands += glide  // standing at the end of its run (or with nothing ahead), its dot a few stops short
                continue
            }
            guard let legs = timeline else {
                // Parked, or no timeline: stand where the notebook places it (a move waits for its turn), once any glide
                // is over (never interrupt a hop).
                if case .traveling(_, let start, let duration, _)? = phases[key], now < start + duration { continue }
                // Standing at a station still listed ahead of the train (its last stop, reached while the vehicle report
                // lags behind: a C at Euclid Av, reported back at Broadway Junction): it stays.
                if case .stopped(let station?, _, _, _, _)? = phases[key],
                   trip.upcoming.contains(where: { locator.stationOf($0.stop) == station }) { continue }
                let look: TrainLook = base.kind == .parked ? .parked : .stopped
                why = base.kind == .parked ? "parked: \(base.how)" : "no timeline: \(base.how)"
                // Asked to stand where it already stands: it keeps its station, so it can still glide on from there
                // (to the end of its run) rather than jump.
                var keep: String?
                if case .stopped(let station?, let point, _, _, _)? = phases[key], hypot(point.x - basePoint.x, point.y - basePoint.y) <= 3 {
                    keep = station
                }
                // A train waiting to start its run is parked at its first station: tied to it, so that when the feed
                // shows it already a station or two on (first seen after it set off), its dot glides there, hop by
                // hop, rather than fading across.
                if keep == nil, base.kind == .parked,
                   let stop = trip.vehicleStop.flatMap({ $0.isEmpty ? nil : $0 }) ?? trip.upcoming.first?.stop,
                   let station = locator.stationOf(stop) {
                    let p = locator.stationPoint(route: trip.routeID, station: station)
                    if hypot(p.x - basePoint.x, p.y - basePoint.y) <= 3 { keep = station }
                }
                commands += stop(key, station: keep, point: basePoint, look: look, now: now, route: trip.routeID,
                                 heading: base.kind == .parked ? startHeading(trip) : nil)
                continue
            }
            // The hop the predictions say the train is on (or about to start); nil = past its last prediction.
            guard let current = legs.first(where: { now <= $0.arrive }) else {
                // Running later than its last prediction: it stands at the last station, once its glide is over (never
                // interrupt a hop: standing it there at once snapped the dot the rest of the way, at the end of a run).
                if case .traveling(_, let start, let duration, _)? = phases[key], now < start + duration { continue }
                let last = legs[legs.count - 1]
                // Standing at the last hop's start, or a few stops before it: it glides on to the last station rather
                // than jump there (a late 4 at Mosholu Pkwy, with Woodlawn its last stop).
                if case .stopped(let station?, _, _, _, _)? = phases[key], station != last.to,
                   let hop = station == last.from ? last
                       : locator.catchUpLeg(route: last.route, from: station, toward: last.to, maxHops: 4, direction: direction),
                   correctionDue(key, "late, on to \(last.to)", now: now) {
                    stats.catchUps += 1
                    let duration = max(Double(hop.line.length) / catchUpSpeed, minTravelSeconds / 2)
                    commands += travel(key, leg: hop, path: hop.line.points, duration: duration, now: now, kind: .catchUp)
                    continue
                }
                why = "past its last prediction"
                commands += stop(key, station: last.to, point: locator.standPoint(route: last.route, station: last.to, from: last.from),
                                 look: .stopped, now: now, route: last.route)
                continue
            }
            standingMoves[key] = nil  // following a timeline: an earlier request to stand it elsewhere no longer holds
            commands += advance(key, legs: legs, current: current, now: now)
        }
        // Trains no longer in the data (run finished, or reassigned) fade out, each in its turn, once they've been
        // missing for `goneAfter` seconds (a train back in the next download carries on where its dot is).
        for key in seen { missingSince[key] = nil }
        for key in phases.keys where !seen.contains(key) { missingSince[key] = missingSince[key] ?? now }
        for key in phases.keys where !seen.contains(key) && now - missingSince[key]! >= goneAfter
            && correctionDue(key, "gone", now: now) {
            missingSince[key] = nil
            standTrace?(key, "gone: not in the data, or not placed", "\(phases[key].map { "\($0)" } ?? "-")".prefix(80).description)
            phases[key] = nil
            pendingCorrections[key] = nil
            standingMoves[key] = nil
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
                why = "first sight, before its hop"
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
                why = "waiting at its hop's start"
                return stop(key, station: station, point: stationPoint(current, at: current.from), look: .stopped, now: now,
                            route: current.route, heading: departure(current))
            }
            // Ahead: at the hop's end, or a station the train reaches later (one its hops leave from or end at, or one a
            // pattern going its way reaches after the hop's start: a 6 running express past 23 St and 28 St).
            if let station, station == current.to
                || legs.contains(where: { ($0.from == station || $0.to == station) && $0.arrive > current.arrive })
                || locator.catchUpLeg(route: current.route, from: current.from, toward: station, maxHops: 8, direction: direction) != nil {
                stats.waitsAhead += 1
                pendingCorrections[key] = nil
                return []  // we're ahead of the predictions: keep waiting here until they catch up
            }
            // Standing part-way along the track of the train's hop: a station it now runs through (the E through Spring
            // St, when the feed switched it to Canal St to W 4 St with its dot already at Spring St). It carries on from
            // there when the hop is due to leave, rather than fading back to the hop's start.
            let on = current.line.nearest(to: point)
            if let station, on.distance < 4, on.along > 2, on.along < current.line.length - 2 {
                pendingCorrections[key] = nil
                guard now >= departAt else { return [] }  // waits here, ahead
                let rest = current.line.piece(from: on.along, to: current.line.length)
                let leg = Locator.Leg(route: current.route, from: station, to: current.to, depart: now, arrive: current.arrive, line: rest)
                let duration = min(max(current.arrive - now, Double(rest.length) / catchUpSpeed, minTravelSeconds / 2), maxTravelSeconds)
                return travel(key, leg: leg, path: rest.points, duration: duration, now: now)
            }
            // Fresh data says the train is further along or somewhere else: correct it, but only when this train's
            // turn comes (meanwhile it waits where it is).
            guard correctionDue(key, "from \(station ?? "parked") toward \(current.from)", now: now) else { return [] }
            // Further along: leave now and catch up, one hop at a time.
            if let station, let behind = legs.first(where: { $0.from == station && $0.arrive < current.arrive })
                ?? locator.catchUpLeg(route: current.route, from: station, toward: current.from, maxHops: 4, then: current.to)
                // Running express where its patterns stop (6 trains express through Manhattan): any pattern going its way.
                ?? locator.catchUpLeg(route: current.route, from: station, toward: current.from, maxHops: 4, direction: direction)
                // Rerouted onto another line (5 trains on the 2/3 through 34 St-Penn Station): along that line's track.
                ?? reroutedCatchUp(from: station, toward: current) {
                stats.catchUps += 1
                let duration = max(Double(behind.line.length) / catchUpSpeed, minTravelSeconds / 2)
                return travel(key, leg: behind, path: behind.line.points, duration: duration, now: now, kind: .catchUp)
            }
            // Somewhere unconnected (e.g. a reroute or a brand-new prediction): fade to the right place.
            stats.teleports += 1
            let reason = station == nil ? "parked placeholder matched to a train elsewhere"
                : (legs.contains { $0.to == station } ? "station is a hop's destination"
                   : (locator.catchUpLeg(route: current.route, from: station!, toward: current.from, maxHops: 40, then: current.to) != nil
                      ? "behind by more than 4 stops" : "not on this route's patterns"))
            stats.teleportReasons[reason, default: 0] += 1
            standTrace?(key, "faded across: \(reason), toward \(current.from)>\(current.to)", "standing at \(station ?? "no station")")
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

    /// For a rerouted train (its hop isn't on its route's patterns): the hop from `station` to the start of `current`
    /// along the track between them (Locator.hopLine falls back to the line its route borrows), when there is one, it's
    /// short (a station or two), and it leads on the way the train is going (so never back the way it came).
    private func reroutedCatchUp(from station: String, toward current: Locator.Leg) -> Locator.Leg? {
        let (line, followed) = locator.hopLine(route: current.route, from: station, to: current.from)
        guard followed, line.length > 0, line.length < 150, let a = line.points.first, let b = line.points.last,
              let c = current.line.points.last else { return nil }
        // Same way on: from the station to the hop's start, then on to its end.
        guard (b.x - a.x) * (c.x - b.x) + (b.y - a.y) * (c.y - b.y) > 0 else { return nil }
        return Locator.Leg(route: current.route, from: station, to: current.from, depart: current.depart, arrive: current.depart, line: line)
    }

    private func stationPoint(_ leg: Locator.Leg, at station: String) -> CGPoint {
        // A rerouted train stands on the circle of a line making the same hop (Locator.standPoint).
        locator.standPoint(route: leg.route, station: station, from: station == leg.to && leg.from != leg.to ? leg.from : nil,
                           to: station == leg.from && leg.from != leg.to ? leg.to : nil)
    }

    /// A train that has finished its run while its dot stands a few stops short of the end (the last hops were
    /// missed between downloads): it glides on along the track, one hop at a time, instead of jumping to the end.
    /// Nil when the dot is already there, isn't standing at a station, or the end isn't within 4 stops ahead.
    private func finishRun(_ key: String, trip: Trip, now: Double) -> [TrainCommand]? {
        var commands: [TrainCommand] = []
        if case .traveling(let leg, let start, let duration, _)? = phases[key] {
            if now < start + duration { return [] }  // never interrupt a hop
            // Arrived: standing at the station, and drawn so (its bullet, not a moving dot), as on any arrival.
            let point = stationPoint(leg, at: leg.to)
            phases[key] = .stopped(station: leg.to, point: point, look: .stopped, route: leg.route, heading: nil)
            commands.append(.place(key: key, point: point, look: .stopped, route: leg.route))
        }
        guard case .stopped(let station?, _, _, _, _)? = phases[key], let stop = trip.vehicleStop,
              let end = locator.stationOf(stop), end != station,
              let hop = locator.catchUpLeg(route: trip.routeID, from: station, toward: end, maxHops: 4, direction: stop.last),
              correctionDue(key, "finish run at \(end)", now: now) else { return commands.isEmpty ? nil : commands }
        stats.catchUps += 1
        let duration = max(Double(hop.line.length) / catchUpSpeed, minTravelSeconds / 2)
        return commands + travel(key, leg: hop, path: hop.line.points, duration: duration, now: now, kind: .catchUp)
    }

    /// The way a train parked at the start of its run will leave: from its first stop toward its second. Nil for a
    /// train that has finished its run (no stops ahead) or whose stops aren't on the map.
    private func startHeading(_ trip: Trip) -> CGVector? {
        let stations = trip.upcoming.prefix(2).compactMap { locator.stationOf($0.stop) }
        guard stations.count == 2, stations[0] != stations[1] else { return nil }
        return locator.departureHeading(route: trip.routeID, from: stations[0], to: stations[1])
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
            if moved <= 3 { standingMoves[key] = nil }  // asked to stay (again): forget any earlier request to move
            if l == look, moved < 0.01, h == heading { return [] }
            if moved > 3 {
                // Moving a standing train: only once the data has asked for the same place for `settleSeconds`, then
                // in this train's turn (correctionDue).
                if let asked = standingMoves[key], hypot(asked.point.x - point.x, asked.point.y - point.y) <= 3 {
                    if now - asked.since < settleSeconds { return [] }
                } else {
                    standingMoves[key] = (point, now)
                    return []
                }
                if !correctionDue(key, "move to \(Int(point.x)),\(Int(point.y))", now: now) { return [] }
                standingMoves[key] = nil
            }
        case .traveling(_, _, _, let path)?:
            // Mid-glide, and the data now has it standing somewhere: unless that's where it's heading, it's a
            // correction too (meanwhile it keeps gliding).
            if let end = path.last, hypot(end.x - point.x, end.y - point.y) > 3,
               !correctionDue(key, "move to \(Int(point.x)),\(Int(point.y))", now: now) { return [] }
        case nil:
            break
        }
        if let standTrace {
            switch phases[key] {
            case .stopped(let s, let p, _, _, _)? where hypot(p.x - point.x, p.y - point.y) > 3:
                standTrace(key, why, "standing at \(s ?? "no station")")
            case .traveling(let leg, let start, let duration, _)? :
                standTrace(key, why, String(format: "gliding %@→%@, %.0f of %.0f s", leg.from, leg.to, now - start, duration))
            default: break
            }
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
        // From where the dot stands: a rerouted train's stand point can be worked out from two different circles (the
        // one for the hop it arrived on, the one for the hop it leaves on), a few map units apart.
        if case .stopped(_, let point, _, _, _)? = phases[key], let first = path.first {
            let gap = hypot(first.x - point.x, first.y - point.y)
            if gap > 0.5, gap < 15 { path.insert(point, at: 0) }
        }
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
        defer { phases = [:]; standingMoves = [:]; missingSince = [:] }
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

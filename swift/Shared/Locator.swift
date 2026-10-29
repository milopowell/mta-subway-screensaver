import CoreGraphics
import Foundation

/// One trip from the live feed (the Swift twin of a row of the notebook's `trains` table, §5).
struct Trip {
    let feed: String
    let tripID: String
    let routeID: String
    /// "STOPPED_AT", "INCOMING_AT", "IN_TRANSIT_TO", or nil when no train is assigned yet.
    let status: String?
    /// The platform the status refers to; nil when there's no vehicle, "" if the vehicle didn't say.
    let vehicleStop: String?
    /// The stops still ahead, in order.
    let upcoming: [StopTime]
}

/// One upcoming stop of a trip, as predicted by the live feed.
struct StopTime {
    let stop: String  // platform ID
    /// Predicted arrival, or departure at a trip's first stop (which has no arrival): the notebook's time.
    let time: Double
    /// Predicted departure, when the feed gives one.
    let departure: Double?
}

/// Where (and whether) to draw one trip. `how` uses exactly the notebook's category labels.
struct Placement {
    enum Kind { case moving, atStation, parked, hidden }

    let point: CGPoint?  // map units; nil when not drawn
    let how: String

    var kind: Kind {
        if point == nil { return .hidden }
        if how.hasPrefix("between") { return .moving }
        if how.hasPrefix("parked") { return .parked }
        return .atStation  // "at station", "at next stop (no hop)"
    }
}

/// Places trips on the map. A port of the notebook's `locate_from_export` (§8), which itself mirrors
/// `locate()` (§6) step by step. If you change the rules in the notebook, change them here too.
final class Locator {
    private let net: SubwayNetwork
    /// route → its patterns, each with a "platform → first position in the pattern" index.
    private var patternsByRoute: [String: [(stops: [String], trips: Int, index: [String: Int])]] = [:]
    /// platform → preceding platforms on any route, with trip counts, in first-seen order
    /// (first-seen order reproduces Python's Counter.most_common tie-break).
    private var prevAny: [String: [(stop: String, trips: Int)]] = [:]
    /// line color → its polylines.
    private let lines: [String: [Polyline]]
    /// (route, from station, to station) → the hop's line and whether it follows the drawn route line.
    private var hopCache: [String: (line: Polyline, followed: Bool)] = [:]

    init(network: SubwayNetwork) {
        net = network
        lines = network.routeLines.mapValues { $0.map { Polyline($0.map(CGPoint.init)) } }
        for p in network.patterns {
            var index: [String: Int] = [:]
            for (k, s) in p.stops.enumerated() where index[s] == nil { index[s] = k }
            patternsByRoute[p.route, default: []].append((p.stops, p.trips, index))
            for (a, b) in zip(p.stops, p.stops.dropFirst()) {
                var list = prevAny[b, default: []]
                if let k = list.firstIndex(where: { $0.stop == a }) {
                    list[k].trips += p.trips
                } else {
                    list.append((a, p.trips))
                }
                prevAny[b] = list
            }
        }
    }

    /// Same as the notebook's previous_stop(): the platform a train left before heading to `stop`,
    /// or nil if `stop` begins its best-matching pattern (it hasn't started its run).
    func previousStop(route: String, stop: String, upcoming: [String]) -> String? {
        var best: String?
        var bestKey: (matches: Int, trips: Int)?
        let next8 = upcoming.prefix(8)
        for p in patternsByRoute[route] ?? [] {
            guard let i = p.index[stop] else { continue }
            let ahead = Set(p.stops[i...])
            let key = (next8.filter { ahead.contains($0) }.count, p.trips)
            if bestKey == nil || key > bestKey! {  // strictly better: the earlier pattern wins ties
                bestKey = key
                best = i > 0 ? p.stops[i - 1] : nil
            }
        }
        if bestKey == nil {
            // This route never stops here in the schedule (a reroute): most common predecessor, any route.
            var top: (stop: String, trips: Int)?
            for candidate in prevAny[stop] ?? [] where top == nil || candidate.trips > top!.trips {
                top = candidate
            }
            return top?.stop
        }
        return best
    }

    /// Same as omap.station_point(): the route's circle at the station, else the station's center.
    func stationPoint(route: String, station: String) -> CGPoint {
        let s = net.stations[station]!
        return CGPoint(s.points[route] ?? s.center)
    }

    /// The track a train follows from station a to b, read like locate_from_export: the path the notebook exported
    /// for this route (`hop_paths`, routed along the joined pieces of its colored line); for a hop that isn't
    /// exported, the stretch of a single piece of the route's line between the two stations; failing that (a train
    /// rerouted onto another line's tracks), the track between the two stations (`pair_paths`); else a straight line.
    func hopLine(route: String, from a: String, to b: String) -> (line: Polyline, followed: Bool) {
        let key = "\(route)|\(a)|\(b)"
        if let cached = hopCache[key] { return cached }
        if let path = net.hopPaths?[key], path.count > 1 {
            let result = (Polyline(path.map(CGPoint.init)), true)
            hopCache[key] = result
            return result
        }
        let pa = stationPoint(route: route, station: a), pb = stationPoint(route: route, station: b)
        let straight = (Polyline([pa, pb]), false)
        let maxSnap: CGFloat = 6
        var best: (sum: CGFloat, line: Polyline)?
        for line in lines[net.routes[route]?.color ?? ""] ?? [] {
            let da = line.nearest(to: pa).distance, db = line.nearest(to: pb).distance
            if da <= maxSnap, db <= maxSnap, best == nil || da + db < best!.sum {
                best = (da + db, line)
            }
        }
        var result = straight
        if let pair = net.pairPaths?["\(a)|\(b)"], pair.count > 1 {
            result = (Polyline(pair.map(CGPoint.init)), true)
        }
        if let line = best?.line {
            let ta = line.nearest(to: pa).along, tb = line.nearest(to: pb).along
            var piece = line.piece(from: min(ta, tb), to: max(ta, tb))
            if ta > tb { piece = piece.reversed() }
            let direct = hypot(pb.x - pa.x, pb.y - pa.y)
            // Use it unless it's degenerate, or wanders far further than the direct distance (e.g. a loop).
            if piece.length >= 1e-6, piece.length <= 3 * direct + 20 {
                result = (piece, true)
            }
        }
        hopCache[key] = result
        return result
    }

    /// Same as the notebook's locate_from_export(): steps 1–6 of §6, in the same order.
    func locate(_ trip: Trip, now: Double) -> Placement {
        let cfg = net.settings
        func station(of stop: String?) -> String? {
            guard let stop, let s = net.platforms[stop], net.stations[s] != nil else { return nil }
            return s
        }
        // 1. No stops left: the run is over.
        guard let first = trip.upcoming.first else {
            if trip.status == "STOPPED_AT", let s = station(of: trip.vehicleStop) {
                return Placement(point: stationPoint(route: trip.routeID, station: s), how: "parked (finished run)")
            }
            return Placement(point: nil, how: "no predictions")
        }
        // 2. Leftover trips whose "next" stop time is long past.
        if first.time < now - cfg.staleAfterS {
            return Placement(point: nil, how: "stale")
        }
        // 3. A platform we can't place. (An empty vehicle stop counts as missing, like Python's `or`.)
        let route = trip.routeID
        let stop = (trip.vehicleStop?.isEmpty == false) ? trip.vehicleStop! : first.stop
        guard let here = station(of: stop) else {
            return Placement(point: nil, how: "unknown stop")
        }
        // 4. Standing at a platform.
        if trip.status == "STOPPED_AT" {
            return Placement(point: stationPoint(route: route, station: here), how: "at station")
        }
        // 5. Not started yet: no train assigned, or heading to the first stop of its run.
        let prev = previousStop(route: route, stop: stop, upcoming: trip.upcoming.map(\.stop))
        if trip.status == nil || prev == nil {
            if first.time - now <= cfg.parkWindowS {
                return Placement(point: stationPoint(route: route, station: here), how: "parked (leaving soon)")
            }
            return Placement(point: nil, how: "waiting (hidden)")
        }
        // 6. Moving: along the route's line between the two stations.
        guard let from = station(of: prev) else {
            return Placement(point: stationPoint(route: route, station: here), how: "at next stop (no hop)")
        }
        let (line, followed) = hopLine(route: route, from: from, to: here)
        let hopTime = net.hopTimes["\(prev!)>\(stop)"] ?? cfg.defaultHopS
        // The arrival time at `stop` (the last entry wins if a stop repeats, like Python's dict()).
        let eta = trip.upcoming.last(where: { $0.stop == stop })?.time ?? first.time
        let fraction = min(max(1 - (eta - now) / hopTime, 0), 1)
        return Placement(point: line.interpolate(fraction: CGFloat(fraction)),
                         how: followed ? "between stops" : "between stops (straight)")
    }

    // ---- Timeline for smooth motion (Swift only, for now) ----

    /// One hop of a train's predicted journey: it leaves station `from` at `depart`, arrives at `to` at `arrive`.
    struct Leg {
        let route: String
        let from: String, to: String  // station IDs
        let depart: Double, arrive: Double  // unix times
        let line: Polyline  // the track the train follows (map units)
    }

    /// The train's predicted journey from its current hop onward, built from the feed's times for every
    /// stop ahead, or nil when the train isn't moving or standing at a station (parked, hidden…).
    ///
    /// `locate()` (the notebook's rule) only looks at the next stop. This keeps going:
    ///   1. the current hop: arrives at the next stop at the predicted time, having left one scheduled
    ///      hop-time earlier (the same assumption `locate()` makes);
    ///   2. every following hop: leaves at the predicted departure, arrives at the predicted arrival.
    /// MotionPlanner turns this into smooth animations.
    func legs(for trip: Trip, now: Double) -> [Leg]? {
        let base = locate(trip, now: now)
        guard base.how == "at station" || base.how.hasPrefix("between"),
              let first = trip.upcoming.first else { return nil }
        let route = trip.routeID
        let stop0 = (trip.vehicleStop?.isEmpty == false) ? trip.vehicleStop! : first.stop
        guard let i0 = trip.upcoming.firstIndex(where: { $0.stop == stop0 }) else { return nil }
        let ahead = Array(trip.upcoming[i0...])

        var raw: [(from: String, to: String, depart: Double, arrive: Double)] = []
        if trip.status != "STOPPED_AT",
           let prev = previousStop(route: route, stop: stop0, upcoming: trip.upcoming.map(\.stop)) {
            let hopTime = net.hopTimes["\(prev)>\(stop0)"] ?? net.settings.defaultHopS
            raw.append((prev, stop0, ahead[0].time - hopTime, ahead[0].time))
        }
        for (a, b) in zip(ahead, ahead.dropFirst()) {
            raw.append((a.stop, b.stop, max(a.departure ?? a.time, a.time), b.time))
        }
        let legs = raw.compactMap { r -> Leg? in
            guard let a = stationOf(r.from), let b = stationOf(r.to), a != b else { return nil }
            return Leg(route: route, from: a, to: b, depart: r.depart, arrive: r.arrive,
                       line: hopLine(route: route, from: a, to: b).line)
        }
        return legs.isEmpty ? nil : legs
    }

    /// The first hop from station `a` toward station `b` along one of the route's stop patterns, for a train
    /// that has fallen behind and must catch up (the feed drops stations a train has passed, so they're not in
    /// its timeline any more). Nil if no pattern of the route runs from `a` to `b` within `maxHops` stops.
    func catchUpLeg(route: String, from a: String, toward b: String, maxHops: Int) -> Leg? {
        for p in patternsByRoute[route] ?? [] {
            var stations: [String] = []
            for platform in p.stops {
                if let s = stationOf(platform), stations.last != s { stations.append(s) }
            }
            guard let i = stations.firstIndex(of: a), let j = stations[(i + 1)...].firstIndex(of: b),
                  j - i <= maxHops else { continue }
            let next = stations[i + 1]
            return Leg(route: route, from: a, to: next, depart: 0, arrive: 0,
                       line: hopLine(route: route, from: a, to: next).line)
        }
        return nil
    }

    /// How far, on average, a path runs from the route's own colored line, in map units: about 0 when the train rides
    /// its own line; larger when it follows another line's track (a reroute) or a straight line. For checking.
    func distanceFromOwnLine(route: String, path: [CGPoint]) -> Double {
        let own = lines[net.routes[route]?.color ?? ""] ?? []
        guard !own.isEmpty, !path.isEmpty else { return .infinity }
        let total = path.reduce(0.0) { sum, p in sum + Double(own.map { $0.nearest(to: p).distance }.min()!) }
        return total / Double(path.count)
    }

    /// True if stations a and b are neighboring stops in one of the route's stop patterns (a hop it normally makes).
    func isPatternHop(route: String, from a: String, to b: String) -> Bool {
        for p in patternsByRoute[route] ?? [] {
            var previous: String?
            for platform in p.stops {
                guard let s = stationOf(platform), s != previous else { continue }
                if previous == a, s == b { return true }
                previous = s
            }
        }
        return false
    }

    /// The station of a platform (nil if it isn't on the map).
    func stationOf(_ platform: String) -> String? {
        guard let s = net.platforms[platform], net.stations[s] != nil else { return nil }
        return s
    }
}

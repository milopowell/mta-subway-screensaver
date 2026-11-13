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
    /// route → its patterns, each with "platform → first position" and "platform → last position" indexes.
    private var patternsByRoute: [String: [(stops: [String], trips: Int, index: [String: Int], last: [String: Int])]] = [:]
    /// platform → preceding platforms on any route, with trip counts, in first-seen order
    /// (first-seen order reproduces Python's Counter.most_common tie-break).
    private var prevAny: [String: [(stop: String, trips: Int)]] = [:]
    /// line color → its polylines.
    private let lines: [String: [Polyline]]
    /// (route, from station, to station) → the hop's line and whether it follows the drawn route line.
    private var hopCache: [String: (line: Polyline, followed: Bool)] = [:]

    init(network: SubwayNetwork) {
        net = network
        onMapPlatforms = Set(network.platforms.filter { network.stations[$0.value] != nil }.keys)
        lines = network.routeLines.mapValues { $0.map { Polyline($0.map(CGPoint.init)) } }
        complexMembers = Dictionary(grouping: network.stations.keys.sorted()) { network.stations[$0]!.complex }
        strokes = (network.routeStrokes ?? []).map { stroke in
            let points = stroke.points.map(CGPoint.init)
            let xs = points.map(\.x), ys = points.map(\.y)
            let box = CGRect(x: xs.min() ?? 0, y: ys.min() ?? 0, width: (xs.max() ?? 0) - (xs.min() ?? 0),
                             height: (ys.max() ?? 0) - (ys.min() ?? 0))
            return (stroke.order, CGFloat(stroke.halfWidth), points, box, stroke.color)
        }
        for p in network.patterns {
            var index: [String: Int] = [:], last: [String: Int] = [:]
            for (k, s) in p.stops.enumerated() {
                if index[s] == nil { index[s] = k }
                last[s] = k
            }
            patternsByRoute[p.route, default: []].append((p.stops, p.trips, index, last))
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
            // How many of the next 8 stops the pattern still visits from `stop` on (a stop is in p.stops[i...]
            // exactly when its last position is at or after i). Runs for every trip every second, so no sets.
            var matches = 0
            for s in next8 where (p.last[s] ?? -1) >= i { matches += 1 }
            let key = (matches, p.trips)
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

    /// The platform a train left before heading to `stop`, for motion, when the dot is known to be at (or heading to)
    /// station `after`: among the route's patterns in which that station comes before `stop` (within 8 stops), the one
    /// where it comes closest before it (then matching the most of the stops ahead, then the most trips). Falls back to
    /// `previousStop(route:stop:upcoming:)` (the notebook's rule) when no pattern has the station there.
    ///
    /// The notebook's rule sees only the stops ahead, so a train making local stops on a line its route usually runs
    /// express (the 4 late at night, at 116 St heading for 125 St) gets the express pattern's previous stop (86 St):
    /// the dot, standing at 116 St, was then sent back down the line to 86 St to "catch up". Closest first: a J express
    /// standing at Marcy Av and heading for Myrtle Av runs straight there (the express pattern, one stop), not through
    /// the local stations of the busier local pattern.
    func previousStop(route: String, stop: String, upcoming: [String], after hint: String?) -> String? {
        guard let hint else { return previousStop(route: route, stop: stop, upcoming: upcoming) }
        return previousStop(route: route, stop: stop, upcoming: upcoming, onlyAfter: hint)
            ?? previousStop(route: route, stop: stop, upcoming: upcoming)
    }

    /// The hinted search of `previousStop(…after:)` alone: nil when no pattern of the route has station `hint` within
    /// 8 stops before `stop`.
    private func previousStop(route: String, stop: String, upcoming: [String], onlyAfter hint: String) -> String? {
        var best: String?
        var bestKey: (closeness: Int, matches: Int, trips: Int)?
        let next8 = upcoming.prefix(8)
        for p in patternsByRoute[route] ?? [] {
            // The pattern stops at `stop`, with the dot's station a few stops before it.
            guard let i = p.index[stop], i > 0,
                  let h = p.stops[max(i - 8, 0)..<i].lastIndex(where: { stationOf($0) == hint }) else { continue }
            // Ranked: how close before `stop` the dot's station is (1 = right before it), then like the notebook's
            // rule: stops ahead it still visits, then trips a day.
            var matches = 0
            for s in next8 where (p.last[s] ?? -1) >= i { matches += 1 }
            let key = (-(i - h), matches, p.trips)
            if bestKey == nil || key > bestKey! {
                bestKey = key
                best = p.stops[i - 1]
            }
        }
        return best
    }

    /// Same as omap.station_point(): the route's circle at the station, else the station's center.
    func stationPoint(route: String, station: String) -> CGPoint {
        let s = net.stations[station]!
        return CGPoint(s.points[route] ?? s.center)
    }

    /// Where a train stands at a station, for motion: the route's circle, as `stationPoint`. A route with no circle
    /// there (a reroute, such as the E on the F's track through Lexington Av/63 St) takes the circle of a route that
    /// makes the same hop, arriving `from` or leaving `to` that neighbor, instead of the middle of the station (between
    /// two lines). Only for drawing: `locate()` keeps the notebook's rule, so the two still match exactly.
    func standPoint(route: String, station: String, from: String? = nil, to: String? = nil) -> CGPoint {
        let s = net.stations[station]!
        if let p = s.points[route] { return CGPoint(p) }
        let key = "\(route)|\(station)|\(from ?? "")|\(to ?? "")"
        if let cached = standCache[key] { return cached }
        // Routes that stop here first (they have a circle of their own), then the rest of the routes drawn here.
        let others = s.routes.filter { s.points[$0] != nil } + s.points.keys.sorted().filter { !s.routes.contains($0) }
        let match = others.first { other in
            (from.map { isPatternHop(route: other, from: $0, to: station) } ?? false)
                || (to.map { isPatternHop(route: other, from: station, to: $0) } ?? false)
        }
        let point = CGPoint(match.flatMap { s.points[$0] } ?? s.center)
        standCache[key] = point
        return point
    }
    private var standCache: [String: CGPoint] = [:]
    /// Complex ID → its stations (W 4 St-Wash Sq: the 8 Av and 6 Av levels).
    private let complexMembers: [String: [String]]

    /// The way a train standing at `station` leaves for `next`: a unit vector (map units) along the track from the
    /// point nearest where it stands to a little way on, so it follows the line as it leaves the station rather than
    /// the straight line to the next stop (and the track running a little to one side of the circle doesn't tilt it).
    /// Nil if the hop has no length.
    func departureHeading(route: String, from station: String, to next: String) -> CGVector? {
        let key = "\(route)|\(station)|\(next)"
        if let cached = headingCache[key] { return cached }
        let line = hopLine(route: route, from: station, to: next).line
        let along = min(line.nearest(to: standPoint(route: route, station: station, to: next)).along, line.length * 0.5)
        let here = line.point(at: along), ahead = line.point(at: min(along + 12, line.length * 0.6))
        let dx = ahead.x - here.x, dy = ahead.y - here.y, length = hypot(dx, dy)
        let heading = length < 0.5 ? nil : CGVector(dx: dx / length, dy: dy / length)
        headingCache[key] = heading
        return heading
    }
    private var headingCache: [String: CGVector?] = [:]

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
        if let pair = net.pairPaths?["\(a)|\(b)"] ?? siblingPair(a, b, from: pa, to: pb), pair.count > 1 {
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
        if !result.1, let chain = chainedPath(route: route, from: a, to: b) {
            result = (Polyline(chain), true)
        }
        hopCache[key] = result
        return result
    }

    /// For a train skipping stops on a line it doesn't normally run on (a weekend E running express on the F's track
    /// from Parsons Blvd to Kew Gardens; an R or W on the D's West End line from 9 Av to 62 St): the track of a line
    /// that stops at every station in between, joined hop by hop. Its own route's patterns are tried first, then the
    /// others'. Only up to 6 stops apart, and only if every piece is drawn. Nil if none.
    private func chainedPath(route: String, from a: String, to b: String) -> [CGPoint]? {
        for r in [route] + patternsByRoute.keys.sorted().filter({ $0 != route }) {
            for p in patternsByRoute[r] ?? [] {
                var stations: [String] = []
                for platform in p.stops {
                    if let s = stationOf(platform), stations.last != s { stations.append(s) }
                }
                guard let i = stations.firstIndex(of: a), let j = stations[(i + 1)...].firstIndex(of: b),
                      j - i >= 2, j - i <= 6 else { continue }
                var points: [CGPoint] = []
                for k in i..<j {
                    let x = stations[k], y = stations[k + 1]
                    guard let piece = net.hopPaths?["\(r)|\(x)|\(y)"] ?? net.pairPaths?["\(x)|\(y)"], piece.count > 1 else {
                        points = []
                        break
                    }
                    points += piece.dropFirst(points.isEmpty ? 0 : 1).map(CGPoint.init)
                }
                if !points.isEmpty { return points }
            }
        }
        return nil
    }

    /// The track between two other stations of the same two complexes, for a rerouted train whose stops name a level
    /// no track joins directly (a weekend A on the F's track, stopping at Broadway-Lafayette St and then at the 8 Av
    /// level of W 4 St, while the F's track reaches the 6 Av level). Its ends are within each complex, so the glide
    /// follows the track and steps across inside the station. Nil if there is none.
    /// Of several such tracks (two big complexes with several lines between them), the one whose ends are nearest
    /// where the train stands at the two stations (`from` and `to`): the line it's on, not just the first by station ID.
    private func siblingPair(_ a: String, _ b: String, from pa: CGPoint, to pb: CGPoint) -> [[Double]]? {
        let left = complexMembers[net.stations[a]?.complex ?? a] ?? [a]
        let right = complexMembers[net.stations[b]?.complex ?? b] ?? [b]
        var best: (gap: CGFloat, pair: [[Double]])?
        for x in left {
            for y in right where x != y {
                guard let pair = net.pairPaths?["\(x)|\(y)"], pair.count > 1 else { continue }
                let start = CGPoint(pair[0]), end = CGPoint(pair[pair.count - 1])
                let gap = hypot(start.x - pa.x, start.y - pa.y) + hypot(end.x - pb.x, end.y - pb.y)
                if best == nil || gap < best!.gap { best = (gap, pair) }
            }
        }
        return best?.pair
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
    /// MotionPlanner turns this into smooth animations. `after`: the station the train's dot is at or heading to, if
    /// known, which settles the hop it's on when the stops ahead fit more than one pattern (`previousStop(…after:)`).
    ///
    /// `base`: the trip's `locate` result, if already known (the planner has it). The timeline is kept per trip and
    /// reused while the trip's data, the dot's station and the placement are unchanged: between downloads (every 30 s)
    /// they are, and building every train's hops every second was most of the planner's time.
    func legs(for trip: Trip, now: Double, after hint: String? = nil, base known: Placement? = nil) -> [Leg]? {
        let base = known ?? locate(trip, now: now)
        // The same trip data, dot station and placement as last time: the same timeline.
        let signature = LegsSignature(feed: trip.feed, count: trip.upcoming.count, first: trip.upcoming.first?.stop,
                                      times: trip.upcoming.reduce(0) { $0 + $1.time + 0.5 * ($1.departure ?? 0) },
                                      vehicle: trip.vehicleStop, status: trip.status, hint: hint, how: base.how)
        if let cached = legsCache[trip.tripID], cached.signature == signature { return cached.legs }
        if legsCache.count > 4000 { legsCache.removeAll() }  // trips come and go: start again now and then
        let legs = buildLegs(for: trip, base: base, hint: hint)
        legsCache[trip.tripID] = (signature, legs)
        return legs
    }

    /// The work of `legs`.
    private func buildLegs(for trip: Trip, base: Placement, hint: String?) -> [Leg]? {
        // The stops ahead that are stations on the map. The feed sometimes lists a stop that isn't one (R60S between
        // Queensboro Plaza and Lexington Av/59 St, R65N between Court St and Whitehall St), and with it first the
        // train's hop couldn't be worked out: the dot, already ahead at the next station, was moved back to the last.
        let upcoming = trip.upcoming.allSatisfy({ onMapPlatforms.contains($0.stop) }) ? trip.upcoming
            : trip.upcoming.filter { onMapPlatforms.contains($0.stop) }
        guard let first = upcoming.first else { return nil }
        let route = trip.routeID
        let stop0 = (trip.vehicleStop?.isEmpty == false) ? trip.vehicleStop! : first.stop
        // Under way, as the notebook places it (standing at a station, or between two)…
        let underWay = base.how == "at station" || base.how.hasPrefix("between")
        // …or "leaving soon" from a station that also starts a shorter pattern (the 5 heading for Bowling Green, where
        // some 5s begin), when the dot is already running this trip and stands a few stops before it, or at that very
        // station (arrived a little ahead of the data): it's still under way. The notebook's rule sees only the stops
        // ahead and parked it there, so the dot jumped ahead, or lost its place on the line and faded.
        let continuing = base.how == "parked (leaving soon)" && trip.status != nil && hint.map {
            $0 == stationOf(stop0) || previousStop(route: route, stop: stop0, upcoming: upcoming.map(\.stop), onlyAfter: $0) != nil
        } == true
        guard underWay || continuing else { return nil }
        var raw: [(from: String, to: String, depart: Double, arrive: Double)] = []
        let ahead: [StopTime]
        if let i0 = upcoming.firstIndex(where: { $0.stop == stop0 }) {
            ahead = Array(upcoming[i0...])
            if trip.status != "STOPPED_AT",
               let prev = previousStop(route: route, stop: stop0, upcoming: upcoming.map(\.stop), after: hint) {
                let hopTime = net.hopTimes["\(prev)>\(stop0)"] ?? net.settings.defaultHopS
                raw.append((prev, stop0, ahead[0].time - hopTime, ahead[0].time))
            }
        } else if trip.status == "STOPPED_AT", let here = stationOf(stop0),
                  // The vehicle's station, as the hint: the E standing at Forest Hills-71 Av with Kew Gardens next runs
                  // express between them, though the busiest E pattern into Kew Gardens comes from 75 Av.
                  let before = previousStop(route: route, stop: first.stop, upcoming: upcoming.map(\.stop), after: here),
                  stationOf(before) == here {
            // The vehicle still reports standing at a station its trip has already dropped from the stops ahead (the
            // two parts of the feed disagree for a moment as the train leaves): it is leaving there for the first
            // stop listed. Without this hop the train had no timeline and was moved straight to that station. Only
            // when that station comes right before the first stop listed: a vehicle report stuck several stations
            // back would otherwise make one long glide across the map.
            ahead = upcoming
            let hopTime = net.hopTimes["\(stop0)>\(first.stop)"] ?? net.settings.defaultHopS
            raw.append((stop0, first.stop, first.time - hopTime, first.time))
        } else if trip.status == "STOPPED_AT", let hint, let k = upcoming.firstIndex(where: { stationOf($0.stop) == hint }) {
            // The vehicle reports standing further back, while the dot has already reached one of the stops listed (a
            // D's vehicle report stuck at Bedford Park Blvd for minutes as its stops moved on, the passed ones still
            // listed): the dot leaves from there, and the stops listed before it are behind it.
            ahead = Array(upcoming[k...])
        } else if trip.status == "STOPPED_AT", let hint,
                  let before = previousStop(route: route, stop: first.stop, upcoming: upcoming.map(\.stop), onlyAfter: hint),
                  stationOf(before) == hint {
            // The vehicle reports standing further back than the station the dot has reached, which comes right before
            // the first stop listed (an E at Spring St reported back at Canal St, with W 4 St next): the dot is ahead,
            // and leaves from where it is for that stop.
            ahead = upcoming
            let hopTime = net.hopTimes["\(before)>\(first.stop)"] ?? net.settings.defaultHopS
            raw.append((before, first.stop, first.time - hopTime, first.time))
        } else if trip.status == "STOPPED_AT", let here = stationOf(stop0), runsBefore(route: route, here, first.stop) {
            // Express: the vehicle stands at a station a few stops before the first stop listed, on a pattern of its
            // route (a C running express from Broadway Junction straight to Euclid Av): it leaves from there for it.
            ahead = upcoming
            let hopTime = net.hopTimes["\(stop0)>\(first.stop)"] ?? net.settings.defaultHopS
            raw.append((stop0, first.stop, first.time - hopTime, first.time))
        } else {
            return nil
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
    ///
    /// Only patterns going the train's way: running on from `b` to `then` (the hop the train is on), or with platforms
    /// of `direction` ("N" or "S", the end of the platform IDs). Without that, a pattern of the opposite direction that
    /// happens to pass `a` before `b` sent the dot backwards.
    func catchUpLeg(route: String, from a: String, toward b: String, maxHops: Int, then next: String? = nil,
                    direction: Character? = nil) -> Leg? {
        for p in patternsByRoute[route] ?? [] {
            // Direction: the pattern's platforms end in the train's N or S.
            if let direction, p.stops.first?.last != direction { continue }
            var stations: [String] = []
            for platform in p.stops {
                if let s = stationOf(platform), stations.last != s { stations.append(s) }
            }
            guard let i = stations.firstIndex(of: a), let j = stations[(i + 1)...].firstIndex(of: b),
                  j - i <= maxHops else { continue }
            // Direction: the pattern carries on from `b` to the hop the train is on.
            if let next, !(j + 1 < stations.count && stations[j + 1] == next) && b != next { continue }
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

    /// How far, on average, a path runs from the nearest drawn subway line of any color, in map units: about 0 when the
    /// train rides some line's track (its own, or the one it shares: the 4 to New Lots Av on the 3's line), larger when
    /// it cuts across the map. For checking (the line runs).
    func distanceFromAnyLine(path: [CGPoint]) -> Double {
        let all = lines.values.flatMap { $0 }
        guard !all.isEmpty, !path.isEmpty else { return .infinity }
        let total = path.reduce(0.0) { sum, p in sum + Double(all.map { $0.nearest(to: p).distance }.min()!) }
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

    /// Each route line as the map draws it (SubwayNetwork.Stroke), with its bounding box for quick rejection.
    private let strokes: [(order: Int, half: CGFloat, points: [CGPoint], box: CGRect, color: String)]

    /// One line a glide's path runs into: the band to hide the dot under, whether the path crosses the line (enters its
    /// band on one side and leaves on the other) or only runs alongside it, whether the train's own line is drawn there
    /// (the map leaves a gap in some lines where they pass under), the line's color and where.
    struct OverpassHit {
        let band: CGPath
        let crosses: Bool
        let ownLineDrawn: Bool
        /// The run touches the start or end of the path, where the train is still leaving or reaching its station's
        /// circle (which sits a little off the line): there "own line missing" says nothing.
        let atStation: Bool
        let color: String
        let at: CGPoint

        /// The train passes under this line: it crosses it, or its own line has a gap here (so it can't be on top). A
        /// line it only runs alongside, on its own line drawn the whole way (the 4 beside the 5's green line in
        /// Brooklyn), doesn't pass over it.
        var passesUnder: Bool { crosses || (!ownLineDrawn && !atStation) }
    }

    /// Where a glide's path passes under another line (an overpass on the map, such as the A/C/E and B/D/F/M over the
    /// 1/2/3 at Columbus Circle), as the outlines of the upper lines' bands in map units: the stretch of the upper line
    /// near the crossing, as wide as the line with its black casing. TrainLayers hides the part of the dot inside them.
    ///
    /// Where the path crosses another line's stroke, the train is under it if its own line there is drawn earlier, or
    /// isn't drawn at all: the map draws some lines continuously and overdraws them (the 2/3 at Columbus Circle), and
    /// leaves a gap in others where they pass under (the 1 there), which the track network bridges.
    ///
    /// Only lines the train actually passes under count (OverpassHit.passesUnder): one it merely runs alongside, inside
    /// the edge of its band, doesn't hide it. A line drawn in pieces that meet where the train crosses it (the orange B/D
    /// lines the 2/3 express pass under at Columbus Circle) is crossed at one piece and only brushed at the next, as the
    /// path slips out through the joint: a brushed line counts when the same line is crossed within 20 map units.
    func overpasses(path: [CGPoint]) -> [CGPath] {
        let hits = overpassHits(path: path)
        return hits.filter { hit in
            hit.passesUnder
                || hits.contains { $0.crosses && $0.color == hit.color && hypot($0.at.x - hit.at.x, $0.at.y - hit.at.y) < 20 }
        }.map(\.band)
    }

    /// Every line whose band the path runs into and isn't its own or drawn under it (see `overpasses`).
    func overpassHits(path: [CGPoint]) -> [OverpassHit] {
        guard path.count > 1 else { return [] }
        let line = Polyline(path)
        guard line.length > 0 else { return [] }
        let xs = path.map(\.x), ys = path.map(\.y)
        let box = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        // Points along the path, one per map unit.
        let count = Int(line.length) + 1
        let samples = (0...count).map { line.point(at: CGFloat($0) * line.length / CGFloat(count)) }
        var hits: [OverpassHit] = []
        for s in strokes where s.points.count > 1 && s.box.insetBy(dx: -s.half, dy: -s.half).intersects(box) {
            // Runs of the path inside this line's band (within its half-width, casing included). Testing the band
            // rather than the center line also catches a line drawn in two pieces that meet where the path crosses
            // (the orange B/D at Columbus Circle, which the 1 passes under right at such a joint).
            let near = samples.map { Locator.nearest(on: s.points, to: $0) }
            var k = 0
            while k < samples.count {
                guard near[k].distance < s.half else { k += 1; continue }
                let runStart = k
                var end = k
                while end + 1 < samples.count, near[end + 1].distance < s.half { end += 1 }
                let mid = (runStart...end).min { near[$0].distance < near[$1].distance }!
                k = end + 1
                let direction = samples[min(mid + 1, samples.count - 1)] - samples[max(mid - 1, 0)]
                let segment = near[mid].segment
                // Following the line (on its center for 8+ map units) rather than crossing it: its own track. A line
                // only brushed in passing doesn't count, even where it points the same way (the orange B/D curve,
                // which the 1 passes under at the point where the curve runs diagonally, like the 1).
                if (runStart...end).filter({ near[$0].distance < 1.5 }).count >= 8 { continue }
                // The train's own line at the crossing: the strokes running along the path through this point. A line
                // can be drawn in several overlapping pieces (the red 2/3 at Borough Hall), so the topmost one counts.
                let at = samples[mid]
                let own = strokes.filter { o in
                    o.order != s.order && o.box.insetBy(dx: -2, dy: -2).contains(at)
                        && Locator.runsAlong(o.points, at: at, direction: direction)
                }.max { $0.order < $1.order }
                if let own, own.order > s.order { continue }  // drawn later: the train is on top
                // Crossing: just before the run and just after it, the path is on opposite sides of the line.
                func side(_ i: Int) -> CGFloat {
                    let a = s.points[near[i].segment], b = s.points[near[i].segment + 1], p = samples[i]
                    return (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
                }
                // (A path that starts or ends inside the band, at a station under the line, uses its first or last
                // point there instead: Eastern Pkwy, under the Q, where the 4 sets off.)
                let before = max(runStart - 1, 0), after = min(end + 1, samples.count - 1)
                let crosses = before < after && side(before) * side(after) < 0
                hits.append(OverpassHit(band: Locator.band(s.points, from: segment, around: near[mid].point, half: s.half),
                                        crosses: crosses, ownLineDrawn: own != nil,
                                        atStation: runStart == 0 || end == samples.count - 1, color: s.color, at: at))
            }
        }
        return hits
    }

    /// For checking (`--visibility-audit`): walks a glide's path one map unit at a time and says at each point whether
    /// the train should be hidden, judged straight from the map's drawing order, and whether `overpasses` hides it.
    /// Expected: another line is drawn on top here (the point is well inside its band, not just at the edge) and the
    /// track the train is on (any line right under the point, running the same way: its own, or the one a rerouted train
    /// borrows) is drawn earlier or missing. Points within 6 map units of either end are left out: there the train is
    /// still at a station's circle, off the line.
    func visibilityCheck(route: String, path: [CGPoint]) -> [(point: CGPoint, expected: Bool, actual: Bool)] {
        guard path.count > 1 else { return [] }
        let line = Polyline(path)
        guard line.length > 12 else { return [] }
        let bands = overpasses(path: path)
        let xs = path.map(\.x), ys = path.map(\.y)
        let box = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!).insetBy(dx: -8, dy: -8)
        let nearby = strokes.filter { $0.box.insetBy(dx: -$0.half, dy: -$0.half).intersects(box) }
        var out: [(point: CGPoint, expected: Bool, actual: Bool)] = []
        var along: CGFloat = 6
        while along <= line.length - 6 {
            let p = line.point(at: along)
            let direction = line.point(at: min(along + 1, line.length)) - line.point(at: max(along - 1, 0))
            let distances = nearby.map { Locator.nearest(on: $0.points, to: p).distance }
            let own = nearby.indices.filter { distances[$0] < 2 && Locator.runsAlong(nearby[$0].points, at: p, direction: direction) }
            let ownOrder = own.map { nearby[$0].order }.max()
            let above = nearby.indices.filter { k in !own.contains(k) && (ownOrder.map { nearby[k].order > $0 } ?? true) }
            let covered = above.contains { distances[$0] < nearby[$0].half - 1.5 }
            // At the very edge of a line's band (within 1.5 units of it) a dot is partly under it either way: skip.
            let edge = above.contains { abs(distances[$0] - nearby[$0].half) < 1.5 }
            if !edge { out.append((p, covered, bands.contains { $0.contains(p) })) }
            along += 1
        }
        return out
    }

    /// The nearest point of a polyline to `point`: its distance, the point, and the segment it lies on.
    private static func nearest(on points: [CGPoint], to point: CGPoint) -> (distance: CGFloat, point: CGPoint, segment: Int) {
        var best = (distance: CGFloat.infinity, point: points[0], segment: 0)
        for j in 0..<(points.count - 1) {
            let a = points[j], ab = points[j + 1] - a, length2 = ab.x * ab.x + ab.y * ab.y
            let t = length2 > 0 ? min(max(((point.x - a.x) * ab.x + (point.y - a.y) * ab.y) / length2, 0), 1) : 0
            let q = CGPoint(x: a.x + t * ab.x, y: a.y + t * ab.y)
            let d = hypot(q.x - point.x, q.y - point.y)
            if d < best.distance { best = (d, q, j) }
        }
        return best
    }

    /// True if two directions are within about 25° of each other (either way round).
    private static func aligned(_ a: CGPoint, _ b: CGPoint) -> Bool {
        let la = hypot(a.x, a.y), lb = hypot(b.x, b.y)
        guard la > 0, lb > 0 else { return false }
        return abs((a.x * b.x + a.y * b.y) / (la * lb)) > 0.9
    }

    /// True if a polyline passes within 1.5 map units of `point` along `direction`.
    private static func runsAlong(_ points: [CGPoint], at point: CGPoint, direction: CGPoint) -> Bool {
        for (a, b) in zip(points, points.dropFirst()) {
            let ab = b - a, length2 = ab.x * ab.x + ab.y * ab.y
            guard length2 > 0 else { continue }
            let t = min(max(((point.x - a.x) * ab.x + (point.y - a.y) * ab.y) / length2, 0), 1)
            let near = CGPoint(x: a.x + t * ab.x, y: a.y + t * ab.y)
            if hypot(near.x - point.x, near.y - point.y) < 1.5, aligned(ab, direction) { return true }
        }
        return false
    }

    /// The band of a stroke around a crossing: its stretch within about 25 map units of the point, as wide as the line
    /// with its casing (with rounded ends, so the bands of two pieces of one line leave no gap where they meet).
    private static func band(_ points: [CGPoint], from j: Int, around hit: CGPoint, half: CGFloat) -> CGPath {
        /// Points from `hit` along the stroke (backward through vertices j, j-1, … or forward through j+1, …), cut off
        /// exactly 25 map units away.
        func walk(_ indices: [Int]) -> [CGPoint] {
            var out: [CGPoint] = [], walked: CGFloat = 0, last = hit
            for k in indices {
                let step = hypot(points[k].x - last.x, points[k].y - last.y)
                if walked + step >= 25 {
                    let t = step > 0 ? (25 - walked) / step : 0
                    out.append(CGPoint(x: last.x + (points[k].x - last.x) * t, y: last.y + (points[k].y - last.y) * t))
                    break
                }
                walked += step
                last = points[k]
                out.append(points[k])
            }
            return out
        }
        let line = CGMutablePath()
        line.addLines(between: walk(Array(stride(from: j, through: 0, by: -1))).reversed() + [hit]
                      + walk(Array((j + 1)..<points.count)))
        return line.copy(strokingWithWidth: half * 2, lineCap: .round, lineJoin: .round, miterLimit: 2)  // round ends close joints
    }

    /// Platforms whose station is on the map (`stationOf` isn't nil), for the checks every trip gets every second.
    private let onMapPlatforms: Set<String>
    /// Each trip's last timeline (see `legs`), reused while nothing it depends on has changed.
    private var legsCache: [String: (signature: LegsSignature, legs: [Leg]?)] = [:]
    private struct LegsSignature: Equatable {
        let feed: String, count: Int, first: String?, times: Double, vehicle: String?, status: String?, hint: String?, how: String
    }

    /// The trip as motion sees it: without the stops that aren't stations on the map, and with no vehicle stop if that
    /// isn't one (it is then on its way to its first stop on the map). The feed gives the R under the East River its
    /// next stop as R60N, a stop that isn't a station, for a couple of minutes: the notebook's rule hides a train it
    /// can't place, so its dot faded out at Lexington Av/59 St and back in at Queens Plaza. (`locate` itself keeps the
    /// notebook's rule.)
    ///
    /// Also, for a trip with a train, without the stops listed at the front with times more than the stale limit in the
    /// past while a later stop is still to come: the feed kept listing a 6 train's passed stops ("14 St-Union Sq, 173 s ago") ahead of Grand
    /// Central, and the notebook's rule, which takes a trip whose first stop is that old for a leftover, hid it.
    func onMap(_ trip: Trip, now: Double) -> Trip {
        let stale = now - net.settings.staleAfterS
        let vehicleOnMap = trip.vehicleStop.map { $0.isEmpty || onMapPlatforms.contains($0) } ?? true
        // Quick: every stop on the map, and nothing stale at the front (most trips, every second).
        if vehicleOnMap, trip.status == nil || (trip.upcoming.first.map { $0.time >= stale } ?? true),
           trip.upcoming.allSatisfy({ onMapPlatforms.contains($0.stop) }) {
            return trip
        }
        var upcoming = trip.upcoming.filter { onMapPlatforms.contains($0.stop) }
        // Passed stops at the front, while a later one is still fresh: only for a trip with a train running it (one with
        // no train whose times have all gone by is a leftover, and stays hidden).
        // Never the stop the train is heading for, however late it is there (a 7 overdue at Mets-Willets Point); but a
        // report of standing at a stop that old is stuck (a 6 "at 14 St-Union Sq" for minutes as its times moved on),
        // and that stop goes too (the timeline then works from the stops ahead and where the dot is).
        if trip.status != nil, var fresh = upcoming.firstIndex(where: { $0.time >= stale }), fresh > 0 {
            if trip.status != "STOPPED_AT", let vehicle = upcoming.firstIndex(where: { $0.stop == trip.vehicleStop }) {
                fresh = min(fresh, vehicle)
            }
            upcoming.removeFirst(fresh)
        }
        if upcoming.count == trip.upcoming.count && vehicleOnMap { return trip }
        return Trip(feed: trip.feed, tripID: trip.tripID, routeID: trip.routeID,
                    status: vehicleOnMap || trip.status == nil ? trip.status : "IN_TRANSIT_TO",
                    vehicleStop: vehicleOnMap ? trip.vehicleStop : nil, upcoming: upcoming)
    }

    /// True if one of the route's patterns stops at station `a` and then, within 8 stops, at platform `stop`.
    func runsBefore(route: String, _ a: String, _ stop: String) -> Bool {
        (patternsByRoute[route] ?? []).contains { p in
            guard let i = p.index[stop], i > 0 else { return false }
            return p.stops[max(i - 8, 0)..<i].contains { stationOf($0) == a }
        }
    }

    /// The name of the station whose center is nearest `point` (for problems' details).
    func nearestStationName(to point: CGPoint) -> String {
        net.stations.values.min { hypot($0.center[0] - point.x, $0.center[1] - point.y) < hypot($1.center[0] - point.x, $1.center[1] - point.y) }?.name ?? "?"
    }

    /// A station's name ("59 St-Columbus Circle"), or its ID if it isn't on the map.
    func stationName(_ station: String) -> String { net.stations[station]?.name ?? station }

    /// The station of a platform (nil if it isn't on the map).
    func stationOf(_ platform: String) -> String? {
        guard let s = net.platforms[platform], net.stations[s] != nil else { return nil }
        return s
    }
}

private func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }

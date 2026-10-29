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
        lines = network.routeLines.mapValues { $0.map { Polyline($0.map(CGPoint.init)) } }
        strokes = (network.routeStrokes ?? []).map { stroke in
            let points = stroke.points.map(CGPoint.init)
            let xs = points.map(\.x), ys = points.map(\.y)
            let box = CGRect(x: xs.min() ?? 0, y: ys.min() ?? 0, width: (xs.max() ?? 0) - (xs.min() ?? 0),
                             height: (ys.max() ?? 0) - (ys.min() ?? 0))
            return (stroke.order, CGFloat(stroke.halfWidth), points, box)
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

    /// Each route line as the map draws it (SubwayNetwork.Stroke), with its bounding box for quick rejection.
    private let strokes: [(order: Int, half: CGFloat, points: [CGPoint], box: CGRect)]

    /// Where a glide's path passes under another line (an overpass on the map, such as the A/C/E and B/D/F/M over the
    /// 1/2/3 at Columbus Circle), as the outlines of the upper lines' bands in map units: the stretch of the upper line
    /// near the crossing, as wide as the line with its black casing. TrainLayers hides the part of the dot inside them.
    ///
    /// Where the path crosses another line's stroke, the train is under it if its own line there is drawn earlier, or
    /// isn't drawn at all: the map draws some lines continuously and overdraws them (the 2/3 at Columbus Circle), and
    /// leaves a gap in others where they pass under (the 1 there), which the track network bridges.
    func overpasses(path: [CGPoint]) -> [CGPath] {
        guard path.count > 1 else { return [] }
        let line = Polyline(path)
        guard line.length > 0 else { return [] }
        let xs = path.map(\.x), ys = path.map(\.y)
        let box = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        // Points along the path, one per map unit.
        let count = Int(line.length) + 1
        let samples = (0...count).map { line.point(at: CGFloat($0) * line.length / CGFloat(count)) }
        var bands: [CGPath] = []
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
                // The train's own line at the crossing: another stroke running along the path through this point.
                let at = samples[mid]
                let own = strokes.first { o in
                    o.order != s.order && o.box.insetBy(dx: -2, dy: -2).contains(at)
                        && Locator.runsAlong(o.points, at: at, direction: direction)
                }
                if let own, own.order > s.order { continue }  // drawn later: the train is on top
                bands.append(Locator.band(s.points, from: segment, around: near[mid].point, half: s.half))
            }
        }
        return bands
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

    /// The station of a platform (nil if it isn't on the map).
    func stationOf(_ platform: String) -> String? {
        guard let s = net.platforms[platform], net.stations[s] != nil else { return nil }
        return s
    }
}

private func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }

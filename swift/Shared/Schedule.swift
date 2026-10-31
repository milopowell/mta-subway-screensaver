import Foundation

/// The MTA timetable (schedule.json, from the notebook's §8): what runs on lines without live data. When the
/// screensaver starts with no internet, the connection drops, or one feed is down, its trains run from here at real
/// speed instead.
///
/// `trips(at:feeds:)` describes every train that should be running now as the live feed would: the stops still ahead
/// with their times, standing at a platform or heading for the next one. So the motion planner, the map and the
/// next-train board treat them exactly like live trains. Each one keeps the MTA's trip code (start time, route,
/// direction), which the live feed uses too (Trip.identity), so when live data returns each live train takes over its
/// scheduled twin and glides on from there.
final class Schedule {
    /// Which live feed carries each route.
    let feedOf: [String: String]
    private let services: [String: (days: [Bool], start: String, end: String)]
    /// Holidays: date (yyyyMMdd) → services added and removed that day.
    private let exceptions: [String: (add: Set<String>, remove: Set<String>)]
    private let groups: [Group]
    /// New York time: the timetable's clock.
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()

    /// Trips that share a route, stops and running times, listed by start.
    private struct Group {
        let service: String
        let route: String
        let feed: String
        let stops: [String]
        /// The rest of each trip's ID after its start code, e.g. "1..S03R".
        let suffix: String
        /// Seconds from the start (code × 0.6 s) to the arrival at, and departure from, each stop.
        let arrive: [Double]
        let depart: [Double]
        /// Start codes: hundredths of a minute after midnight (000600 = 00:06).
        let codes: [Int]
    }

    init(json data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let services = root["services"] as? [String: [String: Any]],
              let feeds = root["feeds"] as? [String: String],
              let patterns = root["patterns"] as? [[Any]],
              let groups = root["groups"] as? [[Any]] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        feedOf = feeds
        self.services = services.mapValues { s in
            ((s["days"] as? [Int] ?? []).map { $0 == 1 }, s["start"] as? String ?? "", s["end"] as? String ?? "")
        }
        exceptions = (root["exceptions"] as? [String: [String: [String]]] ?? [:]).mapValues {
            (Set($0["add"] ?? []), Set($0["remove"] ?? []))
        }
        self.groups = groups.compactMap { g -> Group? in
            // [service, pattern, suffix, first arrival, seconds between arrivals, dwells (0 = none), codes]
            guard g.count == 7, let service = g[0] as? String, let p = g[1] as? Int, p < patterns.count,
                  let route = patterns[p][0] as? String, let stops = patterns[p][1] as? [String],
                  let suffix = g[2] as? String, let first = g[3] as? Int, let hops = g[4] as? [Int],
                  let codes = g[6] as? [Int], hops.count == stops.count - 1 else { return nil }
            var arrive = [Double(first)]
            for hop in hops { arrive.append(arrive[arrive.count - 1] + Double(hop)) }
            let dwell = (g[5] as? [Int])?.map(Double.init) ?? Array(repeating: 0, count: stops.count)
            return Group(service: service, route: route, feed: feeds[route] ?? "", stops: stops, suffix: suffix,
                         arrive: arrive, depart: zip(arrive, dwell).map { $0 + $1 }, codes: codes)
        }
    }

    /// Loads schedule.json from the bundled resources; nil for an export made before the timetable was added.
    static func loadBundled() -> Schedule? {
        guard let url = SubwayView.resources.url(forResource: "schedule", withExtension: "json") else { return nil }
        do {
            return try Schedule(json: Data(contentsOf: url))
        } catch {
            NSLog("Schedule: couldn't read schedule.json: %@", error.localizedDescription)
            return nil
        }
    }

    /// The services running on the day that starts at `midnight`: by weekday within their dates, with holiday changes.
    /// Outside every service's dates (a schedule that hasn't started yet, or has run out), by weekday alone, so the
    /// lines still run on the nearest timetable rather than not at all.
    private func services(on midnight: Date) -> Set<String> {
        let day = calendar.component(.weekday, from: midnight)  // 1 = Sunday
        let index = (day + 5) % 7  // Monday = 0, as in GTFS
        let ymd = String(format: "%04d%02d%02d", calendar.component(.year, from: midnight),
                         calendar.component(.month, from: midnight), calendar.component(.day, from: midnight))
        let dated = services.filter { $0.value.start <= ymd && ymd <= $0.value.end }
        if dated.isEmpty {
            return Set(services.filter { $0.value.days.indices.contains(index) && $0.value.days[index] }.keys)
        }
        var running = Set(dated.filter { $0.value.days.indices.contains(index) && $0.value.days[index] }.keys)
        if let change = exceptions[ymd] {
            running.formUnion(change.add)
            running.subtract(change.remove)
        }
        return running
    }

    /// Every train of `feeds` that should be running at `now` (or leaves its first stop within `parkWindow`
    /// seconds), described as the live feed would describe it.
    func trips(at now: Double, feeds: Set<String>, parkWindow: Double) -> [Trip] {
        guard !feeds.isEmpty else { return [] }
        var trips: [Trip] = []
        let today = calendar.startOfDay(for: Date(timeIntervalSince1970: now))
        // Yesterday's service too: its late trips run past midnight (GTFS times beyond 24:00).
        for dayOffset in [-1, 0] {
            guard let midnight = calendar.date(byAdding: .day, value: dayOffset, to: today) else { continue }
            let running = services(on: midnight)
            let base = midnight.timeIntervalSince1970
            for group in groups where running.contains(group.service) && feeds.contains(group.feed) {
                let first = group.depart[0], last = group.arrive[group.arrive.count - 1]
                for code in group.codes {
                    let start = base + Double(code) * 0.6
                    guard now >= start + first - parkWindow, now <= start + last else { continue }
                    trips.append(trip(group, code: code, start: start, now: now))
                }
            }
        }
        return trips
    }

    /// One scheduled train at `now`: standing at a platform while it dwells there, otherwise heading for its next
    /// stop; before it leaves its first stop, no train assigned yet (the locator parks it there, as for live trips).
    private func trip(_ g: Group, code: Int, start: Double, now: Double) -> Trip {
        // The first stop it hasn't left yet.
        let next = g.depart.firstIndex { start + $0 >= now } ?? g.stops.count - 1
        let upcoming = (next..<g.stops.count).map { k in
            // At a trip's first stop the time is its departure (it has no arrival), as in the live feed.
            StopTime(stop: g.stops[k], time: start + (k == 0 ? g.depart[0] : g.arrive[k]), departure: start + g.depart[k])
        }
        let status: String?
        if next == 0 && now < start + g.depart[0] {
            status = nil
        } else if now >= start + g.arrive[next] {
            status = "STOPPED_AT"
        } else {
            status = "IN_TRANSIT_TO"
        }
        return Trip(feed: g.feed, tripID: String(format: "%06d_", code) + g.suffix, routeID: g.route,
                    status: status, vehicleStop: status == nil ? nil : g.stops[next], upcoming: upcoming)
    }
}

extension Trip {
    /// The MTA's code for a trip: start (hundredths of a minute after midnight), route and direction, e.g.
    /// "083100_A..N" for both the live "083100_A..N" and the timetable's "083100_A..N04R" (the pattern part after the
    /// direction differs between the two). Lets a live train take over its scheduled twin. Falls back to the whole ID.
    var identity: String {
        let parts = tripID.split(separator: "_", maxSplits: 1)
        guard parts.count == 2, parts[0].allSatisfy(\.isNumber),
              let dots = parts[1].firstIndex(of: ".") else { return tripID }
        let rest = parts[1][dots...].drop { $0 == "." }
        guard let direction = rest.first, direction == "N" || direction == "S" else { return tripID }
        return "\(parts[0])_\(parts[1][..<dots])..\(direction)"
    }
}

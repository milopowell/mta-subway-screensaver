import Foundation

/// What actually happened: for each trip, the stations it reached and when, worked out from successive feed
/// downloads. Used by the time-lapse (to replay real movements) and by the preview app's --timing-report.
///
/// The feed lists only the stops a train has not finished with, so a station dropping off a trip's list means
/// the train has been there and left. For that station:
///   arrival   = the time reported in the first download that says the train is STOPPED_AT it; if the train was
///               never seen standing there (a short stop between downloads), the last time predicted before it
///               arrived. (While a train stands at a station some lines keep moving its "arrival" forward to the
///               present, so the last reported arrival would really be the departure.)
///   departure = the last time reported for the station before it dropped off.
/// A train that leaves the feed altogether (its trip ended) is credited with the stations it was last seen at.
///
/// Visits are kept in the order the trip lists its stops, and their times are made consistent: the MTA's times for
/// neighbouring stations sometimes contradict each other (a last prediction made up to a download earlier can be
/// later than the next station's actual arrival). Times only ever move earlier, from the newest visit backwards,
/// so each hop takes at least `minimumHop` seconds; the newest times (usually "stopped at" reports) are trusted.
final class TripHistory {
    struct Visit {
        let station: String
        let arrive: Double, depart: Double
    }

    struct Record {
        let route: String
        /// Stations reached, in order.
        var visits: [Visit] = []
        /// True once the trip has left the feed (finished its run).
        var ended = false
    }

    /// How many seconds of visits to keep.
    let keep: Double
    /// Shortest believable time between leaving one station and reaching the next.
    var minimumHop: Double = 20
    private(set) var records: [String: Record] = [:]
    /// The first and latest download observed.
    private(set) var firstObserved: Double?, lastObserved: Double?
    /// How each arrival time was found (for the timing report).
    private(set) var arrivalsFromStopped = 0, arrivalsFromPrediction = 0

    private struct Seen {
        var stoppedAt: Double? = nil, lastPredicted: Double? = nil, last: Double
        var order = 0  // position in the trip's list of stops
    }
    /// trip → station → what the feed said while that station was still listed
    private var seen: [String: [String: Seen]] = [:]
    private let platforms: [String: String]

    /// - Parameters:
    ///   - platforms: stop ID → station ID (network.json `platforms`).
    ///   - keep: seconds of visits to keep (older ones are forgotten).
    init(platforms: [String: String], keep: Double) {
        self.platforms = platforms
        self.keep = keep
    }

    /// The recorded visit of a trip to a station, if it has happened.
    func visit(trip key: String, station: String) -> Visit? {
        records[key]?.visits.first { $0.station == station }
    }

    /// Takes in one download: every current trip, and the time it was downloaded. `downloaded` names the feeds
    /// that actually downloaded this round (nil = all): a trip missing from a feed that failed hasn't ended.
    func observe(_ trips: [Trip], at: Double, downloaded: Set<String>? = nil) {
        firstObserved = firstObserved ?? at
        lastObserved = at
        var present = Set<String>()
        for trip in trips {
            let key = "\(trip.feed)|\(trip.tripID)"
            present.insert(key)
            let standingAt = trip.status == "STOPPED_AT" ? trip.vehicleStop.flatMap { platforms[$0] } : nil
            var listed: [String: Seen] = [:]
            for (order, stop) in trip.upcoming.enumerated() {
                guard let station = platforms[stop.stop], listed[station] == nil else { continue }
                var entry = seen[key]?[station] ?? Seen(last: stop.time)
                entry.last = stop.departure ?? stop.time
                entry.order = order
                if station == standingAt {
                    entry.stoppedAt = entry.stoppedAt ?? stop.time
                } else if entry.stoppedAt == nil {
                    entry.lastPredicted = stop.time
                }
                listed[station] = entry
            }
            if records[key] == nil { records[key] = Record(route: trip.routeID) }
            let passed = (seen[key] ?? [:]).filter { listed[$0.key] == nil }
            record(passed, for: key, at: at)
            seen[key] = listed
        }
        // Trips that have left the feed: credit the stations they were standing at (their terminal).
        for (key, stations) in seen where !present.contains(key)
            && downloaded.map({ $0.contains(String(key.prefix { $0 != "|" })) }) ?? true {
            record(stations.filter { $0.value.stoppedAt != nil }, for: key, at: at)
            records[key]?.ended = true
            seen[key] = nil
        }
        forget(before: at - keep)
    }

    private func record(_ passed: [String: Seen], for key: String, at: Double) {
        var visits: [(order: Int, visit: Visit)] = []
        for (station, entry) in passed.sorted(by: { $0.value.order < $1.value.order }) {
            // Skip stations the train didn't reach (dropped by a reroute): their time wasn't due yet.
            guard let arrive = entry.stoppedAt ?? entry.lastPredicted, arrive <= at + 30 else { continue }
            if entry.stoppedAt != nil { arrivalsFromStopped += 1 } else { arrivalsFromPrediction += 1 }
            visits.append((entry.order, Visit(station: station, arrive: arrive, depart: max(entry.last, arrive))))
        }
        guard !visits.isEmpty, var all = records[key]?.visits else { return }
        all += visits.map(\.visit)
        // Make the times consistent, newest first: each visit must end at least `minimumHop` before the next begins.
        for k in stride(from: all.count - 2, through: 0, by: -1) {
            let depart = min(all[k].depart, all[k + 1].arrive - minimumHop)
            if depart < all[k].depart || all[k].arrive > depart {
                all[k] = Visit(station: all[k].station, arrive: min(all[k].arrive, depart), depart: depart)
            }
        }
        records[key]?.visits = all
    }

    private func forget(before cutoff: Double) {
        for (key, record) in records {
            let kept = record.visits.filter { $0.depart >= cutoff }
            if kept.isEmpty, record.ended || seen[key] == nil {
                records[key] = nil
            } else if kept.count != record.visits.count {
                records[key]?.visits = kept
            }
        }
    }
}

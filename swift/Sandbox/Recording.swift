import Foundation

/// A recording of the live feed: every download (30 s apart) for as long as it ran, saved as JSON so a moment you
/// saw in the screensaver can be replayed in the sandbox, as often as needed, while you fix it.
///
/// Each trip keeps its next 12 stops (the motion planner never needs more), which keeps a 30-minute recording to
/// about 30 MB (about 500 KB per download).
struct Recording: Codable {
    struct Stop: Codable {
        let stop: String
        let time: Double
        let departure: Double?
    }

    struct TripRecord: Codable {
        let feed: String, tripID: String, routeID: String
        let status: String?, vehicleStop: String?
        let upcoming: [Stop]
    }

    struct Snapshot: Codable {
        let at: Double  // when it was downloaded (unix time)
        let trips: [TripRecord]
    }

    var snapshots: [Snapshot] = []

    var start: Double { snapshots.first?.at ?? 0 }
    var end: Double { snapshots.last?.at ?? 0 }

    mutating func add(_ trips: [Trip], at: Double) {
        snapshots.append(Snapshot(at: at, trips: trips.map { trip in
            TripRecord(feed: trip.feed, tripID: trip.tripID, routeID: trip.routeID, status: trip.status,
                       vehicleStop: trip.vehicleStop,
                       upcoming: trip.upcoming.prefix(12).map { Stop(stop: $0.stop, time: $0.time, departure: $0.departure) })
        }))
    }

    /// The trips as the last download at or before `time` reported them (the first download before the recording
    /// starts; nothing after it ends).
    func trips(at time: Double) -> [Trip] {
        guard time <= end + 30, let snapshot = snapshots.last(where: { $0.at <= time }) ?? snapshots.first else { return [] }
        return snapshot.trips.map { record in
            Trip(feed: record.feed, tripID: record.tripID, routeID: record.routeID, status: record.status,
                 vehicleStop: record.vehicleStop,
                 upcoming: record.upcoming.map { StopTime(stop: $0.stop, time: $0.time, departure: $0.departure) })
        }
    }
}

/// A saved set of trains sent by hand, to load again later ("rush hour at Columbus Circle"). Each train is sent
/// again as it was, including how long ago it was sent, so it reappears where it was. Delays and jumps are not kept.
struct Scenario: Codable {
    struct SentTrain: Codable {
        let route: String
        let from: String, to: String  // station IDs
        let pace: Double
        let secondsAgo: Double  // how long before saving it was sent
    }

    var trains: [SentTrain]
}

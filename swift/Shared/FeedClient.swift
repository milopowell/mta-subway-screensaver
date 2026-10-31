import Foundation
import SwiftProtobuf

/// Downloads and decodes the MTA's GTFS-Realtime feeds: the Swift twin of the notebook's fetch_all() (§5).
enum FeedClient {
    /// GTFS-Realtime vehicle status codes, with the names the notebook uses.
    private static func statusName(_ status: TransitRealtime_VehiclePosition.VehicleStopStatus) -> String {
        switch status {
        case .incomingAt: return "INCOMING_AT"
        case .stoppedAt: return "STOPPED_AT"
        case .inTransitTo: return "IN_TRANSIT_TO"
        }
    }

    /// Turns one decoded feed into trips, exactly like the loop in fetch_all():
    /// every trip_update becomes a Trip; its vehicle record (if any) supplies status and stop.
    static func trips(from message: TransitRealtime_FeedMessage, feed: String) -> [Trip] {
        var updates: [(id: String, update: TransitRealtime_TripUpdate)] = []
        var updateIndex: [String: Int] = [:]  // later duplicates replace earlier ones, keeping first position
        var vehicles: [String: TransitRealtime_VehiclePosition] = [:]
        for entity in message.entity {
            if entity.hasTripUpdate {
                let id = entity.tripUpdate.trip.tripID
                if let k = updateIndex[id] {
                    updates[k].update = entity.tripUpdate
                } else {
                    updateIndex[id] = updates.count
                    updates.append((id, entity.tripUpdate))
                }
            }
            if entity.hasVehicle {
                vehicles[entity.vehicle.trip.tripID] = entity.vehicle
            }
        }
        return updates.map { id, update in
            let vehicle = vehicles[id]
            let upcoming = update.stopTimeUpdate.map { stu in
                // `time`: the arrival time, or the departure time at a trip's first stop (which has no arrival),
                // exactly as the notebook. `departure` is kept separately for smooth motion.
                StopTime(stop: stu.stopID, time: Double(stu.hasArrival ? stu.arrival.time : stu.departure.time),
                         departure: stu.hasDeparture ? Double(stu.departure.time) : nil)
            }
            return Trip(feed: feed, tripID: id, routeID: update.trip.routeID,
                        status: vehicle.map { statusName($0.currentStatus) },
                        vehicleStop: vehicle?.stopID, upcoming: upcoming)
        }
    }

    /// The connection used for feed downloads: no caching (every download must be fresh, and a screensaver
    /// shouldn't fill a cache) and a 15 s timeout, so one slow feed can't hold up a round for long.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()

    /// Downloads all feeds at the same time. Returns the trips of each feed that succeeded, keyed by feed,
    /// plus the time just before downloading (used as "now" for placement, like `fetched_at` in the notebook).
    ///
    /// A feed counts as failed (and is left out) on a network error, an HTTP error, unreadable data, or when
    /// it contains no trips at all. The MTA occasionally serves an empty feed for a moment; treating it as a
    /// failure lets `FeedCache` keep that line's trains on screen.
    static func fetchEach(settings: SubwayNetwork.Settings) async -> (feeds: [String: [Trip]], fetchedAt: Double) {
        let fetchedAt = Date().timeIntervalSince1970
        let feeds = await withTaskGroup(of: (String, [Trip]?).self) { group in
            for feed in settings.feeds {
                group.addTask {
                    let url = URL(string: settings.feedURL.replacingOccurrences(of: "{}", with: feed))!
                    do {
                        let (data, response) = try await session.data(from: url)
                        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                        guard status == 200 else { throw URLError(.badServerResponse) }
                        let found = trips(from: try TransitRealtime_FeedMessage(serializedBytes: data), feed: feed)
                        guard !found.isEmpty else { throw URLError(.zeroByteResource) }
                        return (feed, found)
                    } catch {
                        NSLog("FeedClient: %@ failed: %@", feed, error.localizedDescription)
                        return (feed, nil)
                    }
                }
            }
            var collected: [String: [Trip]] = [:]
            for await (feed, trips) in group { collected[feed] = trips }
            return collected
        }
        return (feeds, fetchedAt)
    }

    /// Downloads all feeds and returns every trip in the notebook's feed order. Failed feeds contribute nothing.
    static func fetchAll(settings: SubwayNetwork.Settings) async -> (trips: [Trip], fetchedAt: Double) {
        let (feeds, fetchedAt) = await fetchEach(settings: settings)
        return (settings.feeds.flatMap { feeds[$0] ?? [] }, fetchedAt)
    }

    /// Reads feeds saved as <dir>/<feed>.pb (for testing against the notebook on identical data).
    static func load(fromDirectory dir: URL, settings: SubwayNetwork.Settings) throws -> [Trip] {
        try settings.feeds.flatMap { feed in
            let data = try Data(contentsOf: dir.appendingPathComponent("\(feed).pb"))
            return trips(from: try TransitRealtime_FeedMessage(serializedBytes: data), feed: feed)
        }
    }
}

/// Keeps the last good download of each feed, so a feed that fails for a moment (a timeout, a brief network
/// drop, an empty response) doesn't make its trains vanish and fade back in somewhere else 30 s later.
/// Trains from a held feed keep following their predicted timetable. A held feed is dropped once it is
/// `keepFor` seconds old (the stale limit), because by then its predictions are out of date anyway.
struct FeedCache {
    /// Every feed, in the notebook's order.
    let feeds: [String]
    let keepFor: Double
    private var latest: [String: (trips: [Trip], at: Double)] = [:]
    /// Feeds that failed in the latest round.
    private(set) var failed: [String] = []
    /// When the latest round started.
    private(set) var lastRound: Double?
    /// When any feed last downloaded successfully.
    private(set) var lastSuccess: Double?

    init(feeds: [String], keepFor: Double) {
        self.feeds = feeds
        self.keepFor = keepFor
    }

    /// Takes in one download round. `fresh` holds only the feeds that succeeded; the others keep their
    /// previous download until it is too old.
    mutating func receive(_ fresh: [String: [Trip]], at: Double) {
        for (feed, trips) in fresh { latest[feed] = (trips, at) }
        latest = latest.filter { at - $0.value.at <= keepFor }
        failed = feeds.filter { fresh[$0] == nil }
        lastRound = at
        if !fresh.isEmpty { lastSuccess = at }
    }

    /// Every trip currently held, in feed order.
    var trips: [Trip] { feeds.flatMap { latest[$0]?.trips ?? [] } }

    /// True when every feed failed in the latest round: no connection, or the MTA's servers are down.
    var isOffline: Bool { lastRound != nil && failed.count == feeds.count }

    /// Feeds with no data at all: failed, and nothing held from earlier (or held too long). Their lines run from the
    /// timetable (Schedule). Empty until the first round has been tried.
    var withoutData: Set<String> {
        lastRound == nil ? [] : Set(feeds.filter { latest[$0] == nil })
    }
}

/// One download loop shared by every SubwayView in the process. The screensaver gets a view per display (plus a small
/// one for the thumbnail in System Settings); they all share these downloads instead of each fetching the feeds.
/// The loop runs while at least one view is subscribed.
@MainActor
final class FeedHub {
    static let shared = FeedHub()
    typealias Handler = @MainActor (_ fresh: [String: [Trip]], _ fetchedAt: Double) -> Void

    /// Seconds between downloads (the MTA updates the feeds about every 30 s).
    var pollInterval: TimeInterval = 30
    /// Seconds before trying again after a download in which any feed failed.
    var retryInterval: TimeInterval = 10

    private var handlers: [UUID: Handler] = [:]
    private var task: Task<Void, Never>?
    /// The latest download, handed straight to views that subscribe while the loop is running.
    private var latest: (fresh: [String: [Trip]], at: Double)?

    /// Starts receiving downloads (the first right away, or the latest one if the loop is already running).
    func subscribe(settings: SubwayNetwork.Settings, handler: @escaping Handler) -> UUID {
        let id = UUID()
        handlers[id] = handler
        if let latest { handler(latest.fresh, latest.at) }
        if task == nil { run(settings) }
        return id
    }

    /// Stops receiving downloads; the loop stops when nobody is subscribed.
    func unsubscribe(_ id: UUID) {
        handlers[id] = nil
        if handlers.isEmpty {
            task?.cancel()
            task = nil
            latest = nil  // stale by the time anyone subscribes again
        }
    }

    private func run(_ settings: SubwayNetwork.Settings) {
        task = Task { [weak self] in
            while !Task.isCancelled {
                let (fresh, at) = await FeedClient.fetchEach(settings: settings)
                guard let self, !Task.isCancelled else { return }
                self.latest = (fresh, at)
                for handler in self.handlers.values { handler(fresh, at) }
                let wait = fresh.count == settings.feeds.count ? self.pollInterval : self.retryInterval
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
    }
}

import Foundation

/// A pretend live feed for the sandbox: trains you send by hand, turned into the same `Trip` records the real
/// feeds produce. The app's own Locator, MotionPlanner and TrainLayers then move them exactly as they would move real
/// trains, so whatever you change in that code shows up here too.
///
/// Each train has a timetable: when it reaches and leaves every stop. A snapshot (one "download") reports each
/// train the way the MTA does: standing at a stop (STOPPED_AT), or on its way to the next one (IN_TRANSIT_TO), with
/// the predicted times of the stops still ahead.
final class SimulatedFeed {
    struct Train {
        let id: Int
        let route: String
        let platforms: [String]  // platform IDs in travel order
        var arrivals: [Double]  // unix times: when it reaches each stop (the first: when it was sent)
        var departures: [Double]  // … and leaves it (the last: when it leaves the data)
        let label: String  // "1: 59 St-Columbus Circle to 14 St"
    }

    private(set) var trains: [Train] = []
    /// Seconds a train stands at each station, and at its last one before it leaves the data.
    var dwell: Double = 15
    var finishHold: Double = 10
    private let net: SubwayNetwork
    private var nextID = 1

    init(network: SubwayNetwork) {
        net = network
    }

    /// A pattern's stops as (platform, station), with a station that repeats in a row kept once.
    private func stops(of pattern: SubwayNetwork.Pattern) -> [(platform: String, station: String)] {
        var result: [(platform: String, station: String)] = []
        for platform in pattern.stops {
            guard let station = net.platforms[platform], net.stations[station] != nil,
                  result.last?.station != station else { continue }
            result.append((platform, station))
        }
        return result
    }

    /// The route's stations in travel order (its busiest pattern), for the station pickers.
    func stations(of route: String) -> [String] {
        net.patterns.first { $0.route == route }.map { stops(of: $0).map(\.station) } ?? []
    }

    /// Sends a train along `route` from station `from` to station `to`, leaving after one dwell. `pace` divides the
    /// scheduled hop times (2 = twice as fast as the timetable). Nil when no pattern of the route runs from one to the
    /// other (in either direction: the pattern decides which way).
    @discardableResult
    func send(route: String, from: String, to: String, pace: Double, now: Double) -> Train? {
        for pattern in net.patterns where pattern.route == route {
            let list = stops(of: pattern)
            guard let i = list.firstIndex(where: { $0.station == from }),
                  let j = list[(i + 1)...].firstIndex(where: { $0.station == to }) else { continue }
            let platforms = list[i...j].map(\.platform)
            var arrivals = [now], departures = [now + dwell]
            for (a, b) in zip(platforms, platforms.dropFirst()) {
                let hop = (net.hopTimes["\(a)>\(b)"] ?? net.settings.defaultHopS) / pace
                arrivals.append(departures[departures.count - 1] + hop)
                departures.append(arrivals[arrivals.count - 1] + (b == platforms.last ? finishHold : dwell))
            }
            let name = { (s: String) in self.net.stations[s]?.name ?? s }
            let train = Train(id: nextID, route: route, platforms: platforms, arrivals: arrivals, departures: departures,
                              label: "\(RouteSymbolsView.label(for: route)): \(name(from)) to \(name(to))")
            nextID += 1
            trains.append(train)
            return train
        }
        return nil
    }

    /// Sends a train on a random route over a random run of `stops` stations (fewer if the route is shorter).
    @discardableResult
    func sendRandom(stops count: Int, pace: Double, now: Double) -> Train? {
        guard let pattern = net.patterns.filter({ $0.trips >= 20 }).randomElement() else { return nil }
        let list = stops(of: pattern)
        guard list.count >= 2 else { return nil }
        let length = min(count, list.count)
        let i = Int.random(in: 0...(list.count - length))
        return send(route: pattern.route, from: list[i].station, to: list[i + length - 1].station, pace: pace, now: now)
    }

    /// Shifts a train's remaining timetable by `seconds`: positive = running late, negative = further along than
    /// predicted (stops whose times move into the past count as passed).
    func shift(_ id: Int, by seconds: Double, now: Double) {
        guard let k = trains.firstIndex(where: { $0.id == id }) else { return }
        for i in trains[k].arrivals.indices {
            if trains[k].arrivals[i] > now { trains[k].arrivals[i] += seconds }
            if trains[k].departures[i] > now { trains[k].departures[i] += seconds }
        }
    }

    func remove(_ id: Int) {
        trains.removeAll { $0.id == id }
    }

    func removeAll() {
        trains.removeAll()
    }

    /// What a download would report now. Trains past their last departure leave the data (and are forgotten).
    func snapshot(now: Double) -> [Trip] {
        trains.removeAll { now >= $0.departures[$0.departures.count - 1] }
        return trains.map { train in
            let k = train.departures.firstIndex { $0 > now }!  // the stop it is at, or heading to
            let upcoming = (k..<train.platforms.count).map { i in
                // A trip's first stop has only a departure time, as in the real feeds.
                StopTime(stop: train.platforms[i], time: i == 0 ? train.departures[0] : train.arrivals[i],
                         departure: train.departures[i])
            }
            return Trip(feed: "sandbox", tripID: "T\(train.id)", routeID: train.route,
                        status: now >= train.arrivals[k] ? "STOPPED_AT" : "IN_TRANSIT_TO",
                        vehicleStop: train.platforms[k], upcoming: upcoming)
        }
    }
}

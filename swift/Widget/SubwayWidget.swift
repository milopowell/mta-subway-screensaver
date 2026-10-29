import AppIntents
import SwiftUI
import WidgetKit

// The desktop widget: the next trains at one station, each way, like a single station of the next-train board.
// It is built into SubwayPreview.app; add it from the desktop's Edit Widgets, and choose its station in Edit Widget.
//
// A widget can't run continuously. macOS asks it for a timeline about every 10 minutes: it downloads the feeds that
// serve its station once, and lays out one entry per minute from those predictions, so the minutes count down in
// between.

/// The bundled network, loaded once.
private let network = try? SubwayNetwork.loadBundled()

// ---- Choosing the station (Edit Widget) ----

struct StationEntity: AppEntity {
    let id: String
    let name: String
    let routes: [String]

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Station"
    static let defaultQuery = StationQuery()
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(routes.map(RouteSymbolsView.label).joined(separator: " "))")
    }

    init?(id: String) {
        guard let station = network?.stations[id] else { return nil }
        self.id = id
        name = station.name
        routes = station.routes
    }
}

/// Lists stations for the picker in Edit Widget, searchable by name or route.
struct StationQuery: EntityStringQuery {
    private var all: [StationEntity] {
        (network?.stations.keys.compactMap(StationEntity.init) ?? []).sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func entities(for identifiers: [String]) async throws -> [StationEntity] {
        identifiers.compactMap(StationEntity.init)
    }

    func entities(matching string: String) async throws -> [StationEntity] {
        all.filter { $0.name.localizedCaseInsensitiveContains(string) || $0.routes.contains(string.uppercased()) }
    }

    func suggestedEntities() async throws -> [StationEntity] {
        all
    }
}

struct StationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Station"
    static let description = IntentDescription("The station whose next trains the widget shows.")

    @Parameter(title: "Station")
    var station: StationEntity?

    /// 79 St on the 1 until one is chosen (the app's default home station).
    var stationID: String { station?.id ?? SubwaySettings.defaultHomeStations[0] }
}

// ---- Timeline ----

struct TrainsEntry: TimelineEntry {
    let date: Date
    let board: StationBoard?
    /// When the predictions were downloaded; nil when the download failed.
    let fetchedAt: Date?
}

struct TrainsProvider: AppIntentTimelineProvider {
    /// Which feed carries each route (the 1–7 and the 42 St shuttle are in "gtfs").
    private static func feed(for route: String) -> String {
        switch route {
        case "A", "C", "E", "H", "FS": return "gtfs-ace"
        case "B", "D", "F", "FX", "M": return "gtfs-bdfm"
        case "G": return "gtfs-g"
        case "J", "Z": return "gtfs-jz"
        case "N", "Q", "R", "W": return "gtfs-nqrw"
        case "L": return "gtfs-l"
        case "SI": return "gtfs-si"
        default: return "gtfs"
        }
    }

    /// Downloads only the feeds that serve the station; nil when every one fails.
    private func trips(at station: String) async -> [Trip]? {
        guard let network, let info = network.stations[station] else { return nil }
        let feeds = Set(info.routes.map(Self.feed))
        let results = await withTaskGroup(of: [Trip]?.self) { group in
            for feed in feeds {
                group.addTask {
                    let url = URL(string: network.settings.feedURL.replacingOccurrences(of: "{}", with: feed))!
                    guard let (data, _) = try? await URLSession.shared.data(from: url),
                          let message = try? TransitRealtime_FeedMessage(serializedBytes: data) else { return nil }
                    return FeedClient.trips(from: message, feed: feed)
                }
            }
            return await group.reduce(into: [[Trip]?]()) { $0.append($1) }
        }
        let found = results.compactMap { $0 }
        return found.isEmpty ? nil : found.flatMap { $0 }
    }

    private func board(_ station: String, trips: [Trip], at date: Date) -> StationBoard? {
        guard let network else { return nil }
        return StationBoard.make(station: station, trips: trips, network: network, now: date.timeIntervalSince1970,
                                 perDirection: 3)
    }

    func placeholder(in context: Context) -> TrainsEntry {
        TrainsEntry(date: Date(), board: nil, fetchedAt: nil)
    }

    func snapshot(for configuration: StationIntent, in context: Context) async -> TrainsEntry {
        let trips = await trips(at: configuration.stationID)
        return TrainsEntry(date: Date(), board: board(configuration.stationID, trips: trips ?? [], at: Date()),
                           fetchedAt: trips == nil ? nil : Date())
    }

    func timeline(for configuration: StationIntent, in context: Context) async -> Timeline<TrainsEntry> {
        let now = Date()
        let trips = await trips(at: configuration.stationID)
        // One entry a minute for 20 minutes from one download, so the minutes count down; ask again in 10.
        let entries = (0..<20).map { minute -> TrainsEntry in
            let date = now.addingTimeInterval(Double(minute) * 60)
            return TrainsEntry(date: date, board: board(configuration.stationID, trips: trips ?? [], at: date),
                               fetchedAt: trips == nil ? nil : now)
        }
        return Timeline(entries: entries, policy: .after(now.addingTimeInterval(10 * 60)))
    }
}

// ---- Views ----

/// A route symbol: a colored circle with the route's letter (a diamond for express variants is drawn as a circle).
struct RouteBullet: View {
    let route: String
    let size: CGFloat

    var body: some View {
        let colors = network?.routes[route]
        let label = RouteSymbolsView.label(for: route)
        Text(label)
            .font(.system(size: size * (label.count > 1 ? 0.42 : 0.66), weight: .bold))
            .foregroundStyle(Color(nsColor: NSColor(hex: colors?.textColor ?? "#FFFFFF")))
            .frame(width: size, height: size)
            .background(Circle().fill(Color(nsColor: NSColor(hex: colors?.color ?? "#808080"))))
    }
}

struct DirectionColumn: View {
    let label: String
    let arrivals: [Arrival]
    let rows: Int
    let bullet: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if arrivals.isEmpty {
                Text("None listed").font(.system(size: 12)).foregroundStyle(.tertiary)
            }
            ForEach(Array(arrivals.prefix(rows).enumerated()), id: \.offset) { _, arrival in
                HStack(spacing: 6) {
                    RouteBullet(route: arrival.route, size: bullet)
                    if arrival.minutes < 0.5 {
                        Text("now").font(.system(size: bullet * 0.85, weight: .semibold))
                    } else {
                        Text("\(Int(arrival.minutes.rounded()))").font(.system(size: bullet * 0.85, weight: .semibold))
                            + Text(" min").font(.system(size: bullet * 0.5)).foregroundColor(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TrainsWidgetView: View {
    let entry: TrainsEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let board = entry.board {
            let small = family == .systemSmall
            VStack(alignment: .leading, spacing: small ? 6 : 8) {
                HStack(spacing: 4) {
                    Text(board.name).font(.system(size: small ? 13 : 15, weight: .bold)).lineLimit(1).minimumScaleFactor(0.6)
                    Spacer(minLength: 0)
                    if entry.fetchedAt == nil {
                        Text("offline").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                HStack(alignment: .top, spacing: 10) {
                    DirectionColumn(label: board.northLabel, arrivals: board.north, rows: small ? 2 : 3, bullet: small ? 18 : 22)
                    DirectionColumn(label: board.southLabel, arrivals: board.south, rows: small ? 2 : 3, bullet: small ? 18 : 22)
                }
                Spacer(minLength: 0)
            }
        } else {
            Text("Next trains").foregroundStyle(.secondary)
        }
    }
}

@main
struct SubwayWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "SubwayNextTrains", intent: StationIntent.self, provider: TrainsProvider()) { entry in
            TrainsWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Next Trains")
        .description("The next trains each way at a station.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

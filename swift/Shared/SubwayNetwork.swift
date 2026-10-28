import CoreGraphics
import Foundation

/// The data the notebook exports to network.json (§8). Property names follow the JSON.
///
/// Everything is in map units (= points of map_black.pdf): x 0–1656 left→right, y 0–1978 bottom→top.
struct SubwayNetwork: Decodable {
    struct Meta: Decodable {
        let generatedAt: String
        let scheduleVersion: String?
        let feedEndDate: String?  // YYYYMMDD: after this, re-run the notebook and rebuild
        let mapSize: [Double]

        enum CodingKeys: String, CodingKey {
            case generatedAt = "generated_at", scheduleVersion = "schedule_version"
            case feedEndDate = "feed_end_date", mapSize = "map_size"
        }
    }

    /// The notebook's §1 settings, so Swift places trains exactly like the notebook.
    struct Settings: Decodable {
        let staleAfterS: Double  // a trip whose next predicted time is this old is a leftover
        let parkWindowS: Double  // show not-yet-departed trains only if they leave within this
        let defaultHopS: Double  // travel time between two stops when the schedule has none
        let trainDotUnits: Double  // train dot diameter in map units
        let feedURL: String  // with "{}" where the feed name goes
        let feeds: [String]

        enum CodingKeys: String, CodingKey {
            case staleAfterS = "stale_after_s", parkWindowS = "park_window_s", defaultHopS = "default_hop_s"
            case trainDotUnits = "train_dot_units", feedURL = "feed_url", feeds
        }
    }

    struct Route: Decodable {
        let color: String  // "#RRGGBB"
        let textColor: String
        let name: String

        enum CodingKeys: String, CodingKey {
            case color, textColor = "text_color", name
        }
    }

    struct Station: Decodable {
        let name: String
        let complex: String
        let routes: [String]
        let centre: [Double]  // [x, y]
        let extent: [Double]  // [xmin, ymin, xmax, ymax] of its circles
        let points: [String: [Double]]  // route → where that route's train is drawn here
        let northLabel: String  // MTA's label for trains toward the N platform, e.g. "Uptown", "Manhattan"
        let southLabel: String  // … and the S platform, e.g. "Downtown", "Coney Island"
        let borough: String?

        enum CodingKeys: String, CodingKey {
            case name, complex, routes, centre, extent, points
            case northLabel = "north_label", southLabel = "south_label", borough
        }
    }

    struct Pattern: Decodable {
        let route: String
        let stops: [String]  // platform IDs in travel order
        let trips: Int  // trips per day using this exact sequence
    }

    let meta: Meta
    let settings: Settings
    let routes: [String: Route]
    let platforms: [String: String]  // any stop ID (platform or station) → station ID
    let stations: [String: Station]
    let patterns: [Pattern]  // busiest first (the order matters for tie-breaks, as in the notebook)
    let hopTimes: [String: Double]  // "fromPlatform>toPlatform" → scheduled seconds
    let routeLines: [String: [[[Double]]]]  // line colour → polylines → points [x, y]
    /// "route|fromStation|toStation" → the track a train follows on that hop, computed by the notebook (§8) so
    /// both draw exactly the same path. Hops that can't follow the track are missing (use a straight line).
    let hopPaths: [String: [[Double]]]?
    let focusViews: [String: [String]]  // view name → station IDs

    enum CodingKeys: String, CodingKey {
        case meta, settings, routes, platforms, stations, patterns
        case hopTimes = "hop_times", routeLines = "route_lines", focusViews = "focus_views", hopPaths = "hop_paths"
    }

    /// Loads network.json from the app's or screensaver's bundled resources.
    static func loadBundled() throws -> SubwayNetwork {
        guard let url = SubwayView.resources.url(forResource: "network", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey:
                "network.json isn't bundled. Run the notebook's §8 export, then rebuild."])
        }
        return try JSONDecoder().decode(SubwayNetwork.self, from: Data(contentsOf: url))
    }
}

extension CGPoint {
    /// A point from a JSON [x, y] pair.
    init(_ pair: [Double]) {
        self.init(x: pair[0], y: pair[1])
    }
}

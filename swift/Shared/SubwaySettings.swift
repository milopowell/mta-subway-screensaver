import Foundation

/// User choices that persist between runs.
///
/// The preview app stores them in its normal preferences; the screensaver will use its own preferences
/// (ScreenSaverDefaults) and set them from its Options sheet (milestone 3), since a running screensaver
/// can't be clicked.
final class SubwaySettings {
    /// How the screen is arranged.
    enum Layout: String {
        /// The whole map, with a magnified map of the home stations and the next-train board beside it.
        case split
        /// One section of the map filling the screen at a readable zoom, centered on the home stations, with the
        /// next-train board and a small overview map as corner cards.
        case closeUp
    }

    /// Dark or light. The two automatic choices switch while running.
    enum Appearance: String, CaseIterable {
        case dark, light
        /// Follows the Mac's own appearance (System Settings > Appearance), including its Auto setting.
        case system
        /// Light from `dayStartHour` to `dayEndHour`, dark the rest of the time.
        case timeOfDay

        var title: String {
            switch self {
            case .dark: return "Dark"
            case .light: return "Light"
            case .system: return "Match the Mac"
            case .timeOfDay: return "Light by day (7 AM to 7 PM)"
            }
        }
    }
    static let dayStartHour = 7, dayEndHour = 19

    private let defaults: UserDefaults?
    /// Used instead of `defaults` by settings kept in memory only.
    private var inMemory: [String: Any] = [:]
    private static let homeStationsKey = "homeStations", layoutKey = "layout", magnificationKey = "magnification"
    /// Used until the user picks: 79 St (1) and 81 St-Museum of Natural History (B, C).
    static let defaultHomeStations = ["122", "A21"]
    /// Most home stations: the next-train board has room for four (two trains each way at each).
    static let maxHomeStations = 4
    /// Magnification choices, as multiples of the whole map fitted to the screen.
    static let magnifications: [Double] = [2, 3, 4, 6, 8]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Settings kept in memory only, for snapshots and tests: nothing is saved.
    init(homeStations: [String], layout: Layout = .split) {
        defaults = nil
        inMemory = [Self.homeStationsKey: homeStations, Self.layoutKey: layout.rawValue]
    }

    private func value(_ key: String) -> Any? {
        defaults?.object(forKey: key) ?? inMemory[key]
    }

    private func set(_ value: Any, _ key: String) {
        if let defaults {
            defaults.set(value, forKey: key)
            defaults.synchronize()  // the screensaver's preferences must be written before System Settings closes it
        } else {
            inMemory[key] = value
        }
    }

    /// GTFS station IDs, in the order they're shown in the next-train panel (at most `maxHomeStations`).
    var homeStations: [String] {
        get { Array((value(Self.homeStationsKey) as? [String] ?? Self.defaultHomeStations).prefix(Self.maxHomeStations)) }
        set { set(Array(newValue.prefix(Self.maxHomeStations)), Self.homeStationsKey) }
    }

    var layout: Layout {
        get { (value(Self.layoutKey) as? String).flatMap(Layout.init) ?? .split }
        set { set(newValue.rawValue, Self.layoutKey) }
    }

    var appearance: Appearance {
        get { (value("appearance") as? String).flatMap(Appearance.init) ?? .dark }
        set { set(newValue.rawValue, "appearance") }
    }

    /// How much the magnified map (split view) or the close-up is enlarged, as a multiple of the whole map fitted to
    /// the screen (so it means the same on any display); nil = automatic ("Fit stations": framed on the home stations).
    var magnification: Double? {
        get { (value(Self.magnificationKey) as? Double).flatMap { $0 > 0 ? $0 : nil } }
        set { set(newValue ?? 0, Self.magnificationKey) }
    }
}

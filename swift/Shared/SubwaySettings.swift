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
    /// Quiet hours: the picture dims from midnight until this hour.
    static let quietEndHour = 6

    /// What other displays show when there are several (the screensaver runs on each).
    enum OtherDisplays: String, CaseIterable {
        case same  // the same close-up as the main display
        case wholeMap  // the whole map, so between them you see the detail and the system

        var title: String { self == .same ? "The same view" : "The whole map" }
    }

    /// Features on trial: each can be switched on and off, to decide which to keep.
    enum Feature: String, CaseIterable {
        case alerts  // MTA service alerts for your stations' routes, in a card
        case nextTrainRing  // a ring around the dot of the next train arriving at your stations
        case drift  // the close-up drifts slowly in a small circle (shows a little more, protects the screen)
        case largeClock  // a large clock card
        case quietHours  // dims the picture from midnight to 6 AM

        var title: String {
            switch self {
            case .alerts: return "Service alerts"
            case .nextTrainRing: return "Ring around your next train"
            case .drift: return "Slow drift"
            case .largeClock: return "Large clock"
            case .quietHours: return "Quiet hours (dim midnight to 6 AM)"
            }
        }
    }

    private let defaults: UserDefaults?
    /// Used instead of `defaults` by settings kept in memory only.
    private var inMemory: [String: Any] = [:]
    /// When set, the settings live in this plist file instead: the screensaver's shared settings file (see
    /// `sharedFile`), which the preview app also uses while "Share Settings with Screensaver" is on.
    var file: URL?
    /// A layout used whatever is saved, and not saved (the screensaver always shows the close-up).
    var fixedLayout: Layout?
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

    /// The screensaver's settings file. macOS runs screensavers in a sandbox whose home folder is the container below,
    /// so the screensaver (`inside: true`) finds it in its own Application Support folder, and the preview app
    /// (`inside: false`) reaches the same file through the container's full path.
    static func sharedFile(inside: Bool) -> URL {
        let support = inside
            ? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            : URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Containers/com.apple.ScreenSaver.Engine.legacyScreenSaver/Data/Library/Application Support")
        return support.appendingPathComponent("MTA Subway/settings.plist")
    }

    /// Copies these settings (from `defaults`) into `file` if the file doesn't exist yet.
    func seedFile() {
        guard let file, let defaults, !FileManager.default.fileExists(atPath: file.path) else { return }
        let keys = defaults.dictionaryRepresentation().keys.filter {
            [Self.homeStationsKey, Self.magnificationKey, "appearance", "otherDisplays"].contains($0) || $0.hasPrefix("feature.")
        }
        writeFile(Dictionary(uniqueKeysWithValues: keys.map { ($0, defaults.object(forKey: $0)!) }))
    }

    private func readFile() -> [String: Any] {
        guard let file, let data = try? Data(contentsOf: file),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return [:] }
        return dict
    }

    private func writeFile(_ dict: [String: Any]) {
        guard let file, let data = try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        do { try data.write(to: file, options: .atomic) } catch { NSLog("SubwaySettings: couldn't save %@: %@", file.path, error.localizedDescription) }
    }

    private func value(_ key: String) -> Any? {
        if file != nil { return readFile()[key] }
        return defaults?.object(forKey: key) ?? inMemory[key]
    }

    private func set(_ value: Any, _ key: String) {
        if file != nil {
            var dict = readFile()
            dict[key] = value
            writeFile(dict)
        } else if let defaults {
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
        get { fixedLayout ?? (value(Self.layoutKey) as? String).flatMap(Layout.init) ?? .split }
        set { if fixedLayout == nil { set(newValue.rawValue, Self.layoutKey) } }
    }

    var appearance: Appearance {
        get { (value("appearance") as? String).flatMap(Appearance.init) ?? .dark }
        set { set(newValue.rawValue, "appearance") }
    }

    var otherDisplays: OtherDisplays {
        get { (value("otherDisplays") as? String).flatMap(OtherDisplays.init) ?? .same }
        set { set(newValue.rawValue, "otherDisplays") }
    }

    /// Whether a trial feature is on (all are off until switched on).
    func isOn(_ feature: Feature) -> Bool {
        value("feature." + feature.rawValue) as? Bool ?? false
    }

    func set(_ feature: Feature, on: Bool) {
        set(on, "feature." + feature.rawValue)
    }

    /// How much the magnified map (split view) or the close-up is enlarged, as a multiple of the whole map fitted to
    /// the screen (so it means the same on any display); nil = automatic ("Fit stations": framed on the home stations).
    var magnification: Double? {
        get { (value(Self.magnificationKey) as? Double).flatMap { $0 > 0 ? $0 : nil } }
        set { set(newValue ?? 0, Self.magnificationKey) }
    }
}

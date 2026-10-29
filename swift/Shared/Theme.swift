import AppKit

/// Dark or light: which map to show and the colors of everything drawn over it (train dots, the next-train board,
/// cards and notes). SubwayView picks one from the Appearance setting (SubwaySettings.Appearance).
struct Theme: Equatable {
    let isLight: Bool

    static let dark = Theme(isLight: false)
    static let light = Theme(isLight: true)

    /// The exported map for this theme (notebook §8): black, or the paper map's colors.
    var mapResource: String { isLight ? "map_light" : "map_black" }

    /// Behind the map, and outside it: black, or the light map's off-white land (mtamap/style.py LAND_LIGHT).
    var background: NSColor { isLight ? NSColor(red: 0.95, green: 0.95, blue: 0.93, alpha: 1) : .black }
    /// Main text (station names, minutes, the clock), secondary text (labels), and faint text ("None listed").
    var ink: NSColor { isLight ? NSColor(white: 0.08, alpha: 1) : .white }
    var secondaryInk: NSColor { isLight ? NSColor(white: 0.4, alpha: 1) : .gray }
    var faintInk: NSColor { isLight ? NSColor(white: 0.62, alpha: 1) : .darkGray }
    /// "min" beside the minutes.
    var unitInk: NSColor { isLight ? NSColor(white: 0.3, alpha: 1) : NSColor(white: 0.75, alpha: 1) }
    /// The thin border of a card floating over the map, and the dashed outline of the region another panel shows.
    var cardBorder: NSColor { isLight ? NSColor(white: 0, alpha: 0.2) : NSColor(white: 1, alpha: 0.25) }
    var outline: NSColor { isLight ? NSColor(white: 0, alpha: 0.6) : NSColor(white: 1, alpha: 0.7) }
    /// Small notes over the map (offline, time-lapse) and the status line.
    var noteInk: NSColor { isLight ? NSColor(white: 0.15, alpha: 1) : NSColor(white: 0.8, alpha: 1) }
    var noteBackground: NSColor { isLight ? NSColor(white: 1, alpha: 0.8) : NSColor(white: 0, alpha: 0.7) }

    /// Train dots: moving trains stand out most (white on the dark map, near-black on the light one).
    func train(_ look: TrainLook) -> NSColor {
        switch look {
        case .moving: return isLight ? NSColor(white: 0.08, alpha: 1) : .white
        case .stopped: return isLight ? NSColor(white: 0.42, alpha: 1) : NSColor(white: 0.62, alpha: 1)
        case .parked: return isLight ? NSColor(white: 0.66, alpha: 1) : NSColor(white: 0.38, alpha: 1)
        }
    }
    /// The dot's thin border, which separates it from the line under it.
    var trainBorder: NSColor { isLight ? NSColor(white: 1, alpha: 1) : .black }
    /// A moving dot's glow: white on the dark map; a soft shadow on the light one.
    var glowColor: NSColor { isLight ? .black : .white }
    var glowOpacity: Float { isLight ? 0.35 : 0.9 }
}

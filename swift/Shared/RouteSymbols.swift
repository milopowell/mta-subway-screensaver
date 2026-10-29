import AppKit

/// MTA route symbols (a colored circle with the route's letter or number; a diamond for express variants such as
/// 6X), drawn in a row. Used by the station picker; the next-train board draws the same symbols.
final class RouteSymbolsView: NSView {
    var routes: [String] = [] { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    /// route → (background color, letter color), from network.json.
    var colors: [String: (NSColor, NSColor)] = [:]
    var diameter: CGFloat = 16 { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    private let gap: CGFloat = 3

    /// The letter shown in a route's symbol: the shuttles all show "S", the Staten Island Railway "SIR".
    static func label(for route: String) -> String {
        ["GS": "S", "FS": "S", "H": "S", "SI": "SIR"][route] ?? String(route.prefix(1))
    }

    /// Draws one symbol centered on `center` (in a flipped or unflipped view alike).
    static func draw(_ route: String, center: CGPoint, diameter: CGFloat, colors: [String: (NSColor, NSColor)]) {
        let (fill, ink) = colors[route] ?? (.gray, .white)
        let r = diameter / 2
        let path: NSBezierPath
        if route.count == 2, route.hasSuffix("X") {  // 6X, 7X, FX: diamond
            path = NSBezierPath()
            path.move(to: CGPoint(x: center.x, y: center.y - r * 1.15))
            path.line(to: CGPoint(x: center.x + r * 1.15, y: center.y))
            path.line(to: CGPoint(x: center.x, y: center.y + r * 1.15))
            path.line(to: CGPoint(x: center.x - r * 1.15, y: center.y))
            path.close()
        } else {
            path = NSBezierPath(ovalIn: CGRect(x: center.x - r, y: center.y - r, width: diameter, height: diameter))
        }
        fill.setFill()
        path.fill()
        let label = Self.label(for: route)
        let font = NSFont.systemFont(ofSize: diameter * (label.count > 1 ? 0.42 : 0.68), weight: .bold)
        let text = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: ink])
        let size = text.size()
        text.draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2))
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: routes.isEmpty ? 0 : CGFloat(routes.count) * (diameter + gap) - gap, height: diameter + 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        for (i, route) in routes.enumerated() {
            let x = CGFloat(i) * (diameter + gap) + diameter / 2
            Self.draw(route, center: CGPoint(x: x, y: bounds.midY), diameter: diameter, colors: colors)
        }
    }
}

/// A clickable route symbol (for browsing stations by line). Shows a ring while selected, and a small dot below
/// when the line serves one of your stations.
final class RouteButton: NSButton {
    let route: String
    private let colors: [String: (NSColor, NSColor)]
    var isChosen = false { didSet { needsDisplay = true } }
    var servesYours = false { didSet { needsDisplay = true } }

    /// - Parameter name: the route's full name for the tooltip (e.g. "42 St Shuttle"), since some symbols look alike.
    init(route: String, name: String?, colors: [String: (NSColor, NSColor)], target: AnyObject, action: Selector) {
        self.route = route
        self.colors = colors
        super.init(frame: NSRect(x: 0, y: 0, width: 26, height: 30))
        self.target = target
        self.action = action
        isBordered = false
        title = ""
        toolTip = "\(RouteSymbolsView.label(for: route)): \(name ?? route)"
        widthAnchor.constraint(equalToConstant: 26).isActive = true
        heightAnchor.constraint(equalToConstant: 30).isActive = true  // room for the dot below
    }

    required init?(coder: NSCoder) {
        fatalError("created in code only")
    }

    override var isFlipped: Bool { true }  // the symbol at the top, the dot below

    override func draw(_ dirtyRect: NSRect) {
        let center = CGPoint(x: bounds.midX, y: 13)
        if isChosen {
            NSColor.controlAccentColor.setStroke()
            let ring = NSBezierPath(ovalIn: CGRect(x: center.x - 12, y: center.y - 12, width: 24, height: 24))
            ring.lineWidth = 2
            ring.stroke()
        }
        RouteSymbolsView.draw(route, center: center, diameter: 18, colors: colors)
        if servesYours {
            NSColor.controlAccentColor.setFill()
            NSBezierPath(ovalIn: CGRect(x: center.x - 2, y: 26, width: 4, height: 4)).fill()
        }
    }
}

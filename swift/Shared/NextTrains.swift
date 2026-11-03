import AppKit

/// One upcoming train at a station.
struct Arrival {
    let route: String
    let minutes: Double  // from now
}

/// The next trains at one station, split by direction, with the MTA's labels for each direction.
struct StationBoard {
    let station: String
    let name: String
    let northLabel: String, southLabel: String
    let north: [Arrival], south: [Arrival]
    /// Service alerts for this station's lines (ServiceAlert.text): about this station first, then about a whole line;
    /// at most `maxAlerts`, and how many more there are.
    var alerts: [String] = []
    var moreAlerts = 0
    static let maxAlerts = 2
    /// Routes with a train coming (what's running now), in a stable order.
    var routesNow: [String] { Array(Set((north + south).map(\.route))).sorted() }

    /// Builds the board from live trips: trains whose upcoming stops include this station's N or S platform.
    ///
    /// - Parameters:
    ///   - perDirection: how many trains to list each way.
    ///   - now: unix time "now".
    static func make(station: String, trips: [Trip], network: SubwayNetwork, now: Double,
                     perDirection: Int = 3, alerts: [ServiceAlert] = []) -> StationBoard? {
        guard let info = network.stations[station] else { return nil }
        func arrivals(platform: String) -> [Arrival] {
            var out: [Arrival] = []
            for trip in trips {
                // Skip leftover trips (same "stale" rule as the map) and trains already gone.
                guard let first = trip.upcoming.first, first.time >= now - network.settings.staleAfterS,
                      let stop = trip.upcoming.first(where: { $0.stop == platform }), stop.time >= now - 30
                else { continue }
                out.append(Arrival(route: trip.routeID, minutes: (stop.time - now) / 60))
            }
            return Array(out.sorted { $0.minutes < $1.minutes }.prefix(perDirection))
        }
        var board = StationBoard(station: station, name: info.name, northLabel: info.northLabel, southLabel: info.southLabel,
                                 north: arrivals(platform: station + "N"), south: arrivals(platform: station + "S"))
        let relevant = alerts.filter { $0.isRelevant(to: station, network: network, now: now) }
        let ordered = relevant.filter { !$0.stations.isEmpty } + relevant.filter { $0.stations.isEmpty }
        var texts: [String] = []
        for alert in ordered where !texts.contains(alert.text) { texts.append(alert.text) }  // the same notice, once
        board.alerts = Array(texts.prefix(maxAlerts))
        board.moreAlerts = max(texts.count - maxAlerts, 0)
        return board
    }
}

/// Draws the next-train boards, built to be read from across a room: for each home station its name and route
/// symbols, then two narrow columns (the MTA's direction labels, e.g. Uptown / Downtown) listing the next trains
/// as a large route symbol and the minutes until they arrive. The clock sits at the top right.
///
/// The board is sized to its content: `height(stations:perDirection:width:)` gives the height for a number of
/// stations and rows, so SubwayView can give it exactly that. Every station gets `perDirection` rows whether or
/// not that many trains are listed, so the height doesn't change from tick to tick.
final class NextTrainsView: NSView {
    var boards: [StationBoard] = [] { didSet { needsDisplay = true } }
    var theme: Theme = .dark { didSet { needsDisplay = true } }
    /// How opaque the board's own background is: 1 normally, less when it sits on glass (SubwayView.placeBoard).
    var backgroundAlpha: CGFloat = 1 { didSet { needsDisplay = true } }
    /// Draws a rounded patch of the theme's background behind each piece of text (the "NEXT TRAINS" heading, the clock,
    /// each station's name and route symbols, the direction labels, each train's symbol and minutes), so they stay
    /// readable on clear glass while the rest of the board stays see-through.
    var textBackdrops = false { didSet { needsDisplay = true } }
    /// The time shown at the top right of the board (set with each update).
    var time = Date() { didSet { needsDisplay = true } }
    private static let clockFormat: DateFormatter = {
        let format = DateFormatter()
        format.timeStyle = .short  // follows the Mac's 12- or 24-hour setting
        format.dateStyle = .none
        return format
    }()
    /// Trains listed each way at each station (set by SubwayView's layout).
    var perDirection = 2 { didSet { needsDisplay = true } }
    /// route → (background color, letter color), from network.json.
    var routeColors: [String: (NSColor, NSColor)] = [:]

    override var isFlipped: Bool { true }  // lay out top to bottom

    // ---- Sizes (all in units of the base font size, so the board scales with its width) ----
    private static let headerRows: CGFloat = 0.6 + 1.8  // top margin + "NEXT TRAINS" and the clock
    private static let nameRow: CGFloat = 2.0  // station name and route symbols
    private static let labelRow: CGFloat = 1.3  // "UPTOWN" / "DOWNTOWN"
    private static let trainRow: CGFloat = 2.1  // a large route symbol and the minutes
    private static let stationGap: CGFloat = 1.0
    private static let bottomMargin: CGFloat = 0.6
    private static let alertLine: CGFloat = 1.15  // one line of a service alert
    private static let alertGap: CGFloat = 0.35  // after a station's alerts
    private static let alertSize: CGFloat = 0.8  // their text, in units
    private static let alertIndent: CGFloat = 1.3  // room for the warning sign

    /// Base font size for a board of this width.
    static func unit(forWidth width: CGFloat) -> CGFloat {
        min(max(width / 20, 11), 18)
    }

    /// The height the board needs for `stations` stations with `perDirection` rows each way, plus `alertLines` lines of
    /// service alerts over `alertStations` stations (`alertLines(_:width:)`).
    static func height(stations: Int, perDirection: Int, width: CGFloat, alertLines: Int = 0, alertStations: Int = 0) -> CGFloat {
        let unit = unit(forWidth: width)
        guard stations > 0 else { return (headerRows + trainRow + bottomMargin) * unit }
        let station = nameRow + labelRow + CGFloat(perDirection) * trainRow
        let alerts = CGFloat(alertLines) * alertLine + CGFloat(alertStations) * alertGap
        return (headerRows + CGFloat(stations) * station + CGFloat(stations - 1) * stationGap + alerts + bottomMargin) * unit
    }

    /// How many lines the boards' service alerts take at this width (each alert wraps to at most two lines; "+N more"
    /// takes one), and over how many stations.
    func alertLines(width: CGFloat) -> (lines: Int, stations: Int) {
        let unit = NextTrainsView.unit(forWidth: width)
        var lines = 0, stations = 0
        for board in boards where !board.alerts.isEmpty {
            stations += 1
            lines += board.alerts.reduce(0) { $0 + alertLineCount($1, unit: unit, width: width) } + (board.moreAlerts > 0 ? 1 : 0)
        }
        return (lines, stations)
    }

    override func draw(_ dirtyRect: NSRect) {
        if backgroundAlpha > 0 {
            theme.background.withAlphaComponent(backgroundAlpha).setFill()
            bounds.fill(using: .sourceOver)  // over what's underneath, so a see-through board stays see-through
        }
        let unit = NextTrainsView.unit(forWidth: bounds.width)
        let pad = unit
        var y = pad * 0.6

        backdrop(CGRect(x: pad, y: y + unit * 0.45, width: measure("NEXT TRAINS", size: unit * 0.75, weight: .semibold),
                        height: unit * 0.75), unit: unit)
        text("NEXT TRAINS", at: CGPoint(x: pad, y: y + unit * 0.35), size: unit * 0.75, color: theme.secondaryInk, weight: .semibold)
        // The clock, right-aligned on the same line; digits of equal width so it doesn't shift as it changes.
        let clock = NSAttributedString(string: Self.clockFormat.string(from: time), attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: unit * 1.3, weight: .semibold), .foregroundColor: theme.ink,
        ])
        let clockX = bounds.width - pad - clock.size().width
        backdrop(CGRect(x: clockX, y: y - unit * 0.1, width: clock.size().width, height: unit * 1.55), unit: unit)
        clock.draw(at: CGPoint(x: clockX, y: y - unit * 0.1))
        y += unit * 1.8
        if boards.isEmpty {
            text("Choose stations with the tram button.", at: CGPoint(x: pad, y: y), size: unit * 0.9, color: theme.secondaryInk,
                 maxWidth: bounds.width - 2 * pad)
            return
        }
        let columnWidth = (bounds.width - 3 * pad) / 2
        for board in boards {
            guard y < bounds.height - unit * 2 else { break }  // out of room
            // Station name, then a symbol for each route with a train coming.
            let symbols = board.routesNow
            let symbolsWidth = CGFloat(symbols.count) * unit * 1.5
            // A long name shrinks to fit beside its symbols (down to half the usual size, then it is cut short),
            // and stays vertically centered on the row.
            let room = bounds.width - 2 * pad - symbolsWidth - unit * 0.4
            let full = unit * 1.3
            // (The system font spaces small text a little more loosely, so measure again at each size.)
            var nameSize = full
            while nameSize > full * 0.5, measure(board.name, size: nameSize, weight: .bold) > room * 0.98 {
                nameSize *= 0.96
            }
            nameSize = max(nameSize, full * 0.5)
            let nameWidth = min(measure(board.name, size: nameSize, weight: .bold), room)
            backdrop(CGRect(x: pad, y: y + unit * 0.25, width: nameWidth + unit * 0.5 + CGFloat(symbols.count) * unit * 1.5 - unit * 0.2,
                            height: unit * 1.3), unit: unit)
            var x = pad + text(board.name, at: CGPoint(x: pad, y: y + (full - nameSize) * 0.6), size: nameSize, weight: .bold,
                               maxWidth: room) + unit * 0.5
            for route in symbols {
                x += bullet(route, center: CGPoint(x: x + unit * 0.65, y: y + unit * 0.9), diameter: unit * 1.3) + unit * 0.2
            }
            y += unit * NextTrainsView.nameRow
            // Service alerts for this station's lines, under its name.
            if !board.alerts.isEmpty {
                for alert in board.alerts {
                    y += drawAlert(alert, at: y, unit: unit, pad: pad)
                }
                if board.moreAlerts > 0 {
                    let more = "+\(board.moreAlerts) more alert\(board.moreAlerts == 1 ? "" : "s")"
                    text(more, at: CGPoint(x: pad + unit * NextTrainsView.alertIndent, y: y),
                         size: unit * NextTrainsView.alertSize, color: theme.secondaryInk)
                    y += unit * NextTrainsView.alertLine
                }
                y += unit * NextTrainsView.alertGap
            }
            // Two columns: north-bound and south-bound, each with exactly `perDirection` rows.
            for (column, (label, arrivals)) in [(board.northLabel, board.north), (board.southLabel, board.south)].enumerated() {
                let left = pad + CGFloat(column) * (columnWidth + pad)
                var rowY = y
                let labelWidth = min(measure(label.uppercased(), size: unit * 0.75, weight: .semibold), columnWidth)
                backdrop(CGRect(x: left, y: rowY + unit * 0.1, width: labelWidth, height: unit * 0.75), unit: unit)
                text(label.uppercased(), at: CGPoint(x: left, y: rowY), size: unit * 0.75, color: theme.secondaryInk, weight: .semibold,
                     maxWidth: columnWidth)
                rowY += unit * NextTrainsView.labelRow
                if arrivals.isEmpty {
                    text("None listed", at: CGPoint(x: left, y: rowY + unit * 0.4), size: unit * 0.9, color: theme.faintInk)
                }
                for arrival in arrivals.prefix(perDirection) {
                    let diameter = unit * 1.6
                    let number = "\(Int(arrival.minutes.rounded()))"
                    let words = arrival.minutes < 0.5 ? measure("now", size: unit * 1.45, weight: .semibold)
                        : measure(number, size: unit * 1.45, weight: .semibold) + unit * 0.25
                            + measure("min", size: unit * 0.85, weight: .regular)
                    backdrop(CGRect(x: left, y: rowY + unit * 0.15, width: diameter + unit * 0.5 + words, height: diameter), unit: unit)
                    bullet(arrival.route, center: CGPoint(x: left + diameter / 2, y: rowY + unit * 0.95), diameter: diameter)
                    // The number large, "min" smaller beside it; "now" for a train arriving now.
                    let textX = left + diameter + unit * 0.5
                    if arrival.minutes < 0.5 {
                        text("now", at: CGPoint(x: textX, y: rowY + unit * 0.05), size: unit * 1.45, weight: .semibold)
                    } else {
                        let w = text(number, at: CGPoint(x: textX, y: rowY + unit * 0.05), size: unit * 1.45, weight: .semibold)
                        text("min", at: CGPoint(x: textX + w + unit * 0.25, y: rowY + unit * 0.55), size: unit * 0.85,
                             color: theme.unitInk)
                    }
                    rowY += unit * NextTrainsView.trainRow
                }
            }
            y += unit * (NextTrainsView.labelRow + CGFloat(perDirection) * NextTrainsView.trainRow + NextTrainsView.stationGap)
        }
    }

    // ---- Service alerts ----

    /// An alert's text with its route tokens drawn as small route symbols, like the MTA's own notices.
    private func alertText(_ alert: String, unit: CGFloat) -> NSAttributedString {
        let size = unit * NextTrainsView.alertSize
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        style.minimumLineHeight = unit * NextTrainsView.alertLine
        style.maximumLineHeight = unit * NextTrainsView.alertLine
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size), .foregroundColor: theme.ink, .paragraphStyle: style,
        ]
        let out = NSMutableAttributedString()
        var rest = Substring(alert)
        while let open = rest.firstIndex(of: "["), let close = rest[open...].firstIndex(of: "]") {
            out.append(NSAttributedString(string: String(rest[..<open]), attributes: attributes))
            let token = String(rest[rest.index(after: open)..<close])
            if let route = ServiceAlert.route(forToken: token) {
                let diameter = size * 1.15
                let colors = routeColors
                let image = NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
                    RouteSymbolsView.draw(route, center: CGPoint(x: rect.midX, y: rect.midY), diameter: diameter * 0.92,
                                          colors: colors)
                    return true
                }
                let attachment = NSTextAttachment()
                attachment.image = image
                attachment.bounds = CGRect(x: 0, y: -size * 0.22, width: diameter, height: diameter)
                let symbol = NSMutableAttributedString(attachment: attachment)
                symbol.addAttributes(attributes, range: NSRange(location: 0, length: symbol.length))
                out.append(symbol)
            } else {  // an icon token, as words: "[shuttle bus icon]" → "shuttle bus"
                let words = token.replacingOccurrences(of: " icon", with: "")
                out.append(NSAttributedString(string: words, attributes: attributes))
            }
            rest = rest[rest.index(after: close)...]
        }
        out.append(NSAttributedString(string: String(rest), attributes: attributes))
        return out
    }

    /// Lines an alert takes at this width: as many as it wraps to, up to two (longer ones end in "…").
    private func alertLineCount(_ alert: String, unit: CGFloat, width: CGFloat) -> Int {
        let available = width - 2 * unit - unit * NextTrainsView.alertIndent
        let height = alertText(alert, unit: unit).boundingRect(with: CGSize(width: available, height: .greatestFiniteMagnitude),
                                                               options: [.usesLineFragmentOrigin]).height
        return min(max(Int((height / (unit * NextTrainsView.alertLine)).rounded(.up)), 1), 2)
    }

    /// Draws one alert under a station's name: a small warning sign, then the text (at most two lines). Returns the
    /// height it took.
    private func drawAlert(_ alert: String, at y: CGFloat, unit: CGFloat, pad: CGFloat) -> CGFloat {
        let lines = alertLineCount(alert, unit: unit, width: bounds.width)
        let height = CGFloat(lines) * unit * NextTrainsView.alertLine
        let left = pad + unit * NextTrainsView.alertIndent
        let available = bounds.width - pad - left
        backdrop(CGRect(x: pad, y: y + unit * 0.1, width: bounds.width - 2 * pad, height: height - unit * 0.2), unit: unit)
        // The warning sign: a yellow triangle with a dark "!", like the MTA's.
        let s = unit * 0.95, top = y + unit * 0.12
        let triangle = NSBezierPath()
        triangle.move(to: CGPoint(x: pad + s / 2, y: top))
        triangle.line(to: CGPoint(x: pad + s, y: top + s * 0.88))
        triangle.line(to: CGPoint(x: pad, y: top + s * 0.88))
        triangle.close()
        NSColor(srgbRed: 0.99, green: 0.80, blue: 0.10, alpha: 1).setFill()
        triangle.fill()
        let mark = NSAttributedString(string: "!", attributes: [
            .font: NSFont.systemFont(ofSize: s * 0.62, weight: .heavy), .foregroundColor: NSColor(white: 0.1, alpha: 1)])
        mark.draw(at: CGPoint(x: pad + s / 2 - mark.size().width / 2, y: top + s * 0.2))
        alertText(alert, unit: unit).draw(with: CGRect(x: left, y: y, width: available, height: height),
                                          options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        return height
    }

    // ---- Drawing helpers ----

    /// Draws text with its top-left at `point`; returns its width. `maxWidth` truncates with "…".
    @discardableResult
    private func text(_ string: String, at point: CGPoint, size: CGFloat, color: NSColor? = nil,
                      weight: NSFont.Weight = .regular, maxWidth: CGFloat? = nil) -> CGFloat {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color ?? theme.ink, .paragraphStyle: style,
        ]
        let attributed = NSAttributedString(string: string, attributes: attributes)
        let width = min(attributed.size().width, maxWidth ?? .greatestFiniteMagnitude)
        attributed.draw(with: CGRect(x: point.x, y: point.y, width: width, height: size * 1.4),
                        options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        return width
    }

    /// A rounded patch of the theme's background around `content` (when `textBackdrops` is on).
    private func backdrop(_ content: CGRect, unit: CGFloat) {
        guard textBackdrops else { return }
        // Padding small enough that neighboring patches (a station name and the direction labels under it, two train
        // rows) keep a visible gap between them.
        let rect = content.insetBy(dx: -unit * 0.35, dy: -unit * 0.15)
        theme.background.withAlphaComponent(theme.isLight ? 0.75 : 0.65).setFill()
        NSBezierPath(roundedRect: rect, xRadius: min(unit * 0.55, rect.height / 2), yRadius: min(unit * 0.55, rect.height / 2)).fill()
    }

    private func measure(_ string: String, size: CGFloat, weight: NSFont.Weight) -> CGFloat {
        NSAttributedString(string: string, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)]).size().width
    }

    /// Draws a route symbol (a circle, or a diamond for express variants like 6X) and returns its width.
    @discardableResult
    private func bullet(_ route: String, center: CGPoint, diameter: CGFloat) -> CGFloat {
        let (fill, ink) = routeColors[route] ?? (.gray, .white)
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
        let label = RouteSymbolsView.label(for: route)
        let size = diameter * (label.count > 1 ? 0.42 : 0.68)
        let width = measure(label, size: size, weight: .bold)
        text(label, at: CGPoint(x: center.x - width / 2, y: center.y - size * 0.62), size: size, color: ink, weight: .bold)
        return diameter
    }
}

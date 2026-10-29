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
    /// Routes with a train coming (what's running now), in a stable order.
    var routesNow: [String] { Array(Set((north + south).map(\.route))).sorted() }

    /// Builds the board from live trips: trains whose upcoming stops include this station's N or S platform.
    ///
    /// - Parameters:
    ///   - perDirection: how many trains to list each way.
    ///   - now: unix time "now".
    static func make(station: String, trips: [Trip], network: SubwayNetwork, now: Double,
                     perDirection: Int = 3) -> StationBoard? {
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
        return StationBoard(station: station, name: info.name, northLabel: info.northLabel, southLabel: info.southLabel,
                            north: arrivals(platform: station + "N"), south: arrivals(platform: station + "S"))
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

    /// Base font size for a board of this width.
    static func unit(forWidth width: CGFloat) -> CGFloat {
        min(max(width / 20, 11), 18)
    }

    /// The height the board needs for `stations` stations with `perDirection` rows each way.
    static func height(stations: Int, perDirection: Int, width: CGFloat) -> CGFloat {
        let unit = unit(forWidth: width)
        guard stations > 0 else { return (headerRows + trainRow + bottomMargin) * unit }
        let station = nameRow + labelRow + CGFloat(perDirection) * trainRow
        return (headerRows + CGFloat(stations) * station + CGFloat(stations - 1) * stationGap + bottomMargin) * unit
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        let unit = NextTrainsView.unit(forWidth: bounds.width)
        let pad = unit
        var y = pad * 0.6

        text("NEXT TRAINS", at: CGPoint(x: pad, y: y + unit * 0.35), size: unit * 0.75, color: .gray, weight: .semibold)
        // The clock, right-aligned on the same line; digits of equal width so it doesn't shift as it changes.
        let clock = NSAttributedString(string: Self.clockFormat.string(from: time), attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: unit * 1.3, weight: .semibold), .foregroundColor: NSColor.white,
        ])
        clock.draw(at: CGPoint(x: bounds.width - pad - clock.size().width, y: y - unit * 0.1))
        y += unit * 1.8
        if boards.isEmpty {
            text("Choose stations with the tram button.", at: CGPoint(x: pad, y: y), size: unit * 0.9, color: .gray,
                 maxWidth: bounds.width - 2 * pad)
            return
        }
        let columnWidth = (bounds.width - 3 * pad) / 2
        for board in boards {
            guard y < bounds.height - unit * 2 else { break }  // out of room
            // Station name, then a symbol for each route with a train coming.
            let symbols = board.routesNow
            let symbolsWidth = CGFloat(symbols.count) * unit * 1.5
            var x = pad + text(board.name, at: CGPoint(x: pad, y: y), size: unit * 1.3, weight: .bold,
                               maxWidth: bounds.width - 2 * pad - symbolsWidth - unit * 0.4) + unit * 0.5
            for route in symbols {
                x += bullet(route, center: CGPoint(x: x + unit * 0.65, y: y + unit * 0.9), diameter: unit * 1.3) + unit * 0.2
            }
            y += unit * NextTrainsView.nameRow
            // Two columns: north-bound and south-bound, each with exactly `perDirection` rows.
            for (column, (label, arrivals)) in [(board.northLabel, board.north), (board.southLabel, board.south)].enumerated() {
                let left = pad + CGFloat(column) * (columnWidth + pad)
                var rowY = y
                text(label.uppercased(), at: CGPoint(x: left, y: rowY), size: unit * 0.75, color: .gray, weight: .semibold,
                     maxWidth: columnWidth)
                rowY += unit * NextTrainsView.labelRow
                if arrivals.isEmpty {
                    text("None listed", at: CGPoint(x: left, y: rowY + unit * 0.4), size: unit * 0.9, color: .darkGray)
                }
                for arrival in arrivals.prefix(perDirection) {
                    let diameter = unit * 1.6
                    bullet(arrival.route, center: CGPoint(x: left + diameter / 2, y: rowY + unit * 0.95), diameter: diameter)
                    // The number large, "min" smaller beside it; "now" for a train arriving now.
                    let textX = left + diameter + unit * 0.5
                    if arrival.minutes < 0.5 {
                        text("now", at: CGPoint(x: textX, y: rowY + unit * 0.05), size: unit * 1.45, weight: .semibold)
                    } else {
                        let number = "\(Int(arrival.minutes.rounded()))"
                        let w = text(number, at: CGPoint(x: textX, y: rowY + unit * 0.05), size: unit * 1.45, weight: .semibold)
                        text("min", at: CGPoint(x: textX + w + unit * 0.25, y: rowY + unit * 0.55), size: unit * 0.85,
                             color: NSColor(white: 0.75, alpha: 1))
                    }
                    rowY += unit * NextTrainsView.trainRow
                }
            }
            y += unit * (NextTrainsView.labelRow + CGFloat(perDirection) * NextTrainsView.trainRow + NextTrainsView.stationGap)
        }
    }

    // ---- Drawing helpers ----

    /// Draws text with its top-left at `point`; returns its width. `maxWidth` truncates with "…".
    @discardableResult
    private func text(_ string: String, at point: CGPoint, size: CGFloat, color: NSColor = .white,
                      weight: NSFont.Weight = .regular, maxWidth: CGFloat? = nil) -> CGFloat {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: style,
        ]
        let attributed = NSAttributedString(string: string, attributes: attributes)
        let width = min(attributed.size().width, maxWidth ?? .greatestFiniteMagnitude)
        attributed.draw(with: CGRect(x: point.x, y: point.y, width: width, height: size * 1.4),
                        options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        return width
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

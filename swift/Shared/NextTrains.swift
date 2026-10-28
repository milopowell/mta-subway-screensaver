import AppKit

/// One upcoming train at a station.
struct Arrival {
    let route: String
    let destination: String  // the station where this trip ends
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
                let last = trip.upcoming.last.flatMap { network.platforms[$0.stop] }
                let destination = last.flatMap { network.stations[$0]?.name } ?? "—"
                out.append(Arrival(route: trip.routeID, destination: destination, minutes: (stop.time - now) / 60))
            }
            return Array(out.sorted { $0.minutes < $1.minutes }.prefix(perDirection))
        }
        return StationBoard(station: station, name: info.name, northLabel: info.northLabel, southLabel: info.southLabel,
                            north: arrivals(platform: station + "N"), south: arrivals(platform: station + "S"))
    }
}

/// Draws the next-train boards: for each home station, its name and route symbols, then two columns
/// (the MTA's direction labels) of upcoming trains with destination and minutes.
///
/// The board is sized to its content: `height(stations:perDirection:width:)` gives the height for a number of
/// stations and rows, so SubwayView can give it exactly that and hand the rest of the column to the map.
/// Every station gets `perDirection` rows whether or not that many trains are listed, so the height doesn't
/// change from tick to tick.
final class NextTrainsView: NSView {
    var boards: [StationBoard] = [] { didSet { needsDisplay = true } }
    /// Trains listed each way at each station (set by SubwayView's layout).
    var perDirection = 2 { didSet { needsDisplay = true } }
    /// route → (background colour, letter colour), from network.json.
    var routeColors: [String: (NSColor, NSColor)] = [:]

    override var isFlipped: Bool { true }  // lay out top to bottom

    // ---- Sizes (all in units of the base font size, so the board scales with the column) ----
    private static let headerRows: CGFloat = 0.6 + 1.4  // top margin + "NEXT TRAINS"
    private static let nameRow: CGFloat = 1.7  // station name and route symbols
    private static let labelRow: CGFloat = 1.2  // "UPTOWN" / "DOWNTOWN"
    private static let trainRow: CGFloat = 1.35
    private static let stationGap: CGFloat = 0.9
    private static let bottomMargin: CGFloat = 0.6

    /// Base font size for a board of this width: smaller than body text on a wide column, never tiny.
    static func unit(forWidth width: CGFloat) -> CGFloat {
        min(max(width / 44, 9), 13)
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

        text("NEXT TRAINS", at: CGPoint(x: pad, y: y), size: unit * 0.75, color: .gray, weight: .semibold)
        y += unit * 1.4
        if boards.isEmpty {
            text("Choose home stations with the tram button.", at: CGPoint(x: pad, y: y), size: unit * 0.9, color: .gray)
            return
        }
        let columnWidth = (bounds.width - 3 * pad) / 2
        for board in boards {
            guard y < bounds.height - unit * 2 else { break }  // out of room
            // Station name, then a symbol for each route with a train coming.
            var x = pad + text(board.name, at: CGPoint(x: pad, y: y), size: unit * 1.15, weight: .bold) + unit * 0.5
            for route in board.routesNow {
                x += bullet(route, center: CGPoint(x: x + unit * 0.6, y: y + unit * 0.7), diameter: unit * 1.15)
                    + unit * 0.25
            }
            y += unit * NextTrainsView.nameRow
            // Two columns: north-bound and south-bound, each with exactly `perDirection` rows.
            for (column, (label, arrivals)) in [(board.northLabel, board.north), (board.southLabel, board.south)].enumerated() {
                let left = pad + CGFloat(column) * (columnWidth + pad)
                var rowY = y
                text(label.uppercased(), at: CGPoint(x: left, y: rowY), size: unit * 0.7, color: .gray, weight: .semibold)
                rowY += unit * NextTrainsView.labelRow
                if arrivals.isEmpty {
                    text("No trains listed", at: CGPoint(x: left, y: rowY), size: unit * 0.85, color: .darkGray)
                }
                for arrival in arrivals.prefix(perDirection) {
                    bullet(arrival.route, center: CGPoint(x: left + unit * 0.55, y: rowY + unit * 0.6), diameter: unit)
                    let minutes = arrival.minutes < 0.5 ? "now" : "\(Int(arrival.minutes.rounded())) min"
                    let minutesWidth = measure(minutes, size: unit * 0.95, weight: .semibold)
                    text(minutes, at: CGPoint(x: left + columnWidth - minutesWidth, y: rowY), size: unit * 0.95,
                         weight: .semibold)
                    text(arrival.destination, at: CGPoint(x: left + unit * 1.5, y: rowY), size: unit * 0.9,
                         color: NSColor(white: 0.85, alpha: 1), maxWidth: columnWidth - unit * 1.6 - minutesWidth - unit * 0.4)
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

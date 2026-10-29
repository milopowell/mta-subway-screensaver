import AppKit
import SwiftProtobuf

/// One MTA service alert in effect now: "[L] trains are running with delays in both directions…".
struct ServiceAlert {
    let routes: [String]  // route IDs it concerns
    let header: String  // English headline; routes appear as tags like "[L]"
    let start: Double  // when it took effect (unix time): newer alerts are usually the unplanned ones
}

/// Downloads the MTA's subway alerts feed (GTFS-Realtime, no API key needed), keeping the alerts in effect now.
enum ServiceAlerts {
    static let url = URL(string: "https://api-endpoint.mta.info/Dataservice/mtagtfsfeeds/camsys%2Fsubway-alerts")!

    /// The alerts in effect now, newest first; nil when the download fails.
    static func fetch(now: Double = Date().timeIntervalSince1970) async -> [ServiceAlert]? {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        guard let (data, response) = try? await URLSession(configuration: config).data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let message = try? TransitRealtime_FeedMessage(serializedBytes: data) else { return nil }
        var alerts: [ServiceAlert] = []
        for entity in message.entity where entity.hasAlert {
            let alert = entity.alert
            let periods = alert.activePeriod
            let active = periods.isEmpty || periods.contains { Double($0.start) <= now && ($0.end == 0 || now <= Double($0.end)) }
            guard active, let header = alert.headerText.translation.first(where: { $0.language == "en" })?.text else { continue }
            let routes = Array(Set(alert.informedEntity.map(\.routeID).filter { !$0.isEmpty })).sorted()
            alerts.append(ServiceAlert(routes: routes, header: header, start: Double(periods.map(\.start).min() ?? 0)))
        }
        return alerts.sorted { $0.start > $1.start }
    }
}

/// A card listing service alerts (at most `maxAlerts`, two lines each), with the route tags in the text drawn as
/// route symbols.
final class AlertsView: NSView {
    var alerts: [ServiceAlert] = [] { didSet { needsDisplay = true } }
    var theme: Theme = .dark { didSet { needsDisplay = true } }
    /// route → (background color, letter color), from network.json.
    var routeColors: [String: (NSColor, NSColor)] = [:]
    var maxAlerts = 3

    override var isFlipped: Bool { true }

    private func unit(_ width: CGFloat) -> CGFloat { NextTrainsView.unit(forWidth: width) * 0.8 }

    /// The height the card needs at this width (0 when there's nothing to show).
    func height(forWidth width: CGFloat) -> CGFloat {
        guard !alerts.isEmpty else { return 0 }
        let unit = unit(width)
        return (unit * 2.6 + CGFloat(min(alerts.count, maxAlerts)) * lineHeight(unit) * 2 + CGFloat(min(alerts.count, maxAlerts) - 1) * unit * 0.6
                + unit * 0.8).rounded(.up)
    }

    private func lineHeight(_ unit: CGFloat) -> CGFloat { unit * 1.35 }

    override func draw(_ dirtyRect: NSRect) {
        theme.background.setFill()
        bounds.fill()
        let unit = unit(bounds.width), pad = unit
        let title = NSAttributedString(string: "SERVICE ALERTS", attributes: [
            .font: NSFont.systemFont(ofSize: unit * 0.9, weight: .semibold), .foregroundColor: theme.secondaryInk,
        ])
        title.draw(at: CGPoint(x: pad, y: unit * 0.7))
        var y = unit * 2.6
        for alert in alerts.prefix(maxAlerts) {
            let text = attributed(alert.header, size: unit)
            let rect = CGRect(x: pad, y: y, width: bounds.width - 2 * pad, height: lineHeight(unit) * 2)
            text.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            y += lineHeight(unit) * 2 + unit * 0.6
        }
    }

    /// The headline with each "[L]" tag replaced by the route's symbol.
    private func attributed(_ header: String, size: CGFloat) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        style.minimumLineHeight = lineHeight(size)
        style.maximumLineHeight = lineHeight(size)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size), .foregroundColor: theme.ink, .paragraphStyle: style,
        ]
        let result = NSMutableAttributedString()
        var rest = Substring(header.replacingOccurrences(of: "\n", with: " "))
        while let open = rest.firstIndex(of: "["), let close = rest[open...].firstIndex(of: "]") {
            result.append(NSAttributedString(string: String(rest[..<open]), attributes: attributes))
            let tag = String(rest[rest.index(after: open)..<close])
            let route = ["SIR": "SI", "S": "GS"][tag] ?? tag
            if routeColors[route] != nil {
                let d = size * 1.15
                let image = NSImage(size: NSSize(width: d, height: d), flipped: false) { [routeColors] rect in
                    RouteSymbolsView.draw(route, center: CGPoint(x: rect.midX, y: rect.midY), diameter: d * 0.95, colors: routeColors)
                    return true
                }
                let attachment = NSTextAttachment()
                attachment.image = image
                attachment.bounds = CGRect(x: 0, y: -size * 0.22, width: d, height: d)
                let symbol = NSMutableAttributedString(attachment: attachment)
                symbol.addAttributes(attributes, range: NSRange(location: 0, length: symbol.length))
                result.append(symbol)
            } else {
                result.append(NSAttributedString(string: "[\(tag)]", attributes: attributes))
            }
            rest = rest[rest.index(after: close)...]
        }
        result.append(NSAttributedString(string: String(rest), attributes: attributes))
        return result
    }
}

import Foundation

/// One alert from the MTA's subway alerts feed: delays, suspensions, reroutes, skipped stops, station notices. The
/// next-train board lists those that affect a home station (`isRelevant(to:network:now:)`).
struct ServiceAlert {
    /// The routes it's about.
    let routes: Set<String>
    /// The stops it names, as the feed gives them (stations like "127", or platforms like "127N"); empty for one about a
    /// whole line.
    let stations: Set<String>
    /// When it applies (unix times); empty = now and until further notice.
    let periods: [(start: Double, end: Double)]
    /// Its main message: the first paragraph of the MTA's text, with route names as tokens ("Downtown [1] skips 125 St").
    let text: String

    func isActive(at now: Double) -> Bool {
        periods.isEmpty || periods.contains { $0.start <= now && now <= $0.end }
    }

    /// Whether the board should list it for `station`: active, about one of the station's routes, and either about the
    /// whole line or naming this station (or another part of its complex: Times Sq-42 St for the 7 at Times Sq).
    func isRelevant(to station: String, network: SubwayNetwork, now: Double) -> Bool {
        guard isActive(at: now), let info = network.stations[station], !routes.isDisjoint(with: info.routes) else {
            return false
        }
        // A platform stands for its station (network.platforms), and any station of the complex counts.
        return stations.isEmpty || stations.contains { network.stations[network.platforms[$0] ?? $0]?.complex == info.complex }
    }

    /// The alerts in one download of the feed.
    static func alerts(from message: TransitRealtime_FeedMessage) -> [ServiceAlert] {
        message.entity.compactMap { entity -> ServiceAlert? in
            guard entity.hasAlert else { return nil }
            let alert = entity.alert
            let header = alert.headerText.translation
            let html = header.first { $0.language == "en-html" }?.text
            let plain = header.first { $0.language == "en" }?.text ?? header.first?.text ?? ""
            let text = html.map(firstParagraph) ?? plain
            guard !text.isEmpty else { return nil }
            var routes = Set<String>(), stations = Set<String>()
            for entity in alert.informedEntity {
                if !entity.routeID.isEmpty { routes.insert(entity.routeID) }
                if !entity.stopID.isEmpty { stations.insert(entity.stopID) }
            }
            guard !routes.isEmpty else { return nil }
            let periods = alert.activePeriod.map {
                (start: $0.hasStart ? Double($0.start) : 0, end: $0.hasEnd ? Double($0.end) : .greatestFiniteMagnitude)
            }
            return ServiceAlert(routes: routes, stations: stations, periods: periods, text: text)
        }
    }

    /// The first paragraph of the MTA's HTML text, as plain text: "<p>Downtown [1] skips <strong>125 St</strong></p>
    /// <p>…</p>" → "Downtown [1] skips 125 St". (The plain-text version runs the paragraphs together without stops.)
    static func firstParagraph(_ html: String) -> String {
        var text = html
        if let end = text.range(of: "</p>") { text = String(text[..<end.lowerBound]) }
        // A line break inside the paragraph separates two sentences ("…at 5 Av only<br>Madison Av entrance…").
        text = text.replacingOccurrences(of: "<br\\s*/?>", with: "\u{1}", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        text = text.components(separatedBy: "\u{1}").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .map { $0.last.map { ".!?:".contains($0) } == true ? $0 : $0 + "." }.joined(separator: " ")
            .replacingOccurrences(of: "\\.$", with: "", options: .regularExpression)  // a single sentence needs no stop
        for (entity, character) in [("&amp;", "&"), ("&nbsp;", " "), ("&#39;", "'"), ("&quot;", "\""), ("\u{200C}", "")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// The route a token in an alert's text stands for ("[F]" → "F", "[SIR]" → "SI", "[S]" → "GS": every shuttle's
    /// symbol is the same gray S), or nil for other tokens (the MTA also writes icons as tokens, like
    /// "[shuttle bus icon]").
    static func route(forToken token: String) -> String? {
        switch token {
        case "SIR": return "SI"
        case "S": return "GS"
        default: return token.count <= 2 && token.allSatisfy({ $0.isLetter || $0.isNumber }) ? token : nil
        }
    }
}

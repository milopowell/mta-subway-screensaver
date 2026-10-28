import AppKit

/// The home-station picker, shown in a popover from the tram button. From top to bottom:
///
/// * **Your stations:** the chosen stations in the order the next-train board shows them, each with buttons to move
///   it up or down and to remove it.
/// * **Search** by name.
/// * **Browse by line:** a route symbol for every line (a dot below marks lines serving one of your stations);
///   clicking one lists that line's stations in order along the route, scrolled to your first station on it (click
///   it again to go back to all stations).
/// * **Stations**, grouped by borough, each with its route symbols and an Add / Added button. Clicking anywhere on
///   a row also adds or removes it.
/// * **Magnification** of the magnified map: "Fit stations" (automatic) or a fixed multiple of the whole map.
///
/// At most `SubwaySettings.maxHomeStations` can be chosen; at the limit the Add buttons are disabled and a note says
/// why. Every change is reported through `onChange` straight away (no Save button).
final class StationPickerController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private enum Row {
        case header(String)
        case station(String)
    }

    private static let boroughs = [("M", "Manhattan"), ("Bx", "The Bronx"), ("Bk", "Brooklyn"), ("Q", "Queens"),
                                   ("SI", "Staten Island")]
    /// Lines in the order riders know them (the MTA's own grouping by trunk line).
    private static let lineOrder = ["1", "2", "3", "4", "5", "6", "7", "A", "C", "E", "B", "D", "F", "M", "G", "J", "Z",
                                    "L", "N", "Q", "R", "W", "GS", "FS", "H", "SI"]

    private let network: SubwayNetwork
    private let colors: [String: (NSColor, NSColor)]
    private var selected: [String]
    private let onChange: ([String]) -> Void
    private var magnification: Double?
    private let onMagnification: (Double?) -> Void
    private let magnifier = NSSegmentedControl()
    private var line: String?  // the line being browsed, or nil for all stations
    private var rows: [Row] = []

    private let yours = NSStackView()
    private let yoursTitle = NSTextField(labelWithString: "")
    private let limit = SubwaySettings.maxHomeStations
    private let search = NSSearchField()
    private let lineButtons = NSStackView()
    private let table = NSTableView()

    /// - Parameters:
    ///   - network: for station names, routes, boroughs and each line's stops.
    ///   - selected: currently chosen station IDs (kept in this order; new picks go last).
    ///   - magnification: the current magnification (nil = "Fit stations"); `onMagnification` reports changes.
    ///   - onChange: called with the new list after every change.
    init(network: SubwayNetwork, selected: [String], magnification: Double?, onMagnification: @escaping (Double?) -> Void,
         onChange: @escaping ([String]) -> Void) {
        self.magnification = magnification
        self.onMagnification = onMagnification
        self.network = network
        colors = network.routes.mapValues { (NSColor(hex: $0.color), NSColor(hex: $0.textColor)) }
        self.selected = Array(selected.filter { network.stations[$0] != nil }.prefix(SubwaySettings.maxHomeStations))
        self.onChange = onChange
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("created in code only")
    }

    override func loadView() {
        let title = NSTextField(labelWithString: "Home stations")
        title.font = .boldSystemFont(ofSize: 13)
        let hint = label("The magnified map centres on these, and the next-train board lists their trains.", size: 11,
                         color: .secondaryLabelColor)

        yours.orientation = .vertical
        yours.alignment = .leading
        yours.spacing = 4

        search.placeholderString = "Search stations"
        search.delegate = self

        lineButtons.orientation = .vertical
        lineButtons.alignment = .leading
        lineButtons.spacing = 4
        let lines = Self.lineOrder.filter { route in network.patterns.contains { $0.route == route } }
        for chunk in stride(from: 0, to: lines.count, by: 13).map({ Array(lines[$0..<min($0 + 13, lines.count)]) }) {
            let row = NSStackView(views: chunk.map { RouteButton(route: $0, name: network.routes[$0]?.name, colors: colors, target: self, action: #selector(browse(_:))) })
            row.spacing = 4
            lineButtons.addArrangedSubview(row)
        }

        let column = NSTableColumn(identifier: .init("station"))
        column.width = 420
        table.addTableColumn(column)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.selectionHighlightStyle = .none
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.target = self
        table.action = #selector(rowClicked)
        table.floatsGroupRows = false  // borough headings scroll with the list instead of covering its first row
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false  // no extra space above the first row
        scroll.heightAnchor.constraint(equalToConstant: 300).isActive = true

        yoursTitle.font = .systemFont(ofSize: 10, weight: .semibold)
        yoursTitle.textColor = .secondaryLabelColor
        let choices = SubwaySettings.magnifications
        magnifier.segmentCount = choices.count + 1
        magnifier.setLabel("Fit stations", forSegment: 0)
        for (i, m) in choices.enumerated() { magnifier.setLabel("\(Int(m))×", forSegment: i + 1) }
        magnifier.selectedSegment = magnification.flatMap { m in choices.firstIndex { abs($0 - m) < 0.01 } }.map { $0 + 1 } ?? 0
        magnifier.target = self
        magnifier.action = #selector(magnificationChanged)
        magnifier.toolTip = "How much the magnified map is enlarged, compared with the whole map on screen"

        let stack = NSStackView(views: [title, hint, yoursTitle, yours, search,
                                        sectionTitle("BROWSE BY LINE"), lineButtons, scroll,
                                        sectionTitle("MAGNIFIED MAP"), magnifier])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(12, after: yours)
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.widthAnchor.constraint(equalToConstant: 460).isActive = true
        stack.setCustomSpacing(14, after: scroll)
        for v in [search, scroll, yours, magnifier] {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        }
        view = stack
        rebuildYours()
        reloadRows()
        // Fill the list again once the panel is on screen: a table filled before it is in a window (as in the
        // screensaver's Options sheet, which System Settings shows later) can otherwise come up empty.
        DispatchQueue.main.async { [weak self] in self?.reloadRows() }
    }

    @objc private func magnificationChanged() {
        let i = magnifier.selectedSegment
        magnification = i <= 0 ? nil : SubwaySettings.magnifications[i - 1]
        onMagnification(magnification)
    }

    // ---- Your stations ----

    private func rebuildYours() {
        yoursTitle.stringValue = "YOUR STATIONS (\(selected.count) OF \(limit))"
        yours.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if selected.isEmpty {
            yours.addArrangedSubview(label("None yet: add stations from the list below.", size: 12, color: .secondaryLabelColor))
        }
        defer {
            if selected.count >= limit {
                yours.addArrangedSubview(label("The board has room for \(limit) stations. Remove one to add another.",
                                               size: 11, color: .secondaryLabelColor))
            }
            markLines()
        }
        for (i, id) in selected.enumerated() {
            guard let station = network.stations[id] else { continue }
            let symbols = RouteSymbolsView()
            symbols.colors = colors
            symbols.routes = station.routes
            let name = label(station.name, size: 13, color: .labelColor)
            name.lineBreakMode = .byTruncatingTail
            name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let place = label(boroughName(station.borough), size: 11, color: .secondaryLabelColor)
            let up = iconButton("chevron.up", "Move up", #selector(moveChosenUp(_:)), tag: i, enabled: i > 0)
            let down = iconButton("chevron.down", "Move down", #selector(moveChosenDown(_:)), tag: i, enabled: i < selected.count - 1)
            let remove = iconButton("xmark.circle.fill", "Remove", #selector(removeChosen(_:)), tag: i, enabled: true)
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let row = NSStackView(views: [symbols, name, place, spacer, up, down, remove])
            row.spacing = 6
            yours.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: yours.widthAnchor).isActive = true
        }
    }

    @objc private func moveChosenUp(_ sender: NSButton) { swapChosen(sender.tag, sender.tag - 1) }
    @objc private func moveChosenDown(_ sender: NSButton) { swapChosen(sender.tag, sender.tag + 1) }

    private func swapChosen(_ i: Int, _ j: Int) {
        guard selected.indices.contains(i), selected.indices.contains(j) else { return }
        selected.swapAt(i, j)
        changed()
    }

    @objc private func removeChosen(_ sender: NSButton) {
        guard selected.indices.contains(sender.tag) else { return }
        selected.remove(at: sender.tag)
        changed()
    }

    private func toggle(_ id: String) {
        if let i = selected.firstIndex(of: id) {
            selected.remove(at: i)
        } else if selected.count < limit {
            selected.append(id)
        } else {
            NSSound.beep()  // full: the note under your stations says why
            return
        }
        changed()
    }

    private func changed() {
        rebuildYours()
        table.reloadData()
        onChange(selected)
    }

    // ---- Browsing and search ----

    /// Shows one line's stations (as if its symbol were clicked); nil shows all stations. Used for snapshots.
    func browseLine(_ route: String?) {
        _ = view
        line = route
        for case let row as NSStackView in lineButtons.arrangedSubviews {
            for case let button as RouteButton in row.arrangedSubviews { button.isChosen = button.route == line }
        }
        reloadRows()
    }

    @objc private func browse(_ sender: RouteButton) {
        line = line == sender.route ? nil : sender.route
        for case let row as NSStackView in lineButtons.arrangedSubviews {
            for case let button as RouteButton in row.arrangedSubviews { button.isChosen = button.route == line }
        }
        reloadRows()
    }

    /// Marks the lines that serve one of your stations.
    private func markLines() {
        let yourRoutes = Set(selected.flatMap { network.stations[$0]?.routes ?? [] })
        for case let row as NSStackView in lineButtons.arrangedSubviews {
            for case let button as RouteButton in row.arrangedSubviews { button.servesYours = yourRoutes.contains(button.route) }
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        reloadRows()
    }

    /// The stations to list: all of them by borough and name, or one line's in order along the route, with a
    /// borough heading wherever the borough changes; filtered by the search text.
    private func reloadRows() {
        let query = search.stringValue.trimmingCharacters(in: .whitespaces)
        func matches(_ id: String) -> Bool {
            query.isEmpty || (network.stations[id]?.name.localizedCaseInsensitiveContains(query) ?? false)
        }
        rows = []
        if let line {
            var lastBorough: String?
            for id in stationsAlong(line) where matches(id) {
                let borough = network.stations[id]?.borough
                if borough != lastBorough { rows.append(.header(boroughName(borough))) }
                lastBorough = borough
                rows.append(.station(id))
            }
        } else {
            for (code, name) in Self.boroughs {
                let ids = network.stations.filter { $0.value.borough == code && matches($0.key) }
                    .sorted { $0.value.name.localizedStandardCompare($1.value.name) == .orderedAscending }.map(\.key)
                if ids.isEmpty { continue }
                rows.append(.header(name))
                rows += ids.map { .station($0) }
            }
        }
        table.reloadData()
        // Browsing a line: show your first station on it (with a little context above); otherwise the top.
        let yourRow = line == nil ? nil : rows.firstIndex { if case .station(let id) = $0 { return selected.contains(id) }; return false }
        table.scroll(NSPoint(x: 0, y: yourRow.map { table.rect(ofRow: max($0 - 2, 0)).minY } ?? 0))
    }

    /// A line's stations in order from its northern end: its busiest stop pattern first, then stations only other
    /// patterns reach (branches, such as the A's Lefferts and Rockaway ends).
    private func stationsAlong(_ route: String) -> [String] {
        var out: [String] = []
        for pattern in network.patterns where pattern.route == route {
            var stations = pattern.stops.compactMap { network.platforms[$0] }.filter { network.stations[$0] != nil }
            // Read every pattern north to south (map y grows northwards), so branches join in the same direction.
            if let first = stations.first.flatMap({ network.stations[$0] }), let last = stations.last.flatMap({ network.stations[$0] }),
               first.centre[1] < last.centre[1] {
                stations.reverse()
            }
            for id in stations where !out.contains(id) { out.append(id) }
        }
        return out
    }

    private func boroughName(_ code: String?) -> String {
        Self.boroughs.first { $0.0 == code }?.1 ?? ""
    }

    // ---- Table ----

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .header = rows[row] { return 24 }
        return 28
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let name):
            let text = label(name.uppercased(), size: 11, color: .secondaryLabelColor)
            text.font = .systemFont(ofSize: 11, weight: .semibold)
            return text
        case .station(let id):
            guard let station = network.stations[id] else { return nil }
            let chosen = selected.contains(id)
            let symbols = RouteSymbolsView()
            symbols.colors = colors
            symbols.routes = station.routes
            let name = label(station.name, size: 13, color: .labelColor)
            name.lineBreakMode = .byTruncatingTail
            name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let button = NSButton(title: chosen ? "Added" : "Add", target: self, action: #selector(addClicked(_:)))
            button.controlSize = .small
            button.bezelStyle = .rounded
            button.identifier = .init(id)
            button.isEnabled = chosen || selected.count < limit  // full: only removing is possible
            if chosen {
                button.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
                button.imagePosition = .imageLeading
                button.bezelColor = .controlAccentColor
                button.toolTip = "Remove from your stations"
            } else {
                button.toolTip = "Add to your stations"
            }
            button.widthAnchor.constraint(equalToConstant: 74).isActive = true
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let row = NSStackView(views: [symbols, name, spacer, button])
            row.spacing = 8
            row.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
            row.wantsLayer = true
            row.layer?.cornerRadius = 5
            row.layer?.backgroundColor = chosen ? NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor : nil
            return row
        }
    }

    @objc private func addClicked(_ sender: NSButton) {
        if let id = sender.identifier?.rawValue { toggle(id) }
    }

    @objc private func rowClicked() {
        guard table.clickedRow >= 0, case .station(let id) = rows[table.clickedRow] else { return }
        toggle(id)
    }

    // ---- Helpers ----

    private func label(_ text: String, size: CGFloat, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size)
        field.textColor = color
        return field
    }

    private func sectionTitle(_ text: String) -> NSTextField {
        let field = label(text, size: 10, color: .secondaryLabelColor)
        field.font = .systemFont(ofSize: 10, weight: .semibold)
        return field
    }

    private func iconButton(_ symbol: String, _ tip: String, _ action: Selector, tag: Int, enabled: Bool) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage(),
                              target: self, action: action)
        button.isBordered = false
        button.tag = tag
        button.toolTip = tip
        button.isEnabled = enabled
        button.contentTintColor = symbol.hasPrefix("xmark") ? .secondaryLabelColor : .labelColor
        return button
    }
}

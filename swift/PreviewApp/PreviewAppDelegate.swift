import AppKit

/// Opens one window showing SubwayView, sized like your screen, with a minimal menu (Quit; View: layouts,
/// close-up zoom, Full Screen; Appearance; Debug).
final class PreviewAppDelegate: NSObject, NSApplicationDelegate {
    private let startFullScreen: Bool
    private var window: NSWindow?
    private var subwayView: SubwayView?

    init(startFullScreen: Bool) {
        self.startFullScreen = startFullScreen
    }

    func applicationDidFinishLaunching(_ notification: Notification) {

        // Same shape as the screen it opens on, at 70% of its size.
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1512, height: 945)
        let size = NSSize(width: screen.width * 0.7, height: screen.width * 0.7 * 982 / 1512)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "MTA Subway — Preview"
        window.backgroundColor = .black
        let view = SubwayView(frame: NSRect(origin: .zero, size: size), allowsInteraction: true)  // home-station picker button on
        view.showsStatus = true  // time, train counts, data age and CPU use along the bottom
        view.forceTimeLapse = CommandLine.arguments.contains("--time-lapse")
        if let i = CommandLine.arguments.firstIndex(of: "--time-lapse-after"), i + 1 < CommandLine.arguments.count,
           let seconds = Double(CommandLine.arguments[i + 1]) {
            view.setTimeLapseMinimumHistory(seconds)  // start the time-lapse sooner, for testing
        }
        if let i = CommandLine.arguments.firstIndex(of: "--simulate-outage"), i + 1 < CommandLine.arguments.count {
            view.simulatedOutage = Set(CommandLine.arguments[i + 1].split(separator: ",").map(String.init))
        }
        window.contentView = view
        subwayView = view
        NSApp.mainMenu = makeMenu()  // after the view exists, so the Time-lapse item shows its saved state
        view.start()  // download the feeds and start moving trains
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)  // come to the front even when launched from Terminal/Xcode
        if startFullScreen {
            window.toggleFullScreen(nil)
        }
        self.window = window
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    @objc private func showSplit() { subwayView?.setLayout(.split) }
    @objc private func showCloseUp() { subwayView?.setLayout(.closeUp) }
    @objc private func zoomIn() { subwayView?.stepMagnification(1) }
    @objc private func zoomOut() { subwayView?.stepMagnification(-1) }
    @objc private func chooseAppearance(_ item: NSMenuItem) {
        guard let view = subwayView else { return }
        view.settings.appearance = SubwaySettings.Appearance.allCases[item.tag]
        for other in item.menu?.items ?? [] where other.action == item.action { other.state = other === item ? .on : .off }
        view.settingsChanged()
    }

    /// Glass tint choices in the menu, in percent (the screensaver's Options sheet has a slider).
    private static let tints = [0, 15, 30, 50, 70]

    @objc private func chooseBoardStyle(_ item: NSMenuItem) {
        guard let view = subwayView else { return }
        view.settings.boardStyle = SubwaySettings.BoardStyle.allCases[item.tag]
        for other in item.menu?.items ?? [] where other.action == item.action { other.state = other === item ? .on : .off }
        view.settingsChanged()
    }

    @objc private func toggleBackdrops(_ item: NSMenuItem) {
        guard let view = subwayView else { return }
        view.settings.boardBackdrops.toggle()
        item.state = view.settings.boardBackdrops ? .on : .off
        view.settingsChanged()
    }

    @objc private func chooseTint(_ item: NSMenuItem) {
        guard let view = subwayView else { return }
        view.settings.boardTint = Double(item.tag) / 100
        for other in item.menu?.items ?? [] where other.action == item.action { other.state = other === item ? .on : .off }
        view.settingsChanged()
    }

    @objc private func toggleTimeLapse(_ item: NSMenuItem) {
        guard let view = subwayView else { return }
        view.forceTimeLapse.toggle()
        item.state = view.forceTimeLapse ? .on : .off
    }

    /// App menu with Quit (Command-Q); View with Split View (Command-1), Close-up (Command-2), Zoom In / Out
    /// (Command-= / Command--: the magnified map's magnification) and Enter Full Screen (Control-Command-F); Debug with Force Time-lapse
    /// (Option-Command-T), for testing the backup that normally only runs when live data is unavailable.
    private func makeMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Subway Preview", action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appItem.submenu = appMenu

        let viewItem = NSMenuItem()
        main.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Split View", action: #selector(showSplit), keyEquivalent: "1").target = self
        viewMenu.addItem(withTitle: "Close-up", action: #selector(showCloseUp), keyEquivalent: "2").target = self
        viewMenu.addItem(withTitle: "Zoom In", action: #selector(zoomIn), keyEquivalent: "=").target = self
        viewMenu.addItem(withTitle: "Zoom Out", action: #selector(zoomOut), keyEquivalent: "-").target = self
        viewMenu.addItem(.separator())
        let fullScreen = viewMenu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)),
                                          keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        viewItem.submenu = viewMenu

        // Appearance: dark, light, or one of the automatic choices.
        let lookItem = NSMenuItem()
        main.addItem(lookItem)
        let lookMenu = NSMenu(title: "Appearance")
        for (i, choice) in SubwaySettings.Appearance.allCases.enumerated() {
            let item = lookMenu.addItem(withTitle: choice.title, action: #selector(chooseAppearance(_:)), keyEquivalent: "")
            item.tag = i
            item.target = self
            item.state = subwayView?.settings.appearance == choice ? .on : .off
        }
        // The next-train board in the close-up: glass or solid, and how strongly the glass is tinted.
        lookMenu.addItem(.separator())
        let boardItem = lookMenu.addItem(withTitle: "Train Board", action: nil, keyEquivalent: "")
        let boardMenu = NSMenu(title: "Train Board")
        for (i, style) in SubwaySettings.BoardStyle.allCases.enumerated() {
            let item = boardMenu.addItem(withTitle: style.title, action: #selector(chooseBoardStyle(_:)), keyEquivalent: "")
            item.tag = i
            item.target = self
            item.state = subwayView?.settings.boardStyle == style ? .on : .off
        }
        let backdrops = boardMenu.addItem(withTitle: "Backdrops Behind Text (Clear Glass)", action: #selector(toggleBackdrops(_:)),
                                          keyEquivalent: "")
        backdrops.target = self
        backdrops.state = subwayView?.settings.boardBackdrops == true ? .on : .off
        boardMenu.addItem(.separator())
        for percent in Self.tints {
            let item = boardMenu.addItem(withTitle: "Glass Tint \(percent)%", action: #selector(chooseTint(_:)), keyEquivalent: "")
            item.tag = percent
            item.target = self
            item.state = Int(((subwayView?.settings.boardTint ?? 0) * 100).rounded()) == percent ? .on : .off
        }
        boardItem.submenu = boardMenu
        lookItem.submenu = lookMenu

        // Testing tools.
        let debugItem = NSMenuItem()
        main.addItem(debugItem)
        let debugMenu = NSMenu(title: "Debug")
        let lapse = debugMenu.addItem(withTitle: "Force Time-lapse", action: #selector(toggleTimeLapse(_:)), keyEquivalent: "t")
        lapse.keyEquivalentModifierMask = [.command, .option]
        lapse.target = self
        lapse.state = subwayView?.forceTimeLapse == true ? .on : .off
        debugItem.submenu = debugMenu
        return main
    }
}

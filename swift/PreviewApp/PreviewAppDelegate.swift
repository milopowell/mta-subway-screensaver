import AppKit

/// Opens one window showing SubwayView, sized like your screen, with a minimal menu (Quit; View: layouts,
/// close-up zoom, Full Screen; Appearance; Features: the trial features; Debug).
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
        if let i = CommandLine.arguments.firstIndex(of: "--simulate-outage"), i + 1 < CommandLine.arguments.count {
            view.simulatedOutage = Set(CommandLine.arguments[i + 1].split(separator: ",").map(String.init))
        }
        window.contentView = view
        subwayView = view
        if UserDefaults.standard.bool(forKey: Self.sharesKey) { shareSettings(true) }
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
    /// Whether the preview app uses the screensaver's settings file (stations, magnification, appearance, features)
    /// instead of its own; remembered in the app's own preferences.
    private static let sharesKey = "sharesSettingsWithScreensaver"

    private func shareSettings(_ on: Bool) {
        guard let view = subwayView else { return }
        view.settings.file = on ? SubwaySettings.sharedFile(inside: false) : nil
        if on { view.settings.seedFile() }  // the screensaver has none yet: give it the preview app's
        view.settingsChanged()
        view.reloadStations()
    }

    @objc private func toggleSharing(_ item: NSMenuItem) {
        let on = item.state != .on
        UserDefaults.standard.set(on, forKey: Self.sharesKey)
        item.state = on ? .on : .off
        shareSettings(on)
        NSApp.mainMenu = makeMenu()  // the Appearance and Features menus show the settings now in use
    }

    @objc private func chooseAppearance(_ item: NSMenuItem) {
        guard let view = subwayView else { return }
        view.settings.appearance = SubwaySettings.Appearance.allCases[item.tag]
        for other in item.menu?.items ?? [] { other.state = other === item ? .on : .off }
        view.settingsChanged()
    }

    @objc private func toggleFeature(_ item: NSMenuItem) {
        guard let view = subwayView else { return }
        let feature = SubwaySettings.Feature.allCases[item.tag]
        view.settings.set(feature, on: !view.settings.isOn(feature))
        item.state = view.settings.isOn(feature) ? .on : .off
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

        // Appearance (dark, light, automatic) and the features on trial, each switched on and off here.
        let lookItem = NSMenuItem()
        main.addItem(lookItem)
        let lookMenu = NSMenu(title: "Appearance")
        for (i, choice) in SubwaySettings.Appearance.allCases.enumerated() {
            let item = lookMenu.addItem(withTitle: choice.title, action: #selector(chooseAppearance(_:)), keyEquivalent: "")
            item.tag = i
            item.target = self
            item.state = subwayView?.settings.appearance == choice ? .on : .off
        }
        lookItem.submenu = lookMenu

        let featureItem = NSMenuItem()
        main.addItem(featureItem)
        let featureMenu = NSMenu(title: "Features")
        for (i, feature) in SubwaySettings.Feature.allCases.enumerated() {
            let item = featureMenu.addItem(withTitle: feature.title, action: #selector(toggleFeature(_:)), keyEquivalent: "")
            item.tag = i
            item.target = self
            item.state = subwayView?.settings.isOn(feature) == true ? .on : .off
        }
        featureMenu.addItem(.separator())
        let share = featureMenu.addItem(withTitle: "Share Settings with Screensaver", action: #selector(toggleSharing(_:)),
                                        keyEquivalent: "")
        share.target = self
        share.state = UserDefaults.standard.bool(forKey: Self.sharesKey) ? .on : .off
        share.toolTip = "Use the screensaver's stations, magnification, appearance and features, so changes here show there too"
        featureItem.submenu = featureMenu

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

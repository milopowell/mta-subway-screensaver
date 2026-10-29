import AppKit
import ScreenSaver

/// The screensaver itself. macOS creates one of these per screen (and a small one for the preview thumbnail in
/// System Settings) and shows it while the screensaver runs.
///
/// All drawing lives in SubwayView (shared with the preview app); this class only hosts it, always in the close-up
/// layout (the magnified map filling the screen), provides the Options sheet (a running screensaver can't be clicked,
/// so the focus stations and magnification are chosen there), and makes sure everything stops when the screensaver
/// ends. `@objc(SubwaySaverView)` fixes the Objective-C class name so the bundle's
/// Info.plist can name it (NSPrincipalClass = SubwaySaverView).
@objc(SubwaySaverView)
final class SubwaySaverView: ScreenSaverView {
    private let content: SubwayView
    private let settings: SubwaySettings
    private var optionsWindow: NSWindow?

    override init?(frame: NSRect, isPreview: Bool) {
        // The screensaver keeps its own preferences, set from its Options sheet.
        let defaults = ScreenSaverDefaults(forModuleWithName: "com.milopowell.subway.saver") ?? .standard
        settings = SubwaySettings(defaults: defaults)
        settings.layout = .closeUp  // the screensaver always shows the magnified map
        content = SubwayView(frame: NSRect(origin: .zero, size: frame.size), settings: settings)
        super.init(frame: frame, isPreview: isPreview)
        content.autoresizingMask = [.width, .height]  // follow the screen's size
        addSubview(content)
        // Trains move via Core Animation and SubwayView's own timer, not ScreenSaverView's frame loop,
        // so ask macOS for as few animateOneFrame() calls as possible.
        animationTimeInterval = 60
        // Recent macOS doesn't always call stopAnimation() when the screensaver ends, and its host process
        // (legacyScreenSaver) keeps running; this notification is sent reliably, so stop on it too.
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(screensaverWillStop),
                                                            name: .init("com.apple.screensaver.willstop"), object: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("SubwaySaverView is created by macOS with init(frame:isPreview:)")
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    override func startAnimation() {
        super.startAnimation()
        content.start()
    }

    override func stopAnimation() {
        content.stop()  // stop downloads and timers: a screensaver must leave nothing running
        super.stopAnimation()
    }

    @objc private func screensaverWillStop() {
        content.stop()
    }

    // ---- Options sheet (System Settings > Screen Saver > Options…) ----

    override var hasConfigureSheet: Bool { true }

    override var configureSheet: NSWindow? {
        if let optionsWindow { return optionsWindow }
        guard let panel = content.makeSettingsController() else { return nil }

        let title = NSTextField(labelWithString: "Subway Screensaver")
        title.font = .boldSystemFont(ofSize: 15)
        let done = NSButton(title: "Done", target: self, action: #selector(closeOptions))
        done.keyEquivalent = "\r"
        done.bezelStyle = .rounded

        let header = NSStackView(views: [title])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 8
        header.edgeInsets = NSEdgeInsets(top: 16, left: 12, bottom: 0, right: 12)
        let footer = NSStackView(views: [NSView(), done])
        footer.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 12, right: 12)
        let appearance = AppearanceOptionsView(settings: settings) { [weak self] in
            self?.content.settingsChanged()
        }
        let stack = NSStackView(views: [header, panel.view, appearance, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        for v in [header, footer] { v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }

        let window = NSWindow(contentRect: NSRect(origin: .zero, size: stack.fittingSize), styleMask: [.titled],
                              backing: .buffered, defer: false)
        let host = NSViewController()
        host.view = stack
        host.addChild(panel)  // keeps the panel's controller alive with the sheet
        window.contentViewController = host
        optionsWindow = window
        return window
    }

    @objc private func closeOptions() {
        guard let window = optionsWindow else { return }
        if let parent = window.sheetParent { parent.endSheet(window) } else { NSApp.endSheet(window) }
        window.orderOut(nil)
        optionsWindow = nil  // rebuilt from the saved settings next time
    }
}

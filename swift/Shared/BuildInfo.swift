import AppKit

/// Which version of the code an app was built from. `tools/install_apps.sh` writes it into the installed copies'
/// Info.plist (key "SubwayBuild"): the commit and the date, e.g. "Commit ba4aa83, 29 Oct 2026", noting uncommitted
/// changes when there were any. A copy built any other way (Xcode, the build folder) has none.
enum BuildInfo {
    static var description: String {
        Bundle.main.object(forInfoDictionaryKey: "SubwayBuild") as? String
            ?? "Development build (not installed with tools/install_apps.sh)"
    }
}

extension NSApplication {
    /// The standard About window, showing BuildInfo as the version.
    @objc func showAboutWithBuild(_ sender: Any?) {
        orderFrontStandardAboutPanel(options: [.applicationVersion: BuildInfo.description, .version: ""])
    }
}

import AppKit

/// The appearance setting, for the screensaver's Options sheet (the preview app has the same choices in its
/// Appearance menu). A change is saved at once and reported through `onChange`.
final class AppearanceOptionsView: NSStackView {
    private let settings: SubwaySettings
    private let onChange: () -> Void
    private let appearancePopup = NSPopUpButton()

    init(settings: SubwaySettings, onChange: @escaping () -> Void) {
        self.settings = settings
        self.onChange = onChange
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 8
        edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 12, right: 12)

        for choice in SubwaySettings.Appearance.allCases { appearancePopup.addItem(withTitle: choice.title) }
        appearancePopup.selectItem(at: SubwaySettings.Appearance.allCases.firstIndex(of: settings.appearance) ?? 0)
        appearancePopup.target = self
        appearancePopup.action = #selector(appearanceChanged)
        let label = NSTextField(labelWithString: "Appearance")
        label.widthAnchor.constraint(equalToConstant: 100).isActive = true
        addArrangedSubview(NSStackView(views: [label, appearancePopup]))
    }

    required init?(coder: NSCoder) {
        fatalError("created in code only")
    }

    @objc private func appearanceChanged() {
        settings.appearance = SubwaySettings.Appearance.allCases[appearancePopup.indexOfSelectedItem]
        onChange()
    }
}

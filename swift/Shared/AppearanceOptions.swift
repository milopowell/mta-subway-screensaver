import AppKit

/// The appearance setting and the trial features' switches, for the screensaver's Options sheet (the preview app
/// has the same choices in its menus). Every change is saved at once and reported through `onChange`.
final class AppearanceOptionsView: NSStackView {
    private let settings: SubwaySettings
    private let onChange: () -> Void
    private let appearancePopup = NSPopUpButton()
    private let displays = NSPopUpButton()
    private var boxes: [SubwaySettings.Feature: NSButton] = [:]

    /// - Parameter showsDisplays: include the "Other displays" choice (the screensaver only).
    init(settings: SubwaySettings, showsDisplays: Bool, onChange: @escaping () -> Void) {
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
        addArrangedSubview(row("Appearance", appearancePopup))

        if showsDisplays {
            for choice in SubwaySettings.OtherDisplays.allCases { displays.addItem(withTitle: choice.title) }
            displays.selectItem(at: SubwaySettings.OtherDisplays.allCases.firstIndex(of: settings.otherDisplays) ?? 0)
            displays.target = self
            displays.action = #selector(displaysChanged)
            addArrangedSubview(row("Other displays", displays))
        }

        let header = NSTextField(labelWithString: "Trying out")
        header.font = .systemFont(ofSize: 12, weight: .semibold)
        addArrangedSubview(header)
        for feature in SubwaySettings.Feature.allCases {
            let box = NSButton(checkboxWithTitle: feature.title, target: self, action: #selector(featureChanged(_:)))
            box.state = settings.isOn(feature) ? .on : .off
            boxes[feature] = box
            addArrangedSubview(box)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("created in code only")
    }

    private func row(_ title: String, _ control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.widthAnchor.constraint(equalToConstant: 100).isActive = true
        return NSStackView(views: [label, control])
    }

    @objc private func appearanceChanged() {
        settings.appearance = SubwaySettings.Appearance.allCases[appearancePopup.indexOfSelectedItem]
        onChange()
    }

    @objc private func displaysChanged() {
        settings.otherDisplays = SubwaySettings.OtherDisplays.allCases[displays.indexOfSelectedItem]
        onChange()
    }

    @objc private func featureChanged(_ sender: NSButton) {
        guard let feature = boxes.first(where: { $0.value === sender })?.key else { return }
        settings.set(feature, on: sender.state == .on)
        onChange()
    }
}

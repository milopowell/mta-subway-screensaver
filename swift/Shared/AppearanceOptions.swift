import AppKit

/// The appearance settings for the screensaver's Options sheet: dark or light, and how the next-train board is drawn
/// (glass or solid, and the glass's tint). The preview app has the same choices in its Appearance menu. A change is
/// saved at once and reported through `onChange`.
final class AppearanceOptionsView: NSStackView {
    private let settings: SubwaySettings
    private let onChange: () -> Void
    private let appearancePopup = NSPopUpButton()
    private let boardPopup = NSPopUpButton()
    private let tintSlider = NSSlider(value: 0, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let tintLabel = NSTextField(labelWithString: "")
    private let backdropsBox = NSButton(checkboxWithTitle: "Backdrops behind the text (clear glass)", target: nil, action: nil)

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
        addArrangedSubview(row("Appearance", appearancePopup))

        for choice in SubwaySettings.BoardStyle.allCases { boardPopup.addItem(withTitle: choice.title) }
        boardPopup.selectItem(at: SubwaySettings.BoardStyle.allCases.firstIndex(of: settings.boardStyle) ?? 0)
        boardPopup.target = self
        boardPopup.action = #selector(boardChanged)
        addArrangedSubview(row("Train board", boardPopup))

        tintSlider.doubleValue = settings.boardTint * 100
        tintSlider.isContinuous = true  // the board changes as you drag
        tintSlider.target = self
        tintSlider.action = #selector(tintChanged)
        tintSlider.widthAnchor.constraint(equalToConstant: 180).isActive = true
        tintLabel.widthAnchor.constraint(equalToConstant: 40).isActive = true
        addArrangedSubview(row("Glass tint", NSStackView(views: [tintSlider, tintLabel])))
        backdropsBox.state = settings.boardBackdrops ? .on : .off
        backdropsBox.target = self
        backdropsBox.action = #selector(backdropsChanged)
        addArrangedSubview(row("", backdropsBox))
        updateTint()
    }

    required init?(coder: NSCoder) {
        fatalError("created in code only")
    }

    private func row(_ title: String, _ control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.widthAnchor.constraint(equalToConstant: 100).isActive = true
        return NSStackView(views: [label, control])
    }

    /// The tint only matters on glass, and the backdrops on clear glass: show the tint's value, and dim what doesn't apply.
    private func updateTint() {
        tintLabel.stringValue = "\(Int(tintSlider.doubleValue.rounded()))%"
        tintSlider.isEnabled = settings.boardStyle != .solid
        backdropsBox.isEnabled = settings.boardStyle == .clearGlass
    }

    @objc private func backdropsChanged() {
        settings.boardBackdrops = backdropsBox.state == .on
        onChange()
    }

    @objc private func appearanceChanged() {
        settings.appearance = SubwaySettings.Appearance.allCases[appearancePopup.indexOfSelectedItem]
        onChange()
    }

    @objc private func boardChanged() {
        settings.boardStyle = SubwaySettings.BoardStyle.allCases[boardPopup.indexOfSelectedItem]
        updateTint()
        onChange()
    }

    @objc private func tintChanged() {
        settings.boardTint = tintSlider.doubleValue / 100
        updateTint()
        onChange()
    }
}

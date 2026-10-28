import CoreGraphics

/// Which part of the map to show, framed to the screen's shape.
enum Viewport {
    /// Grows `content` (a region of the map) on its short side, keeping its centre, until its width ÷ height
    /// equals `aspect`. The result shows all of `content`, with extra map (or black) around it.
    ///
    /// This is the same framing the notebook's `focus_box` does (§7), without the padding step.
    static func fit(_ content: CGRect, toAspect aspect: CGFloat) -> CGRect {
        guard aspect > 0, content.width > 0, content.height > 0 else { return content }
        var width = content.width, height = content.height
        if width / height < aspect {
            width = height * aspect  // too tall for the screen: widen
        } else {
            height = width / aspect  // too wide: heighten
        }
        return CGRect(x: content.midX - width / 2, y: content.midY - height / 2, width: width, height: height)
    }
}

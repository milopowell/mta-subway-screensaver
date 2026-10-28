import AppKit
import QuartzCore

/// One round dot per train, inside `container` (one of these per map panel).
///
/// * **Moving:** white with a soft glow, and the largest dot, so the eye goes to what is moving.
/// * **Stopped** at a station: a smaller grey dot. **Parked:** a smaller, darker dot.
///
/// Changing between them (size and colour) is animated over `morphSeconds`, so nothing pops. A hop is a
/// single Core Animation glide along the track (`.travel` commands): the dot moves continuously, speeding
/// up out of the station and slowing into the next.
final class TrainLayers {
    let container = CALayer()
    private var layers: [String: CALayer] = [:]
    private var looks: [String: TrainLook] = [:]
    /// The panel's base dot size in points (MapPanel.dotDiameter); each look is a multiple of it.
    private var dot: CGFloat = 6
    private let morphSeconds = 0.4

    /// Dot diameter for each look, in multiples of `dot`: moving dots are about a third larger than stopped ones.
    private static func diameter(_ look: TrainLook) -> CGFloat {
        switch look {
        case .moving: return 1.15
        case .stopped: return 0.85
        case .parked: return 0.7
        }
    }

    /// Carries out MotionPlanner's commands.
    ///
    /// - Parameters:
    ///   - toView: converts map units to this panel's points.
    ///   - dot: base marker size in points.
    ///   - animated: false for snapshots (no animations: travelling trains are drawn where they are now).
    func apply(_ commands: [TrainCommand], toView: (CGPoint) -> CGPoint, dot: CGFloat, animated: Bool = true) {
        if dot != self.dot {
            self.dot = dot
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for (key, layer) in layers { size(layer, looks[key] ?? .stopped) }
            CATransaction.commit()
        }
        for command in commands {
            switch command {
            case .place(let key, let point, let look):
                let layer = layers[key] ?? makeLayer(key, at: toView(point), look: look)
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.removeAnimation(forKey: "travel")
                layer.position = toView(point)
                CATransaction.commit()
                setLook(look, key: key, on: layer, animated: animated)

            case .travel(let key, let path, let duration):
                guard let first = path.first else { continue }
                let points = path.map(toView)
                let layer = layers[key] ?? makeLayer(key, at: toView(first), look: .moving)
                setLook(.moving, key: key, on: layer, animated: animated)
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.position = animated ? points[points.count - 1] : points[0]  // where it ends up / where it is
                CATransaction.commit()
                guard animated, points.count > 1 else { continue }

                // Start from where the dot is on screen right now (normally the path's first point).
                let route = CGMutablePath()
                route.move(to: layer.presentation()?.animation(forKey: "travel") != nil
                           ? (layer.presentation()?.position ?? points[0]) : points[0])
                for p in points.dropFirst() { route.addLine(to: p) }
                let glide = CAKeyframeAnimation(keyPath: "position")
                glide.path = route
                glide.calculationMode = .paced  // even spacing along the track's length…
                glide.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)  // …with gentle start and stop
                glide.duration = duration
                layer.add(glide, forKey: "travel")

            case .remove(let key):
                looks[key] = nil
                guard let layer = layers.removeValue(forKey: key) else { continue }
                CATransaction.begin()
                CATransaction.setAnimationDuration(0.6)
                CATransaction.setCompletionBlock { layer.removeFromSuperlayer() }
                layer.opacity = 0
                CATransaction.commit()
            }
        }
    }

    /// Removes every marker at once (before re-creating them, e.g. after a resize).
    func removeAll() {
        for layer in layers.values { layer.removeFromSuperlayer() }
        layers.removeAll()
        looks.removeAll()
    }

    // ---- Appearance ----

    private func makeLayer(_ key: String, at position: CGPoint, look: TrainLook) -> CALayer {
        let layer = CALayer()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        size(layer, look)
        layer.shadowColor = NSColor.white.cgColor
        layer.shadowOffset = .zero
        layer.position = position
        layer.opacity = 0
        container.addSublayer(layer)
        CATransaction.commit()
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.6)
        layer.opacity = 1  // fade in where it is (no popping)
        CATransaction.commit()
        layers[key] = layer
        looks[key] = look
        return layer
    }

    /// Sets the dot's size and outline for a look (animated if called inside an animated transaction).
    private func size(_ layer: CALayer, _ look: TrainLook) {
        let d = dot * TrainLayers.diameter(look)
        let bounds = CGRect(x: 0, y: 0, width: d, height: d)
        layer.bounds = bounds
        layer.cornerRadius = d / 2
        layer.borderColor = NSColor.black.cgColor
        layer.borderWidth = max(d / 8, 0.75)
        layer.shadowRadius = d * 0.6
        layer.shadowPath = CGPath(ellipseIn: bounds, transform: nil)  // a known shape is much cheaper to shadow
    }

    /// Moving / stopped / parked: size and colour change together over `morphSeconds`.
    private func setLook(_ look: TrainLook, key: String, on layer: CALayer, animated: Bool) {
        let colour: CGColor
        switch look {
        case .moving: colour = NSColor.white.cgColor
        case .stopped: colour = NSColor(white: 0.62, alpha: 1).cgColor
        case .parked: colour = NSColor(white: 0.38, alpha: 1).cgColor
        }
        if looks[key] == look, layer.backgroundColor == colour { return }
        looks[key] = look
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? morphSeconds : 0)
        if !animated { CATransaction.setDisableActions(true) }
        size(layer, look)
        layer.backgroundColor = colour
        layer.shadowOpacity = look == .moving ? 0.9 : 0
        layer.zPosition = look == .moving ? 2 : (look == .stopped ? 1 : 0)  // moving trains on top
        CATransaction.commit()
    }
}

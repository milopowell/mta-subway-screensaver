import AppKit
import QuartzCore

/// One round dot per train, inside `container` (one of these per map panel).
///
/// * **Moving:** white with a soft glow, and the largest dot, so the eye goes to what is moving.
/// * **Stopped** at a station: the station's circle lights up as the route's bullet (its colored circle with the
///   letter, a diamond for express variants, in a thin white ring), like the signs in the stations. The ring comes to
///   a point on the side the train will leave by, aimed along the track toward its next stop (trains waiting in both
///   directions make a point on each side). Each bullet is drawn once per direction and reused, so a waiting train
///   costs no more than a dot. On a small map, where station circles are only a few
///   points wide, it is a smaller gray dot instead. **Parked:** a smaller, darker dot.
///
/// Changing between them (size and color) is animated over `morphSeconds`, so nothing pops. A hop is a
/// single Core Animation glide along the track (`.travel` commands): the dot moves continuously, speeding
/// up out of the station and slowing into the next.
final class TrainLayers {
    let container = CALayer()
    /// The upper lines' bands (map units) a glide's path passes under (Locator.overpasses): the part of the dot inside
    /// them is hidden, so it slips under the line's black border and comes out the other side.
    var overpasses: (([CGPoint]) -> [CGPath])?
    /// Simpler motion, for the time-lapse: at 20 times speed there are dozens of stops and starts a second, so dots
    /// change look instantly instead of over `morphSeconds`, and glides (about 3 s long there) skip the overpass
    /// masks. Both are expensive in bulk, and neither is visible at that speed.
    var simple = false {
        didSet {
            guard simple != oldValue else { return }
            for (key, layer) in layers { breathe(layer, looks[key] == .stopped && bullets[key] != nil && !simple) }
        }
    }
    /// Colors for the dots (dark or light map).
    var theme: Theme = .dark {
        didSet {
            guard theme != oldValue else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for (key, layer) in layers {
                let look = looks[key] ?? .stopped
                size(layer, look, key: key)
                layer.backgroundColor = fill(look, key: key)
                layer.contents = bulletImage(key: key, look: look)
                layer.shadowColor = theme.glowColor.cgColor
                layer.shadowOpacity = look == .moving ? theme.glowOpacity : 0
            }
            CATransaction.commit()
        }
    }
    private var layers: [String: CALayer] = [:]
    private var looks: [String: TrainLook] = [:]
    /// The panel's base dot size in points (MapPanel.dotDiameter); each look is a multiple of it.
    private var dot: CGFloat = 6
    /// A station circle's diameter in points at this zoom (MapPanel), which a waiting train's bullet covers.
    private var circle: CGFloat = 8
    /// Screen pixels per point, for drawing the bullet images sharp.
    var scale: CGFloat = 2
    private let morphSeconds = 0.4
    /// route → (bullet color, letter color), from network.json (MapPanel.routeColors).
    var routeColors: [String: (NSColor, NSColor)] = [:]
    /// Trains standing at stations shown as their route's bullet: key → route.
    private var bullets: [String: String] = [:]
    /// The way each waiting train will leave, as an angle on screen (radians, in whole steps of `headingStep`).
    private var headings: [String: Int] = [:]
    private static let headingStep = CGFloat.pi / 36  // 5°: enough to follow the track, few enough images
    /// Bullet images by route, size and theme, drawn once.
    private var bulletImages: [String: CGImage] = [:]
    /// Bullets only where station circles are big enough to show them (the magnified map).
    private var usesBullets: Bool { circle >= 6 }

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
    ///   - animated: false for snapshots (no animations: traveling trains are drawn where they are now).
    func apply(_ commands: [TrainCommand], toView: (CGPoint) -> CGPoint, dot: CGFloat, circle: CGFloat, animated: Bool = true) {
        if dot != self.dot || circle != self.circle {
            self.dot = dot
            self.circle = circle
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for (key, layer) in layers {
                let look = looks[key] ?? .stopped
                size(layer, look, key: key)
                layer.contents = bulletImage(key: key, look: look)
            }
            CATransaction.commit()
        }
        for command in commands {
            switch command {
            case .place(let key, let point, let look, let route, let heading):
                let target = toView(point)
                var layer = layers[key] ?? makeLayer(key, at: target, look: look)
                let now = layer.presentation()?.position ?? layer.position  // where the dot is on screen
                if animated, distance(now, target) > TrainLayers.fadeDistance {
                    layer = replace(key, at: target, look: look)  // far: fade out here and in there
                }
                let slide = animated && distance(now, target) > 0.5 && distance(now, target) <= TrainLayers.fadeDistance
                layer.removeAnimation(forKey: "travel")
                layer.mask = nil  // standing still: never under a line
                CATransaction.begin()
                if slide {
                    CATransaction.setAnimationDuration(1.0)  // close: slide over instead of jumping
                } else {
                    CATransaction.setDisableActions(true)
                }
                layer.position = target
                CATransaction.commit()
                // A train standing at a station lights up its route's bullet (set before the look, which depends on it).
                let bullet = look == .stopped && usesBullets ? route.flatMap { routeColors[$0] != nil ? $0 : nil } : nil
                // The heading on screen (the map may be flipped or scaled), rounded to a step.
                let step = bullet == nil ? nil : heading.map { h -> Int in
                    let a = toView(point), b = toView(CGPoint(x: point.x + h.dx, y: point.y + h.dy))
                    return Int((atan2(b.y - a.y, b.x - a.x) / TrainLayers.headingStep).rounded())
                }
                if bullets[key] != bullet || headings[key] != step {
                    bullets[key] = bullet
                    headings[key] = step
                    looks[key] = nil  // re-apply the look: bullet or dot
                }
                setLook(look, key: key, on: layer, animated: animated)

            case .travel(let key, let path, let duration):
                guard let first = path.first else { continue }
                let points = path.map(toView)
                var layer = layers[key] ?? makeLayer(key, at: toView(first), look: .moving)
                let now = layer.presentation()?.position ?? layer.position
                if animated, distance(now, points[0]) > TrainLayers.fadeDistance {
                    layer = replace(key, at: points[0], look: .moving)  // far from the glide's start: fade across
                }
                bullets[key] = nil
                headings[key] = nil
                setLook(.moving, key: key, on: layer, animated: animated)
                let start = layer.presentation()?.position ?? layer.position
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.position = animated ? points[points.count - 1] : points[0]  // where it ends up / where it is
                CATransaction.commit()
                guard animated, points.count > 1 || distance(start, points[0]) > 0.5 else { continue }

                // Start from where the dot is on screen right now, so it never jumps onto the path.
                let route = CGMutablePath()
                route.move(to: start)
                for p in (distance(start, points[0]) > 0.5 ? points : Array(points.dropFirst())) { route.addLine(to: p) }
                let glide = CAKeyframeAnimation(keyPath: "position")
                glide.path = route
                glide.calculationMode = .paced  // even spacing along the track's length…
                glide.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)  // …with gentle start and stop
                glide.duration = duration
                layer.add(glide, forKey: "travel")

                // Under an overpass: a mask hides the part of the dot inside the upper lines' bands. The bands stay put
                // on the map while the dot moves, so the mask moves the opposite way, in step with the glide.
                if !simple, let bands = overpasses?(path), let first = bands.first {
                    let origin = toView(.zero), scale = toView(CGPoint(x: 1, y: 0)).x - origin.x
                    var toPoints = CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: origin.x, ty: origin.y)
                    let covered = bands.dropFirst().reduce(first) { $0.union($1) }.copy(using: &toPoints) ?? first
                    let everywhere = CGPath(rect: container.bounds.insetBy(dx: -2000, dy: -2000), transform: nil)
                    let half = layer.bounds.width / 2
                    // A container point q seen from the dot centered at p sits at q - p + half; the mask holds the
                    // container picture, so its offset is half - p.
                    func offset(_ p: CGPoint) -> CGPoint { CGPoint(x: half - p.x, y: half - p.y) }
                    let mask = CAShapeLayer()
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    mask.path = everywhere.subtracting(covered)
                    mask.anchorPoint = .zero
                    mask.bounds = .zero
                    mask.position = offset(points[points.count - 1])
                    layer.mask = mask
                    CATransaction.commit()
                    let follow = CGMutablePath()
                    let drawn = [start] + (distance(start, points[0]) > 0.5 ? points : Array(points.dropFirst()))
                    follow.move(to: offset(drawn[0]))
                    for p in drawn.dropFirst() { follow.addLine(to: offset(p)) }
                    let move = CAKeyframeAnimation(keyPath: "position")
                    move.path = follow
                    move.calculationMode = .paced
                    move.timingFunction = glide.timingFunction
                    move.duration = duration
                    mask.add(move, forKey: "follow")
                } else {
                    layer.mask = nil
                }

            case .remove(let key):
                looks[key] = nil
                bullets[key] = nil
                headings[key] = nil
                guard let layer = layers.removeValue(forKey: key) else { continue }
                fadeOut(layer)
            }
        }
    }

    /// A dot further than this (in points) from where it must be fades out and back in there; a nearer one slides.
    private static let fadeDistance: CGFloat = 30

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    private func fadeOut(_ layer: CALayer) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(1.0)
        CATransaction.setCompletionBlock { layer.removeFromSuperlayer() }
        layer.opacity = 0
        CATransaction.commit()
    }

    /// Fades a train's dot out where it is and a new one in at `position`.
    private func replace(_ key: String, at position: CGPoint, look: TrainLook) -> CALayer {
        if let old = layers.removeValue(forKey: key) {
            old.removeAnimation(forKey: "travel")
            old.position = old.presentation()?.position ?? old.position
            fadeOut(old)
        }
        looks[key] = nil
        return makeLayer(key, at: position, look: look)
    }

    /// Removes every marker at once (before re-creating them, e.g. after a resize).
    func removeAll() {
        for layer in layers.values { layer.removeFromSuperlayer() }
        layers.removeAll()
        looks.removeAll()
        bullets.removeAll()
        headings.removeAll()
    }

    // ---- Appearance ----

    private func makeLayer(_ key: String, at position: CGPoint, look: TrainLook) -> CALayer {
        let layer = CALayer()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        size(layer, look, key: key)
        layer.shadowColor = theme.glowColor.cgColor
        layer.shadowOffset = .zero
        layer.position = position
        layer.opacity = 0
        container.addSublayer(layer)
        layers[key] = layer
        looks[key] = look
        CATransaction.commit()
        CATransaction.begin()
        CATransaction.setAnimationDuration(1.0)
        layer.opacity = 1  // fade in where it is (no popping)
        CATransaction.commit()
        return layer
    }

    /// Sets the dot's size and outline for a look (animated if called inside an animated transaction). A train shown as
    /// its route's bullet has no dot of its own: the layer is the bullet image, with room round it for the point.
    private func size(_ layer: CALayer, _ look: TrainLook, key: String) {
        let bullet = look == .stopped && bullets[key] != nil
        let d = bullet ? bulletSide : dot * TrainLayers.diameter(look)
        let bounds = CGRect(x: 0, y: 0, width: d, height: d)
        layer.bounds = bounds
        layer.cornerRadius = d / 2
        layer.borderColor = theme.trainBorder.cgColor
        layer.borderWidth = bullet ? 0 : max(d / 8, 0.75)
        layer.shadowRadius = d * 0.6
        layer.shadowPath = CGPath(ellipseIn: bounds, transform: nil)  // a known shape is much cheaper to shadow
    }

    /// The dot's color for a look: none for a train shown as its bullet (the image is the whole picture).
    private func fill(_ look: TrainLook, key: String) -> CGColor {
        look == .stopped && bullets[key] != nil ? NSColor.clear.cgColor : theme.train(look).cgColor
    }

    // ---- Route bullets ----

    /// A waiting train's bullet: a little larger than the station circle it covers, so the white ring shows round it.
    private var bulletDiameter: CGFloat { circle * 1.22 }
    /// The bullet's image (and layer) is larger, with room on every side for the point.
    private var bulletSide: CGFloat { bulletDiameter * TrainLayers.pointReach * 2 }
    /// How far the point reaches from the bullet's center, in bullet diameters.
    private static let pointReach: CGFloat = 0.8

    /// The image for a train shown as its route's bullet, or nil (a plain dot).
    private func bulletImage(key: String, look: TrainLook) -> CGImage? {
        guard look == .stopped, let route = bullets[key] else { return nil }
        let d = bulletDiameter, side = bulletSide
        let heading = headings[key]
        let cacheKey = "\(route)|\(Int((d * 10).rounded()))|\(scale)|\(theme.isLight)|\(heading.map(String.init) ?? "-")"
        if let image = bulletImages[cacheKey] { return image }
        let pixels = Int((side * scale).rounded(.up))
        guard pixels > 0, let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let ring = max(d * 0.08, 1)
        let center = CGPoint(x: side / 2, y: side / 2)
        if let heading {
            // The point: a white triangle from the tip to where its sides touch the ring, so ring and point make one
            // smooth teardrop.
            let a = CGFloat(heading) * TrainLayers.headingStep
            let r = (d - ring * 0.3) / 2, tip = d * TrainLayers.pointReach, spread = acos(r / tip)
            func at(_ angle: CGFloat, _ distance: CGFloat) -> CGPoint {
                CGPoint(x: center.x + cos(angle) * distance, y: center.y + sin(angle) * distance)
            }
            let point = NSBezierPath()
            point.move(to: at(a, tip))
            point.line(to: at(a + spread, r))
            point.line(to: at(a - spread, r))
            point.close()
            NSColor.white.setFill()
            point.fill()
        }
        // The white ring: the bullet drawn a ring-width larger in white first (a circle, or a diamond for 6X, 7X, FX).
        RouteSymbolsView.draw(route, center: center, diameter: d - ring * 0.3, colors: [route: (.white, .white)])
        RouteSymbolsView.draw(route, center: center, diameter: d - ring * 2, colors: routeColors)
        NSGraphicsContext.restoreGraphicsState()
        let image = ctx.makeImage()
        bulletImages[cacheKey] = image
        return image
    }


    /// Moving / stopped / parked: size and color change together over `morphSeconds`.
    private func setLook(_ look: TrainLook, key: String, on layer: CALayer, animated: Bool) {
        let color = fill(look, key: key)
        if looks[key] == look, layer.backgroundColor == color { return }
        looks[key] = look
        CATransaction.begin()
        let morph = animated && !simple
        CATransaction.setAnimationDuration(morph ? morphSeconds : 0)
        if !morph { CATransaction.setDisableActions(true) }
        size(layer, look, key: key)
        layer.contents = bulletImage(key: key, look: look)  // fades over the morph, from the dot to the bullet and back
        layer.contentsScale = scale
        layer.backgroundColor = color
        layer.shadowOpacity = look == .moving ? theme.glowOpacity : 0
        layer.zPosition = look == .moving ? 2 : (look == .stopped ? 1 : 0)  // moving trains on top
        CATransaction.commit()
        breathe(layer, look == .stopped && bullets[key] != nil && !simple)
    }

    // ---- Breathing ----

    /// Seconds for one breath of a waiting train's bullet (dim and back).
    private static let breathSeconds: CFTimeInterval = 3.6

    /// A waiting train's bullet breathes: it dims a little and comes back, slowly. Kept cheap for the screen: the
    /// bullet is a finished image, so a breath only changes how strongly it is blended in, never redraws it; the
    /// animation asks for about 12 frames a second instead of the display's 60 to 120 (a slow breath looks the same);
    /// and every bullet keeps the same beat, so the map breathes as one. The dimming is added to the layer's own
    /// opacity, so fading in and out still works on top of it.
    private func breathe(_ layer: CALayer, _ on: Bool) {
        guard on else { layer.removeAnimation(forKey: "breathe"); return }
        guard layer.animation(forKey: "breathe") == nil else { return }
        let breath = CAKeyframeAnimation(keyPath: "opacity")
        breath.values = [0, -0.45, 0]
        breath.keyTimes = [0, 0.5, 1]
        breath.timingFunctions = [CAMediaTimingFunction(name: .easeInEaseOut), CAMediaTimingFunction(name: .easeInEaseOut)]
        breath.isAdditive = true
        breath.duration = TrainLayers.breathSeconds
        breath.repeatCount = .infinity
        breath.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 15, preferred: 12)
        // In step with every other bullet: each breath starts on a whole multiple of the period, so a new bullet
        // joins the beat partway through rather than starting its own.
        let now = layer.convertTime(CACurrentMediaTime(), from: nil)
        breath.beginTime = (now / TrainLayers.breathSeconds).rounded(.down) * TrainLayers.breathSeconds
        layer.add(breath, forKey: "breathe")
    }
}

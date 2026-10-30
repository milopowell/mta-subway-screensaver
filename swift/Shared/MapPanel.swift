import AppKit
import QuartzCore

/// One view of the map: a region of it (`mapRect`) drawn into a rectangle of the screen (`frame`), with its
/// own trains. The full map and the magnified view are two of these.
///
/// Layers, back to front: map bitmap → trains → outline (optional: marks another panel's region).
/// Trains are drawn by TrainLayers: white dots while moving, smaller gray dots while stopped.
final class MapPanel {
    let root = CALayer()
    private let mapLayer = CALayer()
    private let trains = TrainLayers()
    private let outline = CAShapeLayer()

    /// The map shown (it changes with the theme: black or light); call `layout` afterwards to redraw it.
    var document: MapDocument {
        didSet { renderedFor = nil }
    }
    /// The region of the map shown, in map units (always the same shape as `frame`).
    private(set) var mapRect: CGRect = .zero
    /// Smallest and largest base marker size, in points, whatever the zoom.
    var dotRange: ClosedRange<CGFloat> = 4.5...12
    /// The size of a train dot in map units (the notebook's TRAIN_DOT_UNITS).
    var dotUnits: CGFloat = 6.5
    private var renderedFor: (size: CGSize, scale: CGFloat, rect: CGRect)?

    init(document: MapDocument) {
        self.document = document
        root.masksToBounds = true  // trains outside the region are clipped, not drawn over neighbors
        root.backgroundColor = NSColor.black.cgColor
        mapLayer.contentsGravity = .resize
        outline.fillColor = nil
        outline.strokeColor = NSColor(white: 1, alpha: 0.7).cgColor
        outline.lineDashPattern = [4, 3]
        for layer in [mapLayer, trains.container, outline] { root.addSublayer(layer) }
    }

    /// Colors for a theme (the map itself is `document`).
    var theme: Theme = .dark {
        didSet {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            root.backgroundColor = theme.background.cgColor
            outline.strokeColor = theme.outline.cgColor
            CATransaction.commit()
            trains.theme = theme
            renderedFor = nil  // the area outside the map page takes the background color
        }
    }

    /// Places the panel on screen and chooses what it shows.
    ///
    /// - Parameters:
    ///   - frame: where the panel goes, in the parent view's points.
    ///   - region: the part of the map that must be visible; it's widened or heightened to the panel's shape.
    ///   - scale: screen pixels per point (2 on Retina), for a crisp map bitmap.
    func layout(frame: CGRect, showing region: CGRect, scale: CGFloat) {
        guard frame.width > 0, frame.height > 0 else { return }
        mapRect = Viewport.fit(region, toAspect: frame.width / frame.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.frame = frame
        for layer in [mapLayer, trains.container, outline] { layer.frame = root.bounds }
        CATransaction.commit()
        renderMapIfNeeded(scale: scale)
    }

    /// Points per map unit at the current zoom.
    var pointsPerUnit: CGFloat { mapRect.width > 0 ? root.bounds.width / mapRect.width : 1 }

    /// Base train marker size in points: the notebook's dot size at this zoom, kept within `dotRange`.
    /// (A moving dot is 1.15 times this; a stopped dot 0.85.)
    var dotDiameter: CGFloat { min(max(dotUnits * pointsPerUnit, dotRange.lowerBound), dotRange.upperBound) }

    /// Where glides pass under another line (see TrainLayers.overpasses).
    var overpasses: (([CGPoint]) -> [CGPath])? {
        get { trains.overpasses }
        set { trains.overpasses = newValue }
    }

    /// Simpler motion for the time-lapse (TrainLayers.simple).
    var simpleMotion: Bool {
        get { trains.simple }
        set { trains.simple = newValue }
    }

    /// Map units → this panel's points (both with the origin at the bottom-left).
    func toView(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - mapRect.minX) * pointsPerUnit, y: (p.y - mapRect.minY) * pointsPerUnit)
    }

    /// Carries out MotionPlanner's commands for this panel (`animated: false` for snapshots).
    func apply(_ commands: [TrainCommand], animated: Bool = true) {
        trains.apply(commands, toView: toView, dot: dotDiameter, circle: stationCircleUnits * pointsPerUnit, animated: animated)
    }

    /// A station circle's diameter on the map, in map units (a waiting train's bullet covers it).
    var stationCircleUnits: CGFloat = 8.2

    /// route → (bullet color, letter color), for trains waiting at stations (shown as their route's bullet).
    var routeColors: [String: (NSColor, NSColor)] {
        get { trains.routeColors }
        set { trains.routeColors = newValue }
    }

    /// Removes every train dot (before replaying the planner's state after a resize).
    func clearTrains() {
        trains.removeAll()
    }

    /// Outlines a region of the map (e.g. what the magnified panel shows); nil hides the outline.
    func setOutline(_ region: CGRect?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let region {
            let a = toView(CGPoint(x: region.minX, y: region.minY)), b = toView(CGPoint(x: region.maxX, y: region.maxY))
            outline.path = CGPath(rect: CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y), transform: nil)
        } else {
            outline.path = nil
        }
        CATransaction.commit()
    }

    /// Renders the map bitmap if the size, screen scale, region, map or theme changed.
    private func renderMapIfNeeded(scale: CGFloat) {
        let size = root.bounds.size
        if let done = renderedFor, done.size == size, done.scale == scale, done.rect == mapRect { return }
        let start = CFAbsoluteTimeGetCurrent()
        let image = document.renderImage(mapRect: mapRect, pixelSize: CGSize(width: size.width * scale, height: size.height * scale),
                                         background: theme.background.cgColor)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mapLayer.contentsScale = scale
        mapLayer.contents = image
        CATransaction.commit()
        renderedFor = (size, scale, mapRect)
        trains.scale = scale  // bullet images drawn at the screen's resolution
        NSLog("MapPanel: rendered %.0f×%.0f px in %.0f ms", size.width * scale, size.height * scale,
              (CFAbsoluteTimeGetCurrent() - start) * 1000)
    }
}

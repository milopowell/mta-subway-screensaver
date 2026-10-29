// Draws the app icons and writes them as asset catalogs:
//   - the preview app, "night lines": the dark map, with the 1/2/3 red, A/C/E blue and B/D/F/M orange lines curving
//     across a black tile and one white train on the red line;
//   - the sandbox, "blueprint": a drafting sheet, with white track lines on a blue grid, one of them dashed (planned),
//     a hollow train and a solid one.
// The artwork is original (no MTA map), so the icons are kept in the repository.
//
// Run from the mta-screensaver folder after changing a design, then rebuild:
//   swift tools/make_icons.swift

import AppKit

let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

/// Icons are drawn on a 1024-point square (full bleed: macOS rounds the corners itself). Positions are fractions of
/// the side, measured from the top left.
let side: CGFloat = 1024
func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * side, y: (1 - y) * side) }

func srgb(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1)
}

/// A line along `path`, `width` a fraction of the side.
func stroke(_ path: NSBezierPath, _ color: NSColor, width: CGFloat, dash: [CGFloat]? = nil) {
    path.lineWidth = width * side
    if let dash { path.setLineDash(dash.map { $0 * side }, count: dash.count, phase: 0) }
    color.setStroke()
    path.stroke()
}

/// A train dot: `fill` inside a ring (both fractions of the side).
func dot(_ center: CGPoint, radius: CGFloat, fill: NSColor, ring: NSColor, ringWidth: CGFloat) {
    let r = radius * side
    let path = NSBezierPath(ovalIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
    fill.setFill()
    path.fill()
    if ringWidth > 0 { stroke(path, ring, width: ringWidth) }
}

/// A path through points, with a rounded corner at each `(corner, end)` pair: a quadratic curve that turns at
/// `corner` and continues from `end`.
func track(_ start: CGPoint, _ steps: [(corner: CGPoint?, to: CGPoint)]) -> NSBezierPath {
    let path = NSBezierPath()
    path.move(to: start)
    for step in steps {
        if let c = step.corner {
            let p0 = path.currentPoint, p2 = step.to
            path.curve(to: p2, controlPoint1: CGPoint(x: p0.x + (c.x - p0.x) * 2 / 3, y: p0.y + (c.y - p0.y) * 2 / 3),
                       controlPoint2: CGPoint(x: p2.x + (c.x - p2.x) * 2 / 3, y: p2.y + (c.y - p2.y) * 2 / 3))
        } else {
            path.line(to: step.to)
        }
    }
    return path
}

/// The preview app: three lines curving across the night map, one train on the red line.
func drawNightLines() {
    let black = NSColor(white: 0.043, alpha: 1)
    black.setFill()
    NSRect(x: 0, y: 0, width: side, height: side).fill()
    stroke(track(at(0.18, 1), [(nil, at(0.18, 0.58)), (at(0.18, 0.42), at(0.34, 0.42)), (nil, at(1, 0.42))]),
           srgb(0xEE352E), width: 0.09)
    stroke(track(at(0.32, 1), [(nil, at(0.32, 0.64)), (at(0.32, 0.56), at(0.40, 0.56)), (nil, at(1, 0.56))]),
           srgb(0x0039A6), width: 0.09)
    stroke(track(at(0, 0.28), [(nil, at(0.58, 0.28)), (at(0.72, 0.28), at(0.72, 0.42)), (nil, at(0.72, 1))]),
           srgb(0xFF6319), width: 0.09)
    dot(at(0.54, 0.42), radius: 0.075, fill: .white, ring: black, ringWidth: 0.02)
}

/// The sandbox: the same idea on a drafting sheet.
func drawBlueprint() {
    let paper = srgb(0x1F4E8C)
    paper.setFill()
    NSRect(x: 0, y: 0, width: side, height: side).fill()
    let grid = NSBezierPath()
    for f in [0.2, 0.4, 0.6, 0.8] as [CGFloat] {
        grid.move(to: at(f, 0)); grid.line(to: at(f, 1))
        grid.move(to: at(0, f)); grid.line(to: at(1, f))
    }
    stroke(grid, srgb(0x4E79B5), width: 0.015)
    stroke(track(at(0, 0.38), [(nil, at(1, 0.38))]), .white, width: 0.07)
    stroke(track(at(0.6, 0), [(nil, at(0.6, 1))]), .white, width: 0.07, dash: [0.10, 0.06])  // a planned line
    stroke(track(at(0, 0.68), [(nil, at(1, 0.68))]), .white, width: 0.07)
    dot(at(0.6, 0.38), radius: 0.08, fill: paper, ring: .white, ringWidth: 0.035)
    dot(at(0.78, 0.68), radius: 0.08, fill: .white, ring: .white, ringWidth: 0)
}

/// Renders an icon at `pixels` × `pixels` as PNG data.
func png(pixels: Int, draw: () -> Void) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: side, height: side)  // draw in 1024-point units at any pixel size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

/// Writes `<app>/Assets.xcassets/AppIcon.appiconset` with every size macOS uses (16 to 512 points, at 1× and 2×).
func writeCatalog(app: String, draw: () -> Void) throws {
    let catalog = project.appendingPathComponent("swift/\(app)/Assets.xcassets")
    let set = catalog.appendingPathComponent("AppIcon.appiconset")
    try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
    try Data(#"{"info":{"author":"xcode","version":1}}"#.utf8).write(to: catalog.appendingPathComponent("Contents.json"))
    var images: [[String: String]] = []
    for points in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
            try png(pixels: points * scale, draw: draw).write(to: set.appendingPathComponent(name))
            images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
        }
    }
    let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
    try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
        .write(to: set.appendingPathComponent("Contents.json"))
    print("wrote \(set.path)")
}

try writeCatalog(app: "PreviewApp", draw: drawNightLines)
try writeCatalog(app: "Sandbox", draw: drawBlueprint)

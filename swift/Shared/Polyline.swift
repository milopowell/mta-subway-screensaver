import CoreGraphics

/// A line made of straight pieces, with the few measurements train placement needs.
/// These mirror the shapely functions the notebook uses (`distance`, `project`, `substring`, `interpolate`).
struct Polyline {
    let points: [CGPoint]
    /// Distance along the line at each point (cumulative), so `length` = the last entry.
    let cumulative: [CGFloat]

    init(_ points: [CGPoint]) {
        self.points = points
        var total: CGFloat = 0
        var cumulative: [CGFloat] = [0]
        for (a, b) in zip(points, points.dropFirst()) {
            total += hypot(b.x - a.x, b.y - a.y)
            cumulative.append(total)
        }
        self.cumulative = cumulative
    }

    var length: CGFloat { cumulative.last ?? 0 }

    /// The closest point on the line to `p`: returns (distance from p, distance along the line).
    /// On a tie, the earlier piece wins (as in shapely).
    func nearest(to p: CGPoint) -> (distance: CGFloat, along: CGFloat) {
        var best = (distance: CGFloat.infinity, along: CGFloat(0))
        for k in 0..<max(points.count - 1, 0) {
            let a = points[k], b = points[k + 1]
            let dx = b.x - a.x, dy = b.y - a.y
            let len2 = dx * dx + dy * dy
            // Fraction t of the way from a to b where the perpendicular from p lands, kept within the piece.
            let t = len2 > 0 ? max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2)) : 0
            let q = CGPoint(x: a.x + t * dx, y: a.y + t * dy)
            let d = hypot(p.x - q.x, p.y - q.y)
            if d < best.distance {
                best = (d, cumulative[k] + t * (cumulative[k + 1] - cumulative[k]))
            }
        }
        return best
    }

    /// The point at distance `along` from the start (clamped to the line).
    func point(at along: CGFloat) -> CGPoint {
        guard let first = points.first else { return .zero }
        if along <= 0 { return first }
        for k in 0..<(points.count - 1) where cumulative[k + 1] >= along {
            let span = cumulative[k + 1] - cumulative[k]
            let t = span > 0 ? (along - cumulative[k]) / span : 0
            let a = points[k], b = points[k + 1]
            return CGPoint(x: a.x + t * (b.x - a.x), y: a.y + t * (b.y - a.y))
        }
        return points[points.count - 1]
    }

    /// The part of the line between distances `start` and `end` along it (start ≤ end).
    func piece(from start: CGFloat, to end: CGFloat) -> Polyline {
        var out = [point(at: start)]
        for k in 0..<points.count where cumulative[k] > start && cumulative[k] < end {
            out.append(points[k])
        }
        out.append(point(at: end))
        return Polyline(out)
    }

    /// The point a fraction (0–1) of the way along the line.
    func interpolate(fraction: CGFloat) -> CGPoint {
        point(at: fraction * length)
    }

    func reversed() -> Polyline {
        Polyline(points.reversed())
    }
}

import CoreGraphics
import Foundation

/// Checks the motion of every train from the commands it is given (MotionPlanner's or TimeLapse's), whatever their
/// source: live downloads, a recording replayed (the preview app's --replay) or the time-lapse. The line runs
/// (LineRun.swift) check one train against the stop pattern it runs; this needs no pattern, only the moves:
///
/// * **jumps:** a dot moved without gliding, a glide starting away from its dot, or a glide cut short;
/// * **going back:** a dot gliding back to a place it stood at earlier in its run;
/// * **fading to another place:** a dot removed, then shown again somewhere else within a minute;
/// * **the track:** a glide (over 12 map units) away from every drawn line, or turning back on itself;
/// * **over and under:** where the dot is hidden against where the map draws another line over its track (6 map
///   units or more in a row, as in the line runs).
///
/// Counts are kept per kind; each problem keeps its details for the report.
final class MotionAudit {
    enum Kind: String, CaseIterable {
        case jump = "jumps"
        case cutGlide = "cuts a glide short"
        case goesBack = "goes back"
        case fadesElsewhere = "fades to another place"
        case offTrack = "off the track"
        case doublesBack = "doubles back"
        case hiddenOnTop = "hidden on top"
        case shownUnder = "shown under a line"
    }

    struct Problem {
        let kind: Kind
        let key: String, route: String
        /// Where on the map (map units), and when (the clock given with the commands).
        let at: CGPoint
        let time: Double
        let detail: String
    }

    private(set) var problems: [Problem] = []
    /// How many glides were checked.
    private(set) var glides = 0

    private let locator: Locator
    /// A train's route, from its key (the replay knows its trips).
    var routeOf: (String) -> String? = { _ in nil }
    /// Extra details for a problem: what the feed said about the train, why the planner moved it.
    var explain: (String) -> String? = { _ in nil }

    /// Per train: where its dot is (or is gliding to), when its glide ends, and every place it has stood.
    private var position: [String: CGPoint] = [:]
    private var glideEnds: [String: Double] = [:]
    private var stood: [String: [CGPoint]] = [:]
    /// Trains removed, with where and when (a dot shown again elsewhere soon after faded to another place).
    private var removed: [String: (at: CGPoint, time: Double)] = [:]

    init(locator: Locator) {
        self.locator = locator
    }

    /// How many problems of each kind.
    var counts: [Kind: Int] {
        var out: [Kind: Int] = [:]
        for kind in Kind.allCases { out[kind] = problems.filter { $0.kind == kind }.count }
        return out
    }

    private func add(_ kind: Kind, _ key: String, at: CGPoint, time: Double, _ detail: String) {
        let extra = explain(key).map { "\n      " + $0 } ?? ""
        problems.append(Problem(kind: kind, key: key, route: routeOf(key) ?? "?", at: at, time: time, detail: detail + extra))
    }

    /// The nearest station's name (for problems' details).
    func nearest(_ p: CGPoint) -> String { locator.nearestStationName(to: p) }

    /// Forgets where every dot is and has been, as at the start of a new loop of the time-lapse (which removes every
    /// dot and shows each train again where it was at the loop's start: not a train going back).
    func restart() {
        position = [:]
        glideEnds = [:]
        stood = [:]
        removed = [:]
    }

    /// Looks at one tick's commands.
    func observe(_ commands: [TrainCommand], now: Double) {
        for command in commands {
            switch command {
            case .place(let key, let point, _, _, _):
                // Shown again after being removed: elsewhere, it faded across.
                if let gone = removed.removeValue(forKey: key), now - gone.time < 60, gone.at.distance(to: point) > 3 {
                    add(.fadesElsewhere, key, at: point, time: now, String(format: "faded from %@ to %@ (%.0f units)",
                                                                           nearest(gone.at), nearest(point), gone.at.distance(to: point)))
                }
                // Placed while still gliding: the glide is cut short.
                if let ends = glideEnds[key], now < ends - 0.5, let p = position[key] {
                    add(.cutGlide, key, at: p, time: now, String(format: "%.0f s before it reached %@", ends - now, nearest(p)))
                } else if let p = position[key], p.distance(to: point) > 3 {
                    // Moved without a glide.
                    add(.jump, key, at: point, time: now, String(format: "%@ to %@ (%.0f units)", nearest(p), nearest(point),
                                                                 p.distance(to: point)))
                }
                glideEnds[key] = nil
                position[key] = point
                stood[key, default: []].append(point)
            case .travel(let key, let path, let duration):
                guard let first = path.first, let last = path.last else { continue }
                // A glide starting away from the dot.
                if let p = position[key], p.distance(to: first) > 3 {
                    add(.jump, key, at: first, time: now, String(format: "glide starts %.0f units from the dot (%@)",
                                                                 p.distance(to: first), nearest(first)))
                }
                // Back to a place it stood at earlier (not the one it is leaving).
                if let earlier = stood[key]?.dropLast().first(where: { $0.distance(to: last) < 2 }), earlier.distance(to: first) > 3 {
                    add(.goesBack, key, at: last, time: now, "\(nearest(first)) back to \(nearest(last))")
                }
                check(glide: path, key: key, now: now)
                position[key] = last
                glideEnds[key] = now + duration
            case .remove(let key):
                if let p = position[key] { removed[key] = (p, now) }
                position[key] = nil
                glideEnds[key] = nil
            }
        }
    }

    /// The track checks for one glide's path.
    private func check(glide path: [CGPoint], key: String, now: Double) {
        glides += 1
        let line = Polyline(path)
        guard line.length > 12, let first = path.first, let last = path.last else { return }
        let hop = "\(nearest(first)) to \(nearest(last))"
        // On the track: near some drawn line.
        let distance = locator.distanceFromAnyLine(path: path)
        if distance > 3 {
            add(.offTrack, key, at: first, time: now, String(format: "%@: %.0f units from the nearest line on average", hop, distance))
        }
        // Never turning back on itself.
        if let turn = LineRunCheck.turnBack(path) {
            add(.doublesBack, key, at: turn, time: now, hop)
        }
        // Over and under against the map's drawing order.
        guard let route = routeOf(key) else { return }
        let check = locator.visibilityCheck(route: route, path: path)
        if let run = LineRunCheck.longestRun(check.map { $0.actual && !$0.expected }), run.count >= 6 {
            add(.hiddenOnTop, key, at: check[run.first].point, time: now, "\(hop): hidden for \(run.count) units with no line over it")
        }
        if let run = LineRunCheck.longestRun(check.map { !$0.actual && $0.expected }), run.count >= 6 {
            add(.shownUnder, key, at: check[run.first].point, time: now, "\(hop): drawn over a line for \(run.count) units")
        }
    }

    /// Counts and every problem, as JSON-ready values (for tools/check.sh): {"glides": n, "<kind>": count, …}.
    var summary: [String: Int] {
        var out = ["glides": glides]
        for (kind, n) in counts { out[kind.rawValue] = n }
        return out
    }
}

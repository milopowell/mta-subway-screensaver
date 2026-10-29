"""Link GTFS stations to the station circles on the official MTA diagram, and build per-route hop lines."""
import heapq
import re
from collections import Counter, defaultdict

import numpy as np
from scipy.interpolate import RBFInterpolator
from scipy.optimize import linear_sum_assignment
from scipy.sparse.csgraph import connected_components
from scipy.spatial import cKDTree
from shapely.geometry import LineString, Point
from shapely.ops import substring

from . import style as O


def flatten(segs, steps=8):
    lines, cur = [], []
    for k, v in segs:
        if k == "M":
            if len(cur) > 1:
                lines.append(np.array(cur))
            cur = [v]
        elif k == "L":
            cur.append(v)
        elif k == "C" and cur:
            p0 = np.array(cur[-1]); p1, p2, p3 = (np.array(q) for q in v)
            for t in np.linspace(0, 1, steps + 1)[1:]:
                cur.append(tuple((1 - t) ** 3 * p0 + 3 * (1 - t) ** 2 * t * p1 + 3 * (1 - t) * t ** 2 * p2 + t ** 3 * p3))
        elif k == "Z" and cur:
            cur.append(cur[0])
    if len(cur) > 1:
        lines.append(np.array(cur))
    return lines


def norm_name(s):
    s = s.replace("\x92", "'").lower()
    s = re.sub(r"\bsts?\b", "st", s)
    return re.sub(r"[^a-z0-9]", "", s)


def route_color_lines(drawing, COLOR):
    """{color hex: [polyline, ...]} for the thick route strokes, pairing map colors with GTFS colors one-to-one."""
    groups = sorted(set(COLOR.values()))
    gray = COLOR["L"]
    strokes = []
    for p in drawing["paths"]:
        s = p["stroke"]
        if s is None or p["lw"] < 6.5 or O.cropped(p["lo"], p["hi"]) or p.get("casing"):
            continue
        if O.is_neutral(s) and not 0.35 < O.lum(s[:3]) < 0.75:
            continue
        strokes.append((tuple(round(x, 2) for x in s[:3]), p))
    map_colors = sorted({c for c, _ in strokes if not O.is_neutral(c)})
    # cluster nearly identical map colors
    reps = []
    for c in map_colors:
        if not any(np.linalg.norm(np.array(c) - np.array(r)) < 0.08 for r in reps):
            reps.append(c)
    color_groups = [g for g in groups if g != gray]
    grgb = np.array([[int(h[i:i + 2], 16) / 255 for i in (1, 3, 5)] for h in color_groups])
    cost = np.array([[np.linalg.norm(np.array(r) - g) for g in grgb] for r in reps])
    rows, cols = linear_sum_assignment(cost)
    rep_to_group = {reps[r]: color_groups[c] for r, c in zip(rows, cols)}

    def group_of(c):
        if O.is_neutral(c):
            return gray
        r = min(reps, key=lambda r: np.linalg.norm(np.array(r) - np.array(c)))
        return rep_to_group.get(r)

    lines = defaultdict(list)
    for c, p in strokes:
        gname = group_of(c)
        if gname:
            lines[gname] += flatten(p["segs"])
    return dict(lines), rep_to_group


def station_circles(drawing, lines):
    """Dark circles = one per (station, route stopping there). Returns dicts with center, touching line colors
    and a glyph signature (the white letter/number drawn inside, identical for every circle of one route)."""
    trees = {}
    for gname, Ls in lines.items():
        pts = np.vstack([np.vstack([np.linspace(a, b, max(2, int(np.linalg.norm(b - a)))) for a, b in zip(L[:-1], L[1:])]) for L in Ls])
        trees[gname] = cKDTree(pts)
    circ, seen = [], set()
    for p in drawing["paths"]:
        if O.is_station_circle(p) and not O.cropped(p["lo"], p["hi"]):
            key = tuple(np.round((p["lo"] + p["hi"]) / 2 / 0.5).astype(int))
            if key not in seen:  # the PDF stacks some circles several times on the same spot
                seen.add(key)
                circ.append(p)
    centers = np.array([(p["lo"] + p["hi"]) / 2 for p in circ])
    ctree = cKDTree(centers)
    glyph_parts = defaultdict(list)
    for p in drawing["paths"]:
        f = p["fill"]
        if f is None or not O.is_neutral(f) or O.lum(f[:3]) <= 0.93 or max(p["hi"] - p["lo"]) >= 9:
            continue
        d, i = ctree.query((p["lo"] + p["hi"]) / 2)
        if d < 3:
            pts = []
            for k, v in p["segs"]:
                if k in ("M", "L"):
                    pts.append(v)
                elif k == "C":
                    pts += list(v)
            rel = np.round((np.array(pts) - centers[i]) / 0.3).astype(int)
            glyph_parts[i].append(tuple(map(tuple, rel)))
    circles = []
    for i, p in enumerate(circ):
        c = centers[i]
        touching = frozenset(g for g, t in trees.items() if t.query(c)[0] <= 3.5)
        sig = tuple(sorted(set(glyph_parts.get(i, []))))
        circles.append({"center": c, "lines": touching, "glyph": sig})
    return circles


SHUTTLES = ("GS", "FS", "H")  # all three shuttles use the same "S" circle


def learn_glyphs(circles, clusters, assigned, served_trips, COLOR):
    """Decide which route each glyph shape stands for.

    Votes come from matched stations, weighted by how many trips per day each candidate route makes there
    (so the A's few late-night local stops don't drown out the C). Then glyphs and routes are paired one-to-one."""
    votes = defaultdict(Counter)
    for sid, k in assigned.items():
        trips_here = served_trips[sid]
        for i in clusters[k]["members"]:
            c = circles[i]
            if not c["glyph"]:
                continue
            cands = {r: n for r, n in trips_here.items() if COLOR.get(r) in c["lines"]} or dict(trips_here)
            total = sum(cands.values())
            for r, n in cands.items():
                votes[c["glyph"]]["S" if r in SHUTTLES else r] += n / total
    # Merge glyph variants: the same letter placed a hair differently in different circles.
    sigs = list(votes)
    clouds = [np.array([pt for part in g for pt in part], dtype=float) for g in sigs]

    def shape_dist(a, b):
        if len(a) == 0 or len(b) == 0:
            return 1e9
        return (cKDTree(a).query(b)[0].mean() + cKDTree(b).query(a)[0].mean()) / 2

    family = list(range(len(sigs)))
    for i in range(len(sigs)):
        for j in range(i):
            if family[j] == j and shape_dist(clouds[i], clouds[j]) < 0.3:
                family[i] = j
                break
    fam_votes = defaultdict(Counter)
    for i, g in enumerate(sigs):
        fam_votes[family[i]].update(votes[g])
    fams = list(fam_votes)
    route_keys = sorted({r for v in fam_votes.values() for r in v})
    score = np.array([[fam_votes[f].get(r, 0.0) for r in route_keys] for f in fams])
    rows, cs = linear_sum_assignment(-score)  # one glyph family per route
    fam_route = {fams[i]: route_keys[j] for i, j in zip(rows, cs) if score[i, j] > 0.3}
    # leftover families (rare variants) go to their clear favorite
    for f in fams:
        if f not in fam_route and fam_votes[f]:
            r, n = fam_votes[f].most_common(1)[0]
            if n / sum(fam_votes[f].values()) >= 0.6:
                fam_route[f] = r
    glyph_route = {}
    for i, g in enumerate(sigs):
        r = fam_route.get(family[i])
        if r:
            glyph_route[g] = SHUTTLES if r == "S" else (r,)
    return glyph_route, votes


def cluster_circles(circles, gap=14.5, glyph_route=None, COLOR=None):
    pts = np.array([c["center"] for c in circles])
    pairs = cKDTree(pts).query_pairs(gap, output_type="ndarray")
    from scipy.sparse import coo_matrix
    n = len(pts)
    A = coo_matrix((np.ones(len(pairs)), (pairs[:, 0], pairs[:, 1])), shape=(n, n)) if len(pairs) else coo_matrix((n, n))
    _, lab = connected_components(A, directed=False)
    members_of = defaultdict(list)
    for i, l in enumerate(lab):
        members_of[l].append(i)
    out = []
    for members in members_of.values():
        groups, routes = Counter(), set()
        for i in members:
            rs = glyph_route.get(circles[i]["glyph"]) if glyph_route else None
            if rs:
                routes |= set(rs)
                for r in rs:
                    groups[COLOR[r]] += 1
            else:
                for gname in circles[i]["lines"]:
                    groups[gname] += 1
        out.append({"members": members, "center": pts[members].mean(axis=0), "groups": groups, "routes": routes})
    return out


def labels_index(drawing):
    texts = [t for t in drawing["texts"] if t["text"].strip()
             and not O.cropped(np.array([t["x"], t["y"]]), np.array([t["x"], t["y"]]))]
    texts.sort(key=lambda t: (round(t["y"], 0), t["x"]))
    labels = []
    for t in texts:
        if labels:
            L = labels[-1]
            if abs(L["y"] - t["y"]) < 0.6 and abs(L["size"] - t["size"]) < 0.3 and 0 <= t["x"] - L["x_end"] < 4:
                L["text"] += t["text"]
                L["x_end"] = t["x"] + 0.5 * t["size"] * len(t["text"])
                continue
        labels.append({"x": t["x"], "y": t["y"], "x_end": t["x"] + 0.5 * t["size"] * len(t["text"]),
                       "size": t["size"], "text": t["text"]})
    index = defaultdict(list)
    for L in labels:
        index[norm_name(L["text"])].append(np.array([(L["x"] + L["x_end"]) / 2, L["y"] + L["size"] * 0.35]))
    for A in labels:  # two-line labels
        for B in labels:
            aligned = (abs(A["x"] - B["x"]) < 3 or abs(A["x_end"] - B["x_end"]) < 6
                       or abs((A["x"] + A["x_end"]) - (B["x"] + B["x_end"])) / 2 < 5)
            if B is not A and 0 < A["y"] - B["y"] < A["size"] * 1.6 and aligned and abs(A["size"] - B["size"]) < 0.3:
                mid = np.array([(A["x"] + A["x_end"]) / 2, (A["y"] + B["y"]) / 2])
                index[norm_name(A["text"] + B["text"])].append(mid)
                index[norm_name(A["text"] + "-" + B["text"])].append(mid)
    return index


def match_stations(clusters, station_ids, station_xy, station_name, station_groups, label_index, rounds=4,
                   station_routes=None, COLOR=None):
    """Assign each GTFS station to a circle cluster. A cluster can host one station per color group it contains."""
    centers = np.array([c["center"] for c in clusters])
    cols = [(k, g) for k, c in enumerate(clusters) for g in c["groups"]]  # one slot per (cluster, color group)
    slot_tree = cKDTree(centers[[k for k, _ in cols]])

    def label_hits(sid):
        out = list(label_index.get(norm_name(station_name[sid]), []))
        if not out and "-" in station_name[sid]:
            for part in station_name[sid].split("-"):
                out += label_index.get(norm_name(part), [])
        return out

    # confident anchors: unique names with one label and a cluster of the right color next to it
    name_count = Counter(norm_name(n) for n in station_name.values())
    src, dst = [], []
    for i, sid in enumerate(station_ids):
        hits = label_index.get(norm_name(station_name[sid]), [])
        if name_count[norm_name(station_name[sid])] == 1 and len(hits) == 1:
            near = [k for k, c in enumerate(clusters) if set(c["groups"]) & station_groups[sid]
                    and np.linalg.norm(c["center"] - hits[0]) < 45]
            if near:
                k = min(near, key=lambda k: np.linalg.norm(clusters[k]["center"] - hits[0]))
                src.append(station_xy[i]); dst.append(clusters[k]["center"])
    src, dst = np.array(src), np.array(dst)
    mu, sd = station_xy.mean(axis=0), station_xy.std(axis=0)
    assigned = {}
    for rnd in range(rounds):
        warp = RBFInterpolator((src - mu) / sd, dst, kernel="thin_plate_spline", smoothing=0.5)
        pred = warp((station_xy - mu) / sd)
        BIG = 1e6
        cost = np.full((len(station_ids), len(cols)), BIG)
        radius = [150, 100, 80, 80][min(rnd, 3)]
        for i, sid in enumerate(station_ids):
            labs = label_hits(sid)
            cand = set(slot_tree.query_ball_point(pred[i], radius if labs else 160))
            for L in labs:
                cand |= set(slot_tree.query_ball_point(L, 45))
            for j in cand:
                k, gname = cols[j]
                if gname not in station_groups[sid]:
                    continue
                c = np.linalg.norm(centers[k] - pred[i])
                if labs:
                    dl = min(np.linalg.norm(centers[k] - L) for L in labs)
                    c = (0.15 * min(c, 150) + 0.5 * dl) if dl < 45 else (0.5 * c + 45)
                else:
                    c += 15
                # a cluster carrying exactly this station's colors is a better fit
                c += 4 * len(set(clusters[k]["groups"]) ^ station_groups[sid])
                if station_routes is not None and clusters[k]["routes"]:
                    on_my_colors = {r for r in clusters[k]["routes"] if COLOR.get(r) in station_groups[sid]}
                    c += 40 * len(on_my_colors - station_routes[sid])  # map says a route stops here that doesn't
                    c += 6 * len(station_routes[sid] - on_my_colors)  # part-time routes may lack a circle
                cost[i, j] = c
        rows, cs = linear_sum_assignment(cost)
        assigned = {station_ids[i]: cols[j][0] for i, j in zip(rows, cs) if cost[i, j] < BIG}
        good = [(i, cols[j][0]) for i, j in zip(rows, cs) if cost[i, j] < 25]
        src = np.array([station_xy[i] for i, _ in good])
        dst = np.array([centers[k] for _, k in good])
    return assigned, pred


class TrackNetwork:
    """One color's drawn track pieces joined into a network, so a hop can follow the line even where the PDF draws
    it in several pieces (at curves, junctions, and where a line passes under a station's transfer box).

    Pieces are joined where an end of one touches another piece (within `join` map units: most meet exactly), and
    across gaps (up to `bridge` units, e.g. where a line passes under a station's label box) where two piece ends
    point straight at each other. Two parallel lines
    that end side by side point across the gap, not along it, so they are never joined.
    """

    def __init__(self, polylines, join=4.5, bridge=40.0, bridge_angle=20.0):
        self.pieces = [np.asarray(L, dtype=float) for L in polylines if len(L) > 1]
        self.points = []  # node → (x, y)
        self.edges = defaultdict(list)  # node → [(node, length)]
        self.first = []  # piece → node of its first point
        for P in self.pieces:
            self.first.append(len(self.points))
            for k, q in enumerate(P):
                self.points.append(q)
                if k:
                    self._link(len(self.points) - 2, len(self.points) - 1)
        ends = [(i, end) for i in range(len(self.pieces)) for end in (0, -1)]
        for i, end in ends:  # an end touching another piece: join it to the nearest point of that piece
            q = self.pieces[i][end]
            for j in range(len(self.pieces)):
                if j != i:
                    k, t, d = self._project(j, q)
                    if d <= join:
                        self._link(self._node(i, end), self._insert(j, k, t))
        cos_limit = np.cos(np.radians(bridge_angle))
        for a in range(len(ends)):  # two ends pointing at each other across a short gap
            for b in range(a + 1, len(ends)):
                (i, ei), (j, ej) = ends[a], ends[b]
                if i == j:
                    continue
                qi, qj = self.pieces[i][ei], self.pieces[j][ej]
                gap = qj - qi
                d = np.linalg.norm(gap)
                if not join < d <= bridge:
                    continue
                out_i, out_j = self._outward(i, ei), self._outward(j, ej)
                if gap @ out_i / d >= cos_limit and -gap @ out_j / d >= cos_limit:
                    self._link(self._node(i, ei), self._node(j, ej))

    def _node(self, piece, end):
        return self.first[piece] + (len(self.pieces[piece]) - 1 if end == -1 else 0)

    def _link(self, a, b):
        d = float(np.linalg.norm(np.asarray(self.points[a]) - np.asarray(self.points[b])))
        self.edges[a].append((b, d))
        self.edges[b].append((a, d))

    def _outward(self, piece, end):
        """Unit direction leaving the piece at that end."""
        P = self.pieces[piece]
        v = P[0] - P[1] if end == 0 else P[-1] - P[-2]
        return v / (np.linalg.norm(v) or 1)

    def _project(self, piece, q):
        """Nearest point of a piece to q: (segment index, fraction along it, distance)."""
        P = self.pieces[piece]
        a, b = P[:-1], P[1:]
        ab = b - a
        t = np.clip(((q - a) * ab).sum(1) / np.maximum((ab * ab).sum(1), 1e-12), 0, 1)
        d = np.linalg.norm(a + ab * t[:, None] - q, axis=1)
        k = int(d.argmin())
        return k, float(t[k]), float(d[k])

    def _insert(self, piece, k, t):
        """A node at fraction t of segment k of a piece, linked to the segment's two ends."""
        a, b = self.first[piece] + k, self.first[piece] + k + 1
        if t <= 1e-9:
            return a
        if t >= 1 - 1e-9:
            return b
        P = self.pieces[piece]
        self.points.append(P[k] + (P[k + 1] - P[k]) * t)
        n = len(self.points) - 1
        self._link(n, a)
        self._link(n, b)
        return n

    def route(self, p_a, p_b, max_snap=14.0, snap_weight=10.0):
        """Shortest path along the network from near p_a to near p_b, as a list of points, or None.

        Each point snaps to every piece within `max_snap`; snapping further away costs `snap_weight` per unit, so the
        path keeps to the station's own line where same-color lines run side by side.
        """
        def snaps(q):
            out = []
            for i in range(len(self.pieces)):
                k, t, d = self._project(i, np.asarray(q, dtype=float))
                if d <= max_snap:
                    P = self.pieces[i]
                    out.append((d * snap_weight, P[k] + (P[k + 1] - P[k]) * t, self.first[i] + k, self.first[i] + k + 1))
            return out
        starts, goals = snaps(p_a), snaps(p_b)
        if not starts or not goals:
            return None
        # Dijkstra from a virtual start (-1) to a virtual goal (-2); snapped points are their own nodes (-3, -4, ...).
        pts = {}
        extra = defaultdict(list)
        for n, (cost, q, a, b) in enumerate(starts):
            v = -3 - n
            pts[v] = q
            extra[-1].append((v, cost))
            for w in (a, b):
                extra[v].append((w, float(np.linalg.norm(q - self.points[w]))))
        for n, (cost, q, a, b) in enumerate(goals):
            v = -3 - len(starts) - n
            pts[v] = q
            for w in (a, b):
                extra[w].append((v, float(np.linalg.norm(q - self.points[w]))))
            extra[v].append((-2, cost))
        for n, (_, qa, a1, b1) in enumerate(starts):  # both points on the same segment: straight along it
            for m, (_, qb, a2, b2) in enumerate(goals):
                if (a1, b1) == (a2, b2):
                    extra[-3 - n].append((-3 - len(starts) - m, float(np.linalg.norm(qa - qb))))
        best, back, heap = {-1: 0.0}, {}, [(0.0, -1)]
        while heap:
            cost, v = heapq.heappop(heap)
            if v == -2:
                break
            if cost > best.get(v, np.inf):
                continue
            for w, d in (self.edges.get(v, []) if v >= 0 else []) + extra.get(v, []):
                c = cost + d
                if c < best.get(w, np.inf):
                    best[w], back[w] = c, v
                    heapq.heappush(heap, (c, w))
        if -2 not in back:
            return None
        path, v = [], back[-2]
        while v != -1:
            path.append(pts[v] if v < 0 else self.points[v])
            v = back[v]
        return [tuple(map(float, q)) for q in path[::-1]]


_networks = {}  # id(polylines) → (polylines, TrackNetwork): one network per color's list of pieces


def track_network(polylines):
    """The TrackNetwork for a list of pieces (built once per list)."""
    hit = _networks.get(id(polylines))
    if hit is None or hit[0] is not polylines:
        hit = (polylines, TrackNetwork(polylines))
        _networks[id(polylines)] = hit
    return hit[1]


def hop_line(p_a, p_b, polylines, max_snap=14.0):
    """Line between two map points that follows the drawn track (`polylines`: one color's pieces) when both points
    sit on it, joining pieces where the PDF splits the line. Returns (LineString, followed); a straight line and
    False when the track can't be followed or the path would wander far more than the straight distance."""
    straight = LineString([p_a, p_b])
    path = track_network(polylines).route(p_a, p_b, max_snap) if len(polylines) else None
    if path is None or len(path) < 2:
        return straight, False
    piece = LineString(path)
    if piece.length < 1e-6 or piece.length > 3 * np.linalg.norm(np.array(p_b) - np.array(p_a)) + 20:
        return straight, False
    return piece, True


def complete_chains(assigned, clusters, patterns_seq, station_routes, max_step=140):
    """Fill in unmatched stations by walking along each route from its matched neighbors:
    the next stop is the nearest cluster carrying this route's circle that nobody on this route owns yet."""
    owner = defaultdict(set)  # cluster -> routes already claimed there
    for sid, k in assigned.items():
        owner[k] |= station_routes[sid]
    centers = np.array([c["center"] for c in clusters])
    added = {}
    changed = True
    while changed:
        changed = False
        for route, seq in patterns_seq:
            for direction in (seq, seq[::-1]):
                for a, b in zip(direction, direction[1:]):
                    if a in assigned and b not in assigned and b not in added:
                        start = centers[assigned[a] if a in assigned else added[a]]
                        cands = [k for k, c in enumerate(clusters) if route in c["routes"] and route not in owner[k]
                                 and np.linalg.norm(centers[k] - start) < max_step]
                        if cands:
                            k = min(cands, key=lambda k: np.linalg.norm(centers[k] - start))
                            added[b] = k
                            assigned[b] = k
                            owner[k] |= station_routes[b]
                            changed = True
    return added


def _route_class(r):
    """Routes as the map's circles show them: express variants as their line (6X → 6), shuttles as one symbol."""
    return {"FX": "F", "6X": "6", "7X": "7", "GS": "S", "FS": "S", "H": "S"}.get(r, r)


def separate_shared(assigned, clusters, patterns_seq, station_routes, complex_of, max_shift=8, max_reach=220):
    """Fix stations that ended up sharing one circle group with a station they don't transfer to.

    That happens when a run of stations is matched one circle off: on the Brighton line, Prospect Park sat on
    Parkside Av's circle, Parkside Av on Church Av's, and Prospect Park's own circle went unused. For each such
    conflict this tries sliding stations along a route they share (each takes the next station's circle and the
    last one takes an unused group, or one belonging to its own transfer complex), or moving a single station, and
    keeps the plan whose circles best carry each station's routes. Changes `assigned` in place; returns how many
    stations moved.
    """
    centers = np.array([c["center"] for c in clusters])
    routes_of = [{_route_class(r) for r in c["routes"]} for c in clusters]
    served = {s: {_route_class(r) for r in rs} for s, rs in station_routes.items()}

    def mismatch(s, k, where):
        """Routes station s needs that group k lacks, plus (half) routes k carries that s doesn't serve, not counting
        routes served by s's transfer-complex partners in the same group (a complex's stations share one pill)."""
        want, have = served.get(s, set()), routes_of[k]
        if not have:  # glyphs not learned for this group: neutral-ish
            return 0.5 * len(want)
        partners = set()
        for t, kt in where.items():
            if kt == k and t != s and complex_of.get(t, t) == complex_of.get(s, s):
                partners |= served.get(t, set())
        return len(want - have) + 0.5 * len(have - want - partners)

    neighbors = defaultdict(set)
    for _, seq in patterns_seq:
        for a, b in zip(seq, seq[1:]):
            if a != b:
                neighbors[a].add(b)
                neighbors[b].add(a)

    def expected(s, where):
        near = [where[n] for n in neighbors[s] if n in where]
        return centers[near].mean(axis=0) if near else None

    def conflicts(where):
        holders = defaultdict(list)
        for s, k in where.items():
            holders[k].append(s)
        return {k: ss for k, ss in holders.items()
                if len({complex_of.get(x, x) for x in ss}) > 1}

    def cost(plan, where):
        """How much worse (positive) or better (negative) `plan` makes the matching: the circles' routes, how far
        each station sits from where its neighbors along the line suggest, how far stations move, and conflicts."""
        after = dict(where)
        after.update(plan)
        total = 0.0
        for s, k in plan.items():
            total += mismatch(s, k, after) - mismatch(s, where[s], where)
            e_new, e_old = expected(s, after), expected(s, where)
            if e_new is not None and e_old is not None:
                total += (np.linalg.norm(centers[k] - e_new) - np.linalg.norm(centers[where[s]] - e_old)) / 25
            total += np.linalg.norm(centers[k] - centers[where[s]]) / 60  # moving far needs a good reason
        return total + 3 * (len(conflicts(after)) - len(conflicts(where)))  # a resolved conflict is worth a lot

    moved = 0
    for _ in range(60):
        bad = conflicts(assigned)
        if not bad:
            break
        used = set(assigned.values())
        free = [k for k in range(len(clusters)) if k not in used]
        best = None
        for k, holders in bad.items():
            for s in holders:
                def targets(x):
                    """Groups station x may finish in: unused ones near it or near where its neighbors suggest,
                    or any group of its own transfer complex."""
                    own = {assigned[y] for y in assigned if y != x and complex_of.get(y, y) == complex_of.get(x, x)}
                    e = expected(x, assigned)
                    near = [f for f in free if np.linalg.norm(centers[f] - centers[assigned[x]]) <= max_reach
                            or (e is not None and np.linalg.norm(centers[f] - e) <= max_reach)]
                    return near + sorted(own)
                plans = [{s: f} for f in targets(s)]
                for _, seq in patterns_seq:
                    if s not in seq:
                        continue
                    i = seq.index(s)
                    for step in (-1, 1):
                        chain = [s]
                        for m in range(1, max_shift + 1):
                            j = i + step * m
                            if not 0 <= j < len(seq) or seq[j] not in assigned or seq[j] in chain:
                                break
                            chain.append(seq[j])
                            shifted = {chain[t]: assigned[chain[t + 1]] for t in range(len(chain) - 1)}
                            plans += [{**shifted, chain[-1]: f} for f in targets(chain[-1])]
                for plan in plans:
                    c = cost(plan, assigned)
                    if best is None or c < best[0]:
                        best = (c, plan)
        if best is None or best[0] >= 0:
            break
        assigned.update(best[1])
        moved += len(best[1])
    return moved


def refine(assigned, clusters, patterns_seq, station_routes, station_name, label_index, COLOR, rounds=4):
    """Local clean-up: swap neighbors or move a station to an unclaimed circle of its route when that makes
    every route through it shorter (stations should appear in order along their lines), without fighting a label."""
    centers = np.array([c["center"] for c in clusters])
    neighbors = defaultdict(set)
    for _, seq in patterns_seq:
        for a, b in zip(seq, seq[1:]):
            neighbors[a].add(b)
            neighbors[b].add(a)
    labels = {}
    for sid in assigned:
        hits = list(label_index.get(norm_name(station_name[sid]), []))
        if not hits and "-" in station_name[sid]:
            for part in station_name[sid].split("-"):
                hits += label_index.get(norm_name(part), [])
        labels[sid] = hits

    def colors(sid):
        return {COLOR[r] for r in station_routes[sid] if r in COLOR}

    def fits(sid, k):
        c = clusters[k]
        return bool(colors(sid) & set(c["groups"])) and (not c["routes"] or bool(station_routes[sid] & c["routes"]))

    def cost(sid, k, where):
        c = sum(np.linalg.norm(centers[k] - centers[where[n]]) for n in neighbors[sid] if n in where and n != sid)
        if labels.get(sid):
            c += 60 * (min(np.linalg.norm(centers[k] - L) for L in labels[sid]) > 45)
        return c

    def claimed(k, color, where):
        return any(where[s] == k and color in colors(s) for s in where)

    moves = 0
    for _ in range(rounds):
        changed = False
        for a in list(assigned):
            ka = assigned[a]
            # swaps with a neighbor
            for b in neighbors[a]:
                if b not in assigned:
                    continue
                kb = assigned[b]
                if ka == kb or not (fits(a, kb) and fits(b, ka)):
                    continue
                trial = dict(assigned); trial[a], trial[b] = kb, ka
                if cost(a, kb, trial) + cost(b, ka, trial) < cost(a, ka, assigned) + cost(b, kb, assigned) - 8:
                    assigned[a], assigned[b] = kb, ka
                    ka = kb
                    changed = True; moves += 1
            # moves to an unclaimed cluster of this station's routes
            near = set(cKDTree(centers).query_ball_point(centers[ka], 120))
            for n in neighbors[a]:
                if n in assigned:
                    near |= set(cKDTree(centers).query_ball_point(centers[assigned[n]], 120))
            for k in near:
                if k == ka or not fits(a, k) or not clusters[k]["routes"] & station_routes[a]:
                    continue
                if any(claimed(k, col, assigned) for col in colors(a)):
                    continue
                trial = dict(assigned); trial[a] = k
                if cost(a, k, trial) < cost(a, ka, assigned) - 8:
                    assigned[a] = k
                    ka = k
                    changed = True; moves += 1
        if not changed:
            break
    return moves

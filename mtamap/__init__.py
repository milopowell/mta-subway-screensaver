"""The official MTA subway diagram, recolored for a black background, with GTFS stations located on it.

Personal use only: the diagram states it "may not be reproduced without written permission from the
Metropolitan Transportation Authority". Don't redistribute the map or anything rendered from it.
"""
from collections import Counter, defaultdict

import numpy as np
from shapely.geometry import LineString

from . import match as M
from . import style as S
from .pdfdraw import interpret

PAGE_W, PAGE_H = 1656.0, 2016.0
MAP_H = S.TITLE_Y  # the map without the title bar


class OfficialMap:
    def __init__(self, pdf_path, stops, stations, patterns, COLOR, complex_of=None, fixes=None, verbose=True):
        """`complex_of` (station → complex ID, from §2) tells stations that share a transfer complex, which may
        share a circle group, from stations matched to the same group by mistake (those get separated).
        `fixes` (station → (x, y) map point) overrides the matching: the station takes the circle group nearest
        that point. For the few stations the automatic matching still gets wrong."""
        self.COLOR = COLOR
        it = interpret(str(pdf_path))
        self.drawing = {"paths": it.paths, "texts": it.texts}
        self.bullets = S.prepare(self.drawing)

        parent_of = {s: (p if isinstance(p, str) else s) for s, p in zip(stops["stop_id"], stops["parent_station"])}
        served, served_trips = defaultdict(set), defaultdict(Counter)
        for p in patterns.itertuples():
            for s in p.stops:
                served[parent_of[s]].add(p.route_id)
                served_trips[parent_of[s]][p.route_id] += p.n_trips
        st = stations[stations["stop_id"].isin(served)]
        ids = list(st["stop_id"])
        xy = np.column_stack([st["x"], st["y"]])
        names = dict(zip(st["stop_id"], st["stop_name"]))
        groups = {s: {COLOR[r] for r in served[s]} for s in ids}
        seqs = [(p.route_id, [parent_of[s] for s in p.stops]) for p in patterns.itertuples()]

        # 1. route lines and station circles
        self.lines, _ = M.route_color_lines(self.drawing, COLOR)
        self.circles = M.station_circles(self.drawing, self.lines)
        labels = M.labels_index(self.drawing)
        # 2. first match using line colors only
        clusters = M.cluster_circles(self.circles)
        assigned, _ = M.match_stations(clusters, ids, xy, names, groups, labels)
        n1 = len(assigned)
        # 3. learn which glyph is which route, re-cluster with route identities, match again
        self.glyph_route, _ = M.learn_glyphs(self.circles, clusters, assigned, served_trips, COLOR)
        self.clusters = M.cluster_circles(self.circles, glyph_route=self.glyph_route, COLOR=COLOR)
        assigned, _ = M.match_stations(self.clusters, ids, xy, names, groups, labels, station_routes=served, COLOR=COLOR)
        n2 = len(assigned)
        # 4. fill gaps along routes, tidy up the order, fill again
        added = M.complete_chains(assigned, self.clusters, seqs, served)
        moves = M.refine(assigned, self.clusters, seqs, served, names, labels, COLOR)
        added2 = M.complete_chains(assigned, self.clusters, seqs, served)
        # 5. separate stations that ended up sharing a circle group with a station they don't transfer to
        separated = M.separate_shared(assigned, self.clusters, seqs, served, complex_of or {}) if complex_of else 0
        # 6. manual fixes
        centers = np.array([c["center"] for c in self.clusters])
        for station, point in (fixes or {}).items():
            assigned[station] = int(np.linalg.norm(centers - np.asarray(point), axis=1).argmin())

        self.assigned, self.names, self.served = assigned, names, served
        # Which routes run between each pair of neighboring stations, busiest first (for rerouted trains).
        trips_between = defaultdict(Counter)
        for p in patterns.itertuples():
            seq = [parent_of[s] for s in p.stops]
            for x, y in zip(seq, seq[1:]):
                if x != y:
                    trips_between[(x, y)][p.route_id] += p.n_trips
        self.routes_between = {pair: [r for r, _ in c.most_common()] for pair, c in trips_between.items()}
        self._hop_cache = {}
        self.report = {
            "paths": len(it.paths), "labels": len(it.texts), "station circles": len(self.circles),
            "circle groups": len(self.clusters), "glyphs learned": len(self.glyph_route),
            "matched (colors only)": n1, "matched (with glyphs)": n2,
            "filled along routes": len(added) + len(added2), "order fixes": moves, "separated": separated,
            "manual fixes": len(fixes or {}),
            "matched (final)": len(assigned), "GTFS stations": len(ids),
        }
        if verbose:
            for k, v in self.report.items():
                print(f"{k:>24}: {v}")

    # ---- positions ----
    def circle_routes(self, i):
        return set(self.glyph_route.get(self.circles[i]["glyph"], ()))

    def station_point(self, route, station):
        """Where `route`'s circle is drawn at `station` (falls back to the station's center)."""
        k = self.assigned.get(station)
        if k is None:
            return None
        members = self.clusters[k]["members"]
        own = [i for i in members if route in self.circle_routes(i)]
        if not own and len(route) == 2 and route.endswith("X"):
            # An express variant (6X, 7X, FX) with no diamond of its own here stands with its base route (the 6X on the
            # 6's circle), not on the first circle of its line's color (which may be another route's: the 4's, the B's).
            own = [i for i in members if route[0] in self.circle_routes(i)]
        if not own:
            own = [i for i in members if self.COLOR.get(route) in self.circles[i]["lines"]]
        if own:
            return self.circles[own[0]]["center"]
        return self.clusters[k]["center"]

    CIRCLE_RADIUS = 4.1  # station circles are 8.2 map units across

    def station_extent(self, station):
        """Bounding box (xmin, ymin, xmax, ymax) around every circle drawn for `station`, or None if it isn't
        on the map. Used to frame focused views so a station's whole pill stays in view."""
        k = self.assigned.get(station)
        if k is None:
            return None
        pts = np.array([self.circles[i]["center"] for i in self.clusters[k]["members"]])
        lo, hi = pts.min(axis=0) - self.CIRCLE_RADIUS, pts.max(axis=0) + self.CIRCLE_RADIUS
        return (lo[0], lo[1], hi[0], hi[1])

    def hop_line(self, route, a, b):
        """The track a `route` train follows from station a to station b: its own colored line, or, when it can't
        follow that (a rerouted train running on another line's tracks), the track of a route that normally runs
        between the two stations (`pair_line`); a straight line if neither works."""
        key = (route, a, b)
        if key not in self._hop_cache:
            pa, pb = self.station_point(route, a), self.station_point(route, b)
            if pa is None or pb is None:
                self._hop_cache[key] = (None, False)
            else:
                line, followed = M.hop_line(pa, pb, self.lines.get(self.COLOR.get(route), []))
                if not followed:
                    other = self.pair_line(a, b)
                    if other is not None:
                        line, followed = other, True
                self._hop_cache[key] = (line, followed)
        return self._hop_cache[key]

    def pair_line(self, a, b, via=True):
        """The track between neighboring stations a and b of the busiest route that normally runs from a to b along
        its own colored line; failing that (an express skipping a stop, e.g. the D from Grand St across the
        Manhattan Bridge to Atlantic Av, past DeKalb Av), two such stretches through one station in between.
        None if there is neither."""
        key = ("pair", a, b, via)
        if key not in self._hop_cache:
            self._hop_cache[key] = None
            for r in self.routes_between.get((a, b), []):
                pa, pb = self.station_point(r, a), self.station_point(r, b)
                if pa is not None and pb is not None:
                    line, followed = M.hop_line(pa, pb, self.lines.get(self.COLOR.get(r), []))
                    if followed:
                        self._hop_cache[key] = line
                        break
            if self._hop_cache[key] is None and via:
                best = None
                for (x, c) in self.routes_between:
                    if x != a or (c, b) not in self.routes_between:
                        continue
                    first, second = self.pair_line(a, c, via=False), self.pair_line(c, b, via=False)
                    if first is not None and second is not None:
                        joined = LineString(list(first.coords) + list(second.coords))
                        if best is None or joined.length < best.length:
                            best = joined
                ca, cb = (np.asarray(self.clusters[self.assigned[x]]["center"]) for x in (a, b))
                if best is not None and best.length <= 3 * np.linalg.norm(cb - ca) + 20:  # not a detour
                    self._hop_cache[key] = best
        return self._hop_cache[key]

    # ---- drawing ----
    def draw(self, ax, xlim=(0, PAGE_W), ylim=(0, MAP_H), theme="dark"):
        """Draw the map on a matplotlib axis (page coordinates, 1 unit = 1 pt on paper): black background (theme
        "dark") or the paper map's colors ("light")."""
        ax.set_xlim(*xlim)
        ax.set_ylim(*ylim)
        ax.set_facecolor("black" if theme == "dark" else S.LAND_LIGHT)
        ax.set_aspect("equal")
        ax.axis("off")
        fig = ax.figure
        bbox = ax.get_window_extent().transformed(fig.dpi_scale_trans.inverted())
        pts_per_unit = min(bbox.width * 72 / (xlim[1] - xlim[0]), bbox.height * 72 / (ylim[1] - ylim[0]))
        S.draw_official(ax, self.drawing, self.bullets, pts_per_unit, pts_per_unit, theme=theme)
        return pts_per_unit

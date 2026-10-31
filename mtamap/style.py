"""Styling + cropping for the interpreted MTA diagram: black background (dark theme) or the paper map's own colors
(light theme)."""
import matplotlib
import numpy as np
from matplotlib.path import Path
from matplotlib.font_manager import FontProperties
from matplotlib.patches import PathPatch
from matplotlib.textpath import TextPath, text_to_path
from matplotlib.transforms import Affine2D
from shapely.geometry import LineString, Polygon
from shapely.ops import unary_union

from . import pdfdraw

TITLE_Y = 1978.0  # everything above this is the title bar
LEGEND = (1010.0, 1489.0)  # x >= and y >= this is the legend / info panel

# Water and parks, as dark tints of the paper map's blue and green: just visible on black, so the labels
# "East River", "Central Park" etc. name something on screen. The paper map paints one page-sized water
# rectangle, then the land (white) on top of it, then the parks; land is painted black here so the water
# shows only where there is water.
WATER = (0.035, 0.075, 0.13)
PARKS = (0.045, 0.11, 0.06)

# Light theme: the paper map's own colors, with the white land softened to an off-white so a full screen of it isn't
# glaring. Everything white on paper that sits on land (masks behind labels, casings between lines) uses the same
# off-white; letters inside station circles and route symbols stay pure white.
LAND_LIGHT = (0.95, 0.95, 0.93)


def bbox(segs):
    pts = []
    for k, v in segs:
        if k in ("M", "L"):
            pts.append(v)
        elif k == "C":
            pts += [q for q in v if q is not None]
    a = np.array(pts) if pts else np.zeros((1, 2))
    return a.min(axis=0), a.max(axis=0)


def to_mpl_path(segs):
    verts, codes, start = [], [], None
    for kind, p in segs:
        if kind == "M":
            verts.append(p); codes.append(Path.MOVETO); start = p
        elif kind == "L":
            verts.append(p); codes.append(Path.LINETO)
        elif kind == "C":
            verts += list(p); codes += [Path.CURVE4] * 3
        elif kind == "Z":
            verts.append(start if start else (0, 0)); codes.append(Path.CLOSEPOLY)
    return Path(verts, codes) if verts else None


def lum(c):
    return 0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2]


def is_neutral(c):
    return max(c[:3]) - min(c[:3]) < 0.06


def is_yellow(c):
    return c is not None and c[0] > 0.9 and c[1] > 0.75 and c[2] < 0.25


def is_station_circle(p):
    """A small dark filled circle: the per-route station marker (letter/number drawn on top in white)."""
    f = p["fill"]
    if f is None or not is_neutral(f) or lum(f[:3]) >= 0.2 or not p["curves"]:
        return False
    w, h = p["hi"] - p["lo"]
    n_moves = sum(1 for k, _ in p["segs"] if k == "M")
    n_curves = sum(1 for k, _ in p["segs"] if k == "C")
    return 5.5 <= w <= 15 and abs(w - h) < 1.0 and n_moves == 1 and n_curves >= 4


def is_round_circle(p):
    """A station circle for drawing: is_station_circle, and truly round. Station circles are round to within 0.001
    map units; round letters drawn as outlines (the G of "LGA", the C of "Conduit") are off by 0.5 or more and must turn
    white like the rest of their label. (The matching keeps the looser test it was tuned with.)"""
    w, h = p["hi"] - p["lo"]
    return is_station_circle(p) and abs(w - h) < 0.3


def cropped(lo, hi):
    return lo[1] >= TITLE_Y - 1 or (lo[0] >= LEGEND[0] and lo[1] >= LEGEND[1])


def prepare(drawing):
    """Annotate every record with bbox info and collect yellow route bullets."""
    for p in drawing["paths"] + drawing.get("icons", []):
        p["lo"], p["hi"] = bbox(p["segs"])
        p["curves"] = any(k == "C" for k, _ in p["segs"])
    # A white stroke immediately followed by a colored stroke along the same path is a "casing":
    # the thin white outline that separates parallel route lines on the white paper map.
    paths = drawing["paths"]
    for i, p in enumerate(paths):
        p["casing"] = False
        p["pattern_casing"] = False
        s = p["stroke"]
        if s is not None and is_neutral(s) and lum(s[:3]) > 0.93 and p["fill"] is None:
            for q in paths[i + 1: i + 3]:
                if q["stroke"] is not None and q["segs"] == p["segs"] and q["lw"] < p["lw"]:
                    p["casing"] = True
                    break
                # Under a hatched (part-time) line: also a casing, but only for drawing (the station matching never
                # saw these as casings, so its flag stays as it was).
                if q.get("stroke_pattern") and q["segs"] == p["segs"] and q["lw"] < p["lw"]:
                    p["pattern_casing"] = True
                    break
    bullets = [(p["lo"], p["hi"]) for p in drawing["paths"]
               if p["fill"] is not None and is_yellow(p["fill"]) and p["curves"] and max(p["hi"] - p["lo"]) < 16]

    # Small white rectangles are either pieces of letters inside a station circle or route symbol (straight
    # letters like "1", "E", "L" are drawn as rectangles) or *masks*: white patches that hide a line behind
    # a label on the paper map. Masks must turn black on our black map; letter pieces must stay white.
    badges = [(p["lo"], p["hi"]) for p in paths
              if p["fill"] is not None and p["curves"] and 5 <= max(p["hi"] - p["lo"]) <= 30
              and abs((p["hi"] - p["lo"])[0] - (p["hi"] - p["lo"])[1]) < 1.5]  # roughly round filled shapes
    # Land: the big white shapes painted over the water before the first park (the base layer of the map).
    first_park = next((i for i, p in enumerate(paths) if p["fill"] is not None and len(p["fill"]) > 3
                       and p["fill"][3] == "Green Parks"), 0)
    for i, p in enumerate(paths):
        f = p["fill"]
        p["land"] = (i < first_park and f is not None and len(f) <= 3 and is_neutral(f) and lum(f[:3]) > 0.93
                     and (p["hi"] - p["lo"]).prod() > 20000)
    for p in paths:
        f = p["fill"]
        p["mask"] = (f is not None and p["stroke"] is None and not p["curves"] and is_neutral(f)
                     and lum(f[:3]) > 0.93 and max(p["hi"] - p["lo"]) < 40
                     and not inside_any((p["lo"] + p["hi"]) / 2, badges))
    mark_outlined(drawing)
    return bullets


def mark_outlined(drawing):
    """Flags labels the paper map also draws as outlined letters in the same place (the bus labels "LGA LINK Q70",
    for example: the text is kept for searching, the outlines are what shows). On paper the two coincide; drawn with a
    substitute font the text no longer lines up with the outlines and reads as doubled, so only the outlines are kept.
    A label counts as outlined when small filled shapes, one per letter, sit along its baseline."""
    glyphs = [((p["lo"] + p["hi"]) / 2, max(p["hi"] - p["lo"])) for p in drawing["paths"]
              if p["fill"] is not None and p["stroke"] is None and max(p["hi"] - p["lo"]) < 12]
    centers = np.array([c for c, _ in glyphs]) if glyphs else np.zeros((0, 2))
    sizes = np.array([s for _, s in glyphs]) if glyphs else np.zeros(0)
    for t in drawing["texts"]:
        letters = sum(1 for ch in clean_text(t["text"]) if not ch.isspace())
        t["outlined"] = False
        if letters < 2 or abs(t["angle"]) > 1 or not len(centers):
            continue
        width = pdfdraw.text_width(t["text"].rstrip()) * t["size"]
        inside = ((centers[:, 0] >= t["x"] - 0.5) & (centers[:, 0] <= t["x"] + width * 1.15)
                  & (centers[:, 1] >= t["y"] - 0.3 * t["size"]) & (centers[:, 1] <= t["y"] + 0.9 * t["size"])
                  & (sizes <= t["size"] * 1.3))
        t["outlined"] = inside.sum() >= 0.8 * letters


def inside_any(pt, boxes, pad=0.5):
    return any(lo[0] - pad <= pt[0] <= hi[0] + pad and lo[1] - pad <= pt[1] <= hi[1] + pad for lo, hi in boxes)


def style_path(p, bullets):
    """(facecolor, edgecolor) on black, or None to skip."""
    lo, hi = p["lo"], p["hi"]
    if cropped(lo, hi):
        return None
    w, h = hi - lo
    fc = ec = None
    f = p["fill"]
    if f is not None and len(f) > 3 and f[3] == "Blue Water":
        fc = WATER
    elif f is not None and len(f) > 3 and f[3] == "Green Parks":
        fc = PARKS
    elif p.get("land"):
        fc = (0, 0, 0)  # covers the water rectangle wherever there is land
    elif f is not None and not (len(f) > 3):
        c = tuple(min(1, max(0, x)) for x in f[:3])
        big = w * h > 20000
        if big:
            fc = None  # land, panels, beaches: let the black show through
        elif is_neutral(c) and lum(c) > 0.93:
            is_mask = p.get("mask") or (not p["curves"] and max(w, h) >= 40)  # see prepare()
            fc = (0, 0, 0) if is_mask else (1, 1, 1)  # masks behind labels -> black; letters stay white
        elif is_neutral(c) and lum(c) < 0.2:
            center = (lo + hi) / 2
            if is_round_circle(p) or inside_any(center, bullets):
                fc = c  # station circles and letters on yellow bullets stay black
            else:
                fc = (1, 1, 1)  # black label ink -> white
        elif lum(c) > 0.85 and not is_neutral(c):
            fc = None  # pale tints (beaches etc.)
        else:
            fc = c
    s = p["stroke"]
    if s is not None:
        c = tuple(min(1, max(0, x)) for x in s[:3])
        if is_neutral(c) and lum(c) < 0.2:
            ec = c if p["lw"] >= 3 else (0.8, 0.8, 0.8)  # keep pill outlines black, lighten thin leader lines
        elif is_neutral(c) and lum(c) > 0.93 and (p["lw"] < 6 or p.get("casing") or p.get("pattern_casing")):
            ec = (0, 0, 0)  # white casings around lines -> black, so they still separate lines
        else:
            ec = c
    if fc is None and ec is None:
        return None
    return fc, ec


def style_path_light(p, bullets):
    """(facecolor, edgecolor) for the light theme, or None to skip: the paper map's colors (see LAND_LIGHT)."""
    lo, hi = p["lo"], p["hi"]
    if cropped(lo, hi):
        return None
    w, h = hi - lo
    fc = ec = None
    f = p["fill"]
    if f is not None:
        c = tuple(min(1, max(0, x)) for x in f[:3])
        if len(f) > 3 or not (is_neutral(c) and lum(c) > 0.93):
            fc = c  # water, parks, lines, symbols, beaches: as printed
        else:
            is_mask = p.get("mask") or (not p["curves"] and max(w, h) >= 40)  # see prepare()
            fc = LAND_LIGHT if p.get("land") or w * h > 20000 or is_mask else (1, 1, 1)  # letters stay white
    s = p["stroke"]
    if s is not None:
        c = tuple(min(1, max(0, x)) for x in s[:3])
        ec = LAND_LIGHT if is_neutral(c) and lum(c) > 0.93 else c
    if fc is None and ec is None:
        return None
    return fc, ec


def style_text_light(t, bullets):
    """Label color for the light theme: as printed (black when the PDF gives none)."""
    if not clean_text(t["text"]).strip() or t.get("outlined"):
        return None
    if t["y"] >= TITLE_Y - 1 or (t["x"] >= LEGEND[0] and t["y"] >= LEGEND[1]) or (t["y"] > TITLE_Y - 20 and t["size"] > 15):
        return None
    c = t["color"]
    return (0, 0, 0) if c is None else tuple(min(1, max(0, x)) for x in c[:3])


def style_text(t, bullets):
    if not clean_text(t["text"]).strip() or t.get("outlined"):
        return None
    if t["y"] >= TITLE_Y - 1 or (t["x"] >= LEGEND[0] and t["y"] >= LEGEND[1]) or (t["y"] > TITLE_Y - 20 and t["size"] > 15):
        return None
    c = t["color"]
    if c is None:
        return (1, 1, 1)
    c = tuple(min(1, max(0, x)) for x in c[:3])
    if is_neutral(c) and lum(c) < 0.2:
        return c if inside_any((t["x"] + t["size"] * 0.3, t["y"] + t["size"] * 0.3), bullets) else (1, 1, 1)
    return c


def clean_text(s):
    s = s.replace("\x92", "’").replace("\x96", "–").replace("\x97", "—")
    return "".join(ch for ch in s if ord(ch) >= 32)  # icon-font codes (accessibility symbols etc.) can't be drawn as text


# Part-time services (the Z, the 7 express, …) are drawn on the paper map with a tiling pattern: thin diagonal stripes
# in the route's color over a white line. The stripes are about 0.8 map units wide and 1.7 apart (backslash direction:
# matplotlib draws 6 hatch lines per inch per backslash, and one map unit is one point when exporting).
HATCH = "\\" * 5
HATCH_WIDTH = 0.8
HATCH_WASH = 0.35  # opacity of the route color under the stripes, on the dark map


def pattern_of(p):
    """The route color of a patterned (hatched) stroke or fill, or None."""
    return p.get("stroke_pattern") or p.get("fill_pattern")


def to_path(geometry):
    """A shapely (multi)polygon as a matplotlib path, holes included."""
    verts, codes = [], []
    for poly in getattr(geometry, "geoms", [geometry]):
        for ring in [poly.exterior, *poly.interiors]:
            pts = list(ring.coords)
            verts += pts
            codes += [Path.MOVETO] + [Path.LINETO] * (len(pts) - 2) + [Path.CLOSEPOLY]
    return Path(verts, codes)


def hatched(ax, p, lw_scale, zorder, theme):
    """Draws a patterned stroke or fill as diagonal stripes in its route color, like the paper map's pattern. On the
    dark map a faint wash of the color goes under the stripes (on paper the gaps are white, which reads as a lighter
    version of the color; black gaps alone would read as railroad ties)."""
    path = to_mpl_path(p["segs"])
    color = pattern_of(p)
    if p.get("stroke_pattern"):
        lines = [LineString(v) for v in path.to_polygons(closed_only=False) if len(v) > 1]
        area = unary_union([line.buffer(p["lw"] / 2, cap_style=2, join_style=1) for line in lines])
    else:
        area = unary_union([Polygon(v).buffer(0) for v in path.to_polygons() if len(v) > 2])
    if area.is_empty:
        return
    matplotlib.rcParams["hatch.linewidth"] = HATCH_WIDTH * lw_scale  # read when the figure is drawn
    outline = to_path(area)
    if theme == "dark":  # separate from the stripes: in a PDF the hatch takes the patch's opacity
        ax.add_patch(PathPatch(outline, facecolor=(*color, HATCH_WASH), edgecolor="none", lw=0, zorder=zorder))
    ax.add_patch(PathPatch(outline, facecolor="none", edgecolor=color, lw=0, hatch=HATCH, zorder=zorder))


def dashes(p, lw_scale, lw):
    """The paper map's dash pattern for a stroke, as a matplotlib line style: the dotted bus links to LaGuardia
    (zero-length dashes with round caps make dots), ferries and the like. Matplotlib scales dashes by the line width,
    so the pattern is divided by it."""
    if not p.get("dash") or lw <= 0:
        return "solid"
    pattern, phase = p["dash"]
    pattern = [max(x * lw_scale / lw, 1e-3) for x in pattern]
    return (phase * lw_scale / lw, pattern if len(pattern) % 2 == 0 else pattern * 2)


LABEL_FONTS = {False: FontProperties(family=["Helvetica", "Arial", "DejaVu Sans"], size=100),
               True: FontProperties(family=["Arial", "DejaVu Sans"], weight="bold", size=100)}


def label_outline(ax, t, color, zorder):
    """Draws a label as letter outlines in a substitute font (Helvetica; Arial Bold for the medium weight), squeezed or
    stretched along its line to the exact width it has on the paper map (`advance`, from the map font's own character
    widths). Helvetica runs about 5 to 10% wider than the map's Neue Haas Grotesk, so at its natural width a label
    would run into the icon or line beside it."""
    text = clean_text(t["text"])
    prop = LABEL_FONTS[bool(t.get("bold"))]
    natural = text_to_path.get_text_width_height_descent(text, prop, ismath=False)[0] / 100  # per unit of font size
    if natural <= 0:
        return
    stretch = min(max(t["advance"] / (natural * t["size"]), 0.8), 1.15)
    path = TextPath((0, 0), text, size=1, prop=prop)
    to_map = Affine2D().scale(t["size"] * stretch, t["size"]).rotate_deg(t["angle"]).translate(t["x"], t["y"])
    ax.add_patch(PathPatch(to_map.transform_path(path), facecolor=color, edgecolor="none", lw=0, zorder=zorder))


def draw_official(ax, drawing, bullets, lw_scale, text_scale, zorder=0, theme="dark"):
    """Draw the map onto a matplotlib axis in page coordinates: black background (theme "dark") or the paper
    map's colors ("light")."""
    path_style, text_style = (style_path_light, style_text_light) if theme == "light" else (style_path, style_text)
    n = 0
    for p in drawing["paths"]:
        if pattern_of(p) and not cropped(p["lo"], p["hi"]):
            hatched(ax, p, lw_scale, zorder + n * 1e-6, theme)  # a part-time service's hatched line, as on paper
            n += 1
            continue
        st = path_style(p, bullets)
        if st is None:
            continue
        fc, ec = st
        path = to_mpl_path(p["segs"])
        lw = p["lw"] * lw_scale if ec is not None else 0
        # As see-through as on paper (the Staten Island Railway's pale line is its blue at 60%).
        fc = (*fc[:3], p.get("fill_alpha", 1.0)) if fc is not None else None
        ec = (*ec[:3], p.get("stroke_alpha", 1.0)) if ec is not None else None
        ax.add_patch(PathPatch(path, facecolor=fc if fc is not None else "none",
                               edgecolor=ec if ec is not None else "none", lw=lw,
                               linestyle=dashes(p, lw_scale, lw) if ec is not None else "solid",
                               zorder=zorder + n * 1e-6, capstyle="round" if p.get("dash") and p.get("cap") == 1 else "butt",
                               joinstyle="miter"))
        n += 1
    # The icon font's symbols beside station names (accessibility, police, warning, airport, bus): self-contained
    # badges, drawn in their printed colors on both maps, above the map. On the dark map an icon that is only black
    # and white (the bus, the police shield) is drawn the other way round: printed black on a white page, it would
    # vanish into the black; icons on a colored plate (the blue accessibility tile, the yellow warning and airport
    # signs) stay as printed.
    icons = drawing.get("icons", [])
    plain = {tag for tag in {p["tag"] for p in icons}
             if all(is_neutral(c) for q in icons if q["tag"] == tag for c in (q["fill"], q["stroke"]) if c is not None)}
    for p in icons:
        if cropped(p["lo"], p["hi"]) or (p["fill"] is None and p["stroke"] is None):
            continue
        flip = theme == "dark" and p["tag"] in plain
        def ink(c, alpha):
            rgb = tuple(1 - x for x in c[:3]) if flip else tuple(c[:3])
            return (*rgb, alpha)
        fc = ink(p["fill"], p.get("fill_alpha", 1.0)) if p["fill"] is not None else "none"
        ec = ink(p["stroke"], p.get("stroke_alpha", 1.0)) if p["stroke"] is not None else "none"
        ax.add_patch(PathPatch(to_mpl_path(p["segs"]), facecolor=fc, edgecolor=ec,
                               lw=p["lw"] * lw_scale if p["stroke"] is not None else 0, zorder=zorder + 0.5))
    for t in drawing["texts"]:
        c = text_style(t, bullets)
        if c is None:
            continue
        if t.get("advance"):
            label_outline(ax, t, c, zorder + 1)
            continue
        ax.text(t["x"], t["y"], clean_text(t["text"]), rotation=t["angle"], rotation_mode="anchor",
                fontsize=t["size"] * text_scale, color=c,
                # macOS's Helvetica comes as one collection file, of which matplotlib reads only the regular face, so
                # the bold labels (the map's medium weight) use Arial Bold, which looks the same at these sizes.
                family=["Arial", "DejaVu Sans"] if t.get("bold") else ["Helvetica", "Arial", "DejaVu Sans"],
                fontweight="bold" if t.get("bold") else "normal",
                ha="left", va="baseline", zorder=zorder + 1,
                clip_on=True)  # matplotlib doesn't clip text by default; without this, labels spill into
                               # neighboring panels when several zoomed views share one figure

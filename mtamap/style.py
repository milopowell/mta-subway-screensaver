"""Styling + cropping for the interpreted MTA diagram: black background (dark theme) or the paper map's own colors
(light theme)."""
import numpy as np
from matplotlib.path import Path
from matplotlib.patches import PathPatch

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


def cropped(lo, hi):
    return lo[1] >= TITLE_Y - 1 or (lo[0] >= LEGEND[0] and lo[1] >= LEGEND[1])


def prepare(drawing):
    """Annotate every record with bbox info and collect yellow route bullets."""
    for p in drawing["paths"]:
        p["lo"], p["hi"] = bbox(p["segs"])
        p["curves"] = any(k == "C" for k, _ in p["segs"])
    # A white stroke immediately followed by a colored stroke along the same path is a "casing":
    # the thin white outline that separates parallel route lines on the white paper map.
    paths = drawing["paths"]
    for i, p in enumerate(paths):
        p["casing"] = False
        s = p["stroke"]
        if s is not None and is_neutral(s) and lum(s[:3]) > 0.93 and p["fill"] is None:
            for q in paths[i + 1: i + 3]:
                if q["stroke"] is not None and q["segs"] == p["segs"] and q["lw"] < p["lw"]:
                    p["casing"] = True
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
    return bullets


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
            if is_station_circle(p) or inside_any(center, bullets):
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
        elif is_neutral(c) and lum(c) > 0.93 and (p["lw"] < 6 or p.get("casing")):
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
    if not clean_text(t["text"]).strip():
        return None
    if t["y"] >= TITLE_Y - 1 or (t["x"] >= LEGEND[0] and t["y"] >= LEGEND[1]) or (t["y"] > TITLE_Y - 20 and t["size"] > 15):
        return None
    c = t["color"]
    return (0, 0, 0) if c is None else tuple(min(1, max(0, x)) for x in c[:3])


def style_text(t, bullets):
    if not clean_text(t["text"]).strip():
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


def draw_official(ax, drawing, bullets, lw_scale, text_scale, zorder=0, theme="dark"):
    """Draw the map onto a matplotlib axis in page coordinates: black background (theme "dark") or the paper
    map's colors ("light")."""
    path_style, text_style = (style_path_light, style_text_light) if theme == "light" else (style_path, style_text)
    n = 0
    for p in drawing["paths"]:
        st = path_style(p, bullets)
        if st is None:
            continue
        fc, ec = st
        path = to_mpl_path(p["segs"])
        ax.add_patch(PathPatch(path, facecolor=fc if fc is not None else "none",
                               edgecolor=ec if ec is not None else "none",
                               lw=p["lw"] * lw_scale if ec is not None else 0,
                               zorder=zorder + n * 1e-6, capstyle="butt", joinstyle="miter"))
        n += 1
    for t in drawing["texts"]:
        c = text_style(t, bullets)
        if c is None:
            continue
        ax.text(t["x"], t["y"], clean_text(t["text"]), rotation=t["angle"], rotation_mode="anchor",
                fontsize=t["size"] * text_scale, color=c, family=["Helvetica", "Arial", "DejaVu Sans"],
                ha="left", va="baseline", zorder=zorder + 1,
                clip_on=True)  # matplotlib doesn't clip text by default; without this, labels spill into
                               # neighboring panels when several zoomed views share one figure

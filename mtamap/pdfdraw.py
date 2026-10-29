"""Interpret the MTA diagram PDF's content streams into simple path and text records (page coordinates)."""
import math
import re

from .pdfreader import PDF, parse_pdf_string

TOKEN = re.compile(
    rb"\s*(?:"
    rb"(?P<num>[+-]?(?:\d+\.?\d*|\.\d+))(?![\w.])"
    rb"|(?P<name>/[^\s/\[\]()<>{}%]*)"
    rb"|(?P<str>\()"
    rb"|(?P<hex><[0-9A-Fa-f\s]*>)"
    rb"|(?P<dopen><<)|(?P<dclose>>>)"
    rb"|(?P<aopen>\[)|(?P<aclose>\])"
    rb"|(?P<op>[A-Za-z'\"*][A-Za-z0-9'\"*]*)"
    rb"|(?P<comment>%[^\r\n]*)"
    rb")"
)


def tokens(data):
    i, n = 0, len(data)
    while i < n:
        m = TOKEN.match(data, i)
        if not m or m.end() == i:
            i += 1
            continue
        kind = m.lastgroup
        if kind == "str":
            j, depth = m.end(), 1
            while depth:
                c = data[j]
                if c == 0x5C:
                    j += 2
                    continue
                if c == 0x28:
                    depth += 1
                elif c == 0x29:
                    depth -= 1
                j += 1
            yield "str", parse_pdf_string(data[m.end(): j - 1])
            i = j
            continue
        if kind != "comment":
            yield kind, m.group(kind)
        i = m.end()


def mat_mul(a, b):
    """PDF matrices [a b c d e f]: returns a×b."""
    return [
        a[0] * b[0] + a[1] * b[2], a[0] * b[1] + a[1] * b[3],
        a[2] * b[0] + a[3] * b[2], a[2] * b[1] + a[3] * b[3],
        a[4] * b[0] + a[5] * b[2] + b[4], a[4] * b[1] + a[5] * b[3] + b[5],
    ]


def apply(m, x, y):
    return (m[0] * x + m[2] * y + m[4], m[1] * x + m[3] * y + m[5])


class Interpreter:
    def __init__(self, pdf):
        self.pdf = pdf
        self.paths = []  # dicts: pts list of subpaths [(code, [(x,y),...])], fill, stroke, lw, evenodd, tag
        self.texts = []  # dicts: x, y, angle, size, text, color, font
        self.colorspaces = {}

    # ---- resources ----
    def resources(self, dict_bytes):
        res = {"xobj": {}, "cs": {}}
        for key, target in [("XObject", "xobj"), ("ColorSpace", "cs")]:
            m = re.search(rb"/" + key.encode() + rb"\s*<<(.*?)>>", dict_bytes, re.S)
            if m:
                for nm, num in re.findall(rb"/(\w+)\s+(\d+)\s+0\s+R", m.group(1)):
                    res[target][nm.decode()] = int(num)
        return res

    def color_of(self, cs_num, comps):
        """Convert a colour in colour space object cs_num to RGB (0..1)."""
        if cs_num is None:
            return tuple(comps[:3]) if len(comps) >= 3 else (comps[0],) * 3
        d = self.pdf.dict_of(cs_num)
        if b"/Separation" in d:
            name = re.search(rb"/Separation/([^\s/\[]+)", d).group(1).decode().replace("#20", " ")
            c0 = list(map(float, re.search(rb"/C0\[([^\]]*)\]", d).group(1).split()))
            c1 = list(map(float, re.search(rb"/C1\[([^\]]*)\]", d).group(1).split()))
            t = comps[0] if comps else 1.0
            rgb = tuple(a + (b - a) * t for a, b in zip(c0, c1))
            return rgb + (name,)
        if b"/Pattern" in d:
            return None
        if len(comps) >= 3:
            return tuple(comps[:3])
        if len(comps) == 1:
            return (comps[0],) * 3
        if len(comps) == 4:  # CMYK
            c, m, y, k = comps
            return ((1 - c) * (1 - k), (1 - m) * (1 - k), (1 - y) * (1 - k))
        return (0, 0, 0)

    # ---- main loop ----
    def run(self, data, res, ctm, tag="page"):
        gs = {"ctm": ctm, "fill": (0, 0, 0), "stroke": (0, 0, 0), "lw": 1.0, "fcs": None, "scs": None,
              "Tc": 0, "Tw": 0, "Tz": 100, "TL": 0, "Tf": None, "Tfs": 1, "dash": None, "cap": 0}
        stack = []
        operands = []
        path = []
        cur = start = None
        tm = tlm = None
        label = None
        arr_stack = []
        for kind, val in tokens(data):
            if kind == "num":
                (arr_stack[-1] if arr_stack else operands).append(float(val))
                continue
            if kind in ("name",):
                (arr_stack[-1] if arr_stack else operands).append(val.decode("latin1"))
                continue
            if kind == "str":
                (arr_stack[-1] if arr_stack else operands).append(val)
                continue
            if kind == "hex":
                h = re.sub(rb"\s", b"", val[1:-1])
                (arr_stack[-1] if arr_stack else operands).append(bytes.fromhex(h.decode() + ("0" if len(h) % 2 else "")))
                continue
            if kind == "aopen":
                arr_stack.append([])
                continue
            if kind == "aclose":
                a = arr_stack.pop()
                (arr_stack[-1] if arr_stack else operands).append(a)
                continue
            if kind in ("dopen", "dclose"):
                continue
            op = val.decode("latin1")
            o = operands
            operands = []
            if op == "q":
                stack.append(dict(gs))
            elif op == "Q":
                gs = stack.pop() if stack else gs
            elif op == "cm":
                gs["ctm"] = mat_mul(o[-6:], gs["ctm"])
            elif op == "w":
                gs["lw"] = o[-1]
            elif op == "d":
                arr = o[-2] if len(o) >= 2 and isinstance(o[-2], list) else []
                gs["dash"] = (list(arr), o[-1]) if arr else None
            elif op == "J":
                gs["cap"] = int(o[-1])
            elif op == "cs":
                gs["fcs"] = res["cs"].get(o[-1].lstrip("/"))
            elif op == "CS":
                gs["scs"] = res["cs"].get(o[-1].lstrip("/"))
            elif op in ("sc", "scn"):
                nums = [x for x in o if isinstance(x, float)]
                gs["fill"] = self.color_of(gs["fcs"], nums)
            elif op in ("SC", "SCN"):
                nums = [x for x in o if isinstance(x, float)]
                gs["stroke"] = self.color_of(gs["scs"], nums)
            elif op == "g":
                gs["fill"], gs["fcs"] = (o[-1],) * 3, None
            elif op == "G":
                gs["stroke"], gs["scs"] = (o[-1],) * 3, None
            elif op == "rg":
                gs["fill"], gs["fcs"] = tuple(o[-3:]), None
            elif op == "RG":
                gs["stroke"], gs["scs"] = tuple(o[-3:]), None
            elif op == "k":
                gs["fill"] = tuple(((1 - o[-4]) * (1 - o[-1]), (1 - o[-3]) * (1 - o[-1]), (1 - o[-2]) * (1 - o[-1])))
            elif op == "K":
                gs["stroke"] = tuple(((1 - o[-4]) * (1 - o[-1]), (1 - o[-3]) * (1 - o[-1]), (1 - o[-2]) * (1 - o[-1])))
            # ---- path construction ----
            elif op == "m":
                cur = start = apply(gs["ctm"], o[-2], o[-1])
                path.append(("M", cur))
            elif op == "l":
                cur = apply(gs["ctm"], o[-2], o[-1])
                path.append(("L", cur))
            elif op == "c":
                p1, p2, p3 = (apply(gs["ctm"], o[-6 + i], o[-5 + i]) for i in (0, 2, 4))
                path.append(("C", (p1, p2, p3)))
                cur = p3
            elif op == "v":
                p2, p3 = (apply(gs["ctm"], o[-4 + i], o[-3 + i]) for i in (0, 2))
                path.append(("C", (cur, p2, p3)))
                cur = p3
            elif op == "y":
                p1, p3 = (apply(gs["ctm"], o[-4 + i], o[-3 + i]) for i in (0, 2))
                path.append(("C", (p1, p3, p3)))
                cur = p3
            elif op == "re":
                x, y, w, h = o[-4:]
                c = [apply(gs["ctm"], x, y), apply(gs["ctm"], x + w, y), apply(gs["ctm"], x + w, y + h), apply(gs["ctm"], x, y + h)]
                path += [("M", c[0]), ("L", c[1]), ("L", c[2]), ("L", c[3]), ("Z", None)]
                cur = start = c[0]
            elif op == "h":
                path.append(("Z", None))
                cur = start
            elif op in ("S", "s", "f", "F", "f*", "B", "B*", "b", "b*", "n"):
                if op in ("s", "b", "b*"):
                    path.append(("Z", None))
                if op != "n" and path:
                    fill = gs["fill"] if op in ("f", "F", "f*", "B", "B*", "b", "b*") else None
                    stroke = gs["stroke"] if op in ("S", "s", "B", "B*", "b", "b*") else None
                    scale = math.sqrt(abs(gs["ctm"][0] * gs["ctm"][3] - gs["ctm"][1] * gs["ctm"][2]))
                    dash = None
                    if gs["dash"] and stroke is not None:
                        dash = ([x * scale for x in gs["dash"][0]], gs["dash"][1] * scale)
                    self.paths.append({"segs": path, "fill": fill, "stroke": stroke, "lw": gs["lw"] * scale,
                                       "evenodd": op.endswith("*"), "tag": tag, "dash": dash, "cap": gs["cap"]})
                path = []
            elif op in ("W", "W*"):
                pass
            # ---- XObjects ----
            elif op == "Do":
                num = res["xobj"].get(o[-1].lstrip("/"))
                if num is not None:
                    d = self.pdf.dict_of(num)
                    if b"/Form" in d:
                        mm = re.search(rb"/Matrix\s*\[([^\]]*)\]", d)
                        mtx = list(map(float, mm.group(1).split())) if mm else [1, 0, 0, 1, 0, 0]
                        sub_res = self.resources(d)
                        # a form without its own colour spaces uses its parent's
                        for k, v in res["cs"].items():
                            sub_res["cs"].setdefault(k, v)
                        self.run(self.pdf.stream(num), sub_res, mat_mul(mtx, gs["ctm"]), tag=f"form{num}")
            # ---- text ----
            elif op == "BT":
                tm = tlm = [1, 0, 0, 1, 0, 0]
                label = None
                jumped = False
            elif op == "ET":
                tm = None
                label = None
            elif op == "Tf":
                gs["Tf"], gs["Tfs"] = o[-2], o[-1]
            elif op == "Tc":
                gs["Tc"] = o[-1]
            elif op == "Tw":
                gs["Tw"] = o[-1]
            elif op == "Tz":
                gs["Tz"] = o[-1]
            elif op == "TL":
                gs["TL"] = o[-1]
            elif op == "Tm":
                tm = tlm = o[-6:]
                label = None
            elif op in ("Td", "TD"):
                tx, ty = o[-2], o[-1]
                if op == "TD":
                    gs["TL"] = -ty
                tlm = mat_mul([1, 0, 0, 1, tx, ty], tlm)
                tm = tlm
                if label is not None and (abs(ty) > 1e-6 or tx < -0.1):
                    label = None  # a new line or a step back: start a new label
                elif label is not None and tx > 2.0:
                    jumped = True  # further along the same line: a new label, or the rest of a kerned word (Tj decides)
            elif op == "T*":
                tlm = mat_mul([1, 0, 0, 1, 0, -gs["TL"]], tlm)
                tm = tlm
                label = None
            elif op in ("Tj", "TJ", "'", '"'):
                if op in ("'", '"'):
                    tlm = mat_mul([1, 0, 0, 1, 0, -gs["TL"]], tlm)
                    tm = tlm
                    label = None
                parts = o[-1] if op == "TJ" else [o[-1]]
                s = ""
                for part in parts:
                    if isinstance(part, bytes):
                        s += part.decode("latin1")
                    elif isinstance(part, float) and part < -250:
                        s += " "
                trm = mat_mul([gs["Tfs"], 0, 0, gs["Tfs"], 0, 0], mat_mul(tm, gs["ctm"]))
                if label is not None and jumped and not continues(label, trm):
                    label = None
                jumped = False
                if label is None:
                    x, y = trm[4], trm[5]
                    label = {"x": x, "y": y, "angle": math.degrees(math.atan2(trm[1], trm[0])),
                             "size": math.hypot(trm[0], trm[1]), "text": "", "color": gs["fill"],
                             "font": gs["Tf"], "tag": tag}
                    self.texts.append(label)
                label["text"] += s
            # everything else (gs, d, j, J, M, BDC, EMC, ri, i, sh, ...) is ignored


# Approximate Helvetica advance widths (fraction of the font size), enough to tell where a label's text ends.
_NARROW, _WIDE = set("fijlrtI!.,:;'|()[]- "), set("mwMW@%")


def text_width(text):
    """Estimated width of `text` in Helvetica, in multiples of the font size."""
    return sum(0.28 if c in _NARROW else 0.85 if c in _WIDE else 0.67 if c.isupper() else 0.55 for c in text)


def continues(label, trm):
    """True if text placed at `trm` carries on `label`'s word on the same line: it starts within about one letter
    of where the label's text ends. The PDF sets some words in pieces to kern them ("Manha" + "ttan", "Astor P" +
    "l"); drawing the pieces separately with a substitute font leaves uneven gaps, so they are joined."""
    size = label["size"]
    ang = math.radians(label["angle"])
    dx, dy = trm[4] - label["x"], trm[5] - label["y"]
    along = dx * math.cos(ang) + dy * math.sin(ang)
    across = -dx * math.sin(ang) + dy * math.cos(ang)
    return abs(across) < 0.05 * size and abs(along - text_width(label["text"]) * size) < 1.0 * size


def interpret(path):
    pdf = PDF(path)
    page = [n for n, (d, s) in pdf.objs.items() if s is None and b"/Type/Page" in d and b"/Contents" in d][0]
    pd = pdf.dict_of(page)
    contents = [int(x) for x in re.findall(rb"(\d+) 0 R", re.search(rb"/Contents\[([^\]]*)\]", pd).group(1))]
    data = b"\n".join(pdf.stream(n) for n in contents)
    it = Interpreter(pdf)
    it.run(data, it.resources(pd), [1, 0, 0, 1, 0, 0])
    return it

"""ROBIN wordmark: upright, geometric caps where every cut and diagonal shares one angle.

Each chamfer is a cut of ANGLE degrees from the horizontal, so a cut that is
RUN units wide is RUN * tan(ANGLE) tall. The R's leg and the N's diagonal run
at the same angle, which keeps the whole word in one visual rhythm.
"""

import math

ANGLE = 60  # degrees from horizontal, shared by every cut and diagonal
TAN = math.tan(math.radians(ANGLE))
H = 200     # cap height
S = 46      # stem weight
BAR = 40    # horizontal stroke weight
CUT = 26    # horizontal run of the outer corner cuts
GAP = 24    # letter spacing


def rise(run):
    return run * TAN


def poly(pts):
    return "M" + " L".join(f"{round(x, 2):g} {round(y, 2):g}" for x, y in pts) + " Z"


def shift(pts, dx):
    return [(x + dx, y) for x, y in pts]


WEIGHT = 46                     # uniform stroke weight of the R and B


def inset(pts, distances):
    """Insets a convex polygon: edge i (pts[i] -> pts[i+1]) moves inward by
    distances[i]. Used to cut holes that leave every stroke equally thick."""
    n = len(pts)
    area = sum(pts[i][0] * pts[(i + 1) % n][1] - pts[(i + 1) % n][0] * pts[i][1] for i in range(n))
    sign = 1 if area > 0 else -1
    lines = []
    for i in range(n):
        (x0, y0), (x1, y1) = pts[i], pts[(i + 1) % n]
        dx, dy = x1 - x0, y1 - y0
        length = math.hypot(dx, dy)
        nx, ny = -dy / length * sign, dx / length * sign   # inward normal
        d = distances[i]
        lines.append(((x0 + nx * d, y0 + ny * d), (dx, dy)))
    out = []
    for i in range(n):
        (p, r), (q, t) = lines[i - 1], lines[i]
        denom = r[0] * t[1] - r[1] * t[0]
        u = ((q[0] - p[0]) * t[1] - (q[1] - p[1]) * t[0]) / denom
        out.append((p[0] + u * r[0], p[1] + u * r[1]))
    return out


def glyph_r():
    w = 140                      # bowl width (its hole matches the B's)
    yb = 120                     # bowl bottom
    leg = (H - yb) / TAN         # horizontal travel of the leg
    # The leg's right edge continues straight on from the end of the bowl's
    # lower cut, so leg and bowl meet without a step. Both right-hand corners
    # of the bowl are cut at the shared angle.
    foot = w - CUT + leg         # right end of the leg at the baseline
    outer = [(0, 0), (w - CUT, 0), (w, rise(CUT)), (w, yb - rise(CUT)), (w - CUT, yb), (foot, H), (foot - S, H),
             (w - CUT - S, yb), (S, yb), (S, H), (0, H)]
    bowl = [(0, 0), (w - CUT, 0), (w, rise(CUT)), (w, yb - rise(CUT)), (w - CUT, yb), (0, yb)]
    counter = inset(bowl, [WEIGHT] * len(bowl))
    return max(w, foot), [outer, counter]


def glyph_o():
    w = 150
    outer = [(CUT, 0), (w - CUT, 0), (w, rise(CUT)), (w, H - rise(CUT)), (w - CUT, H), (CUT, H), (0, H - rise(CUT)),
             (0, rise(CUT))]
    c = CUT * 0.55
    x0, x1, y0, y1 = S, w - S, BAR, H - BAR
    counter = [(x0 + c, y0), (x1 - c, y0), (x1, y0 + rise(c)), (x1, y1 - rise(c)), (x1 - c, y1), (x0 + c, y1),
               (x0, y1 - rise(c)), (x0, y0 + rise(c))]
    return w, [outer, counter]


def glyph_b():
    w = 140
    mid = H / 2
    notch = 14                   # depth of the waist notch, cut at the shared angle
    outer = [(0, 0), (w - CUT, 0), (w, rise(CUT)), (w, mid - rise(notch)), (w - notch, mid), (w, mid + rise(notch)),
             (w, H - rise(CUT)), (w - CUT, H), (0, H)]
    # Each hole is its bowl inset by the stroke weight; the bowls share the middle bar.
    upper = [(0, 0), (w - CUT, 0), (w, rise(CUT)), (w, mid - rise(notch)), (w - notch, mid), (0, mid)]
    lower = [(0, mid), (w - notch, mid), (w, mid + rise(notch)), (w, H - rise(CUT)), (w - CUT, H), (0, H)]
    top = inset(upper, [WEIGHT, WEIGHT, WEIGHT, WEIGHT, WEIGHT / 2, WEIGHT])
    bottom = inset(lower, [WEIGHT / 2, WEIGHT, WEIGHT, WEIGHT, WEIGHT, WEIGHT])
    return w, [outer, top, bottom]


def glyph_i():
    c = CUT * S / 60             # same angle; the run is limited by the stem
    return S, [[(0, rise(c)), (c, 0), (S, 0), (S, H), (0, H)]]


def glyph_n():
    travel = H / TAN             # horizontal travel of the diagonal
    w = travel + S
    y_right = (w - 2 * S) * TAN  # where the diagonal meets the right stem
    y_left = H - y_right         # where it meets the left stem
    outer = [(0, 0), (S, 0), (w - S, y_right), (w - S, 0), (w, 0), (w, H), (w - S, H), (S, y_left), (S, H), (0, H)]
    return w, [outer]


GLYPHS = {"R": glyph_r, "O": glyph_o, "B": glyph_b, "I": glyph_i, "N": glyph_n}
# Optical spacing: the R's leg reaches under the O's lower cut.
KERN = {"R": -14}


def word(text="ROBIN", gap=GAP):
    paths, x = [], 0.0
    for ch in text:
        width, polys = GLYPHS[ch]()
        paths += [poly(shift(p, x)) for p in polys]
        x += width + gap + KERN.get(ch, 0)
    return " ".join(paths), x - gap

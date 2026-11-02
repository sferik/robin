# Generates the Robin mascot, favicon, mono mark, logo and wordmark SVGs.
# Usage: python3 assets/source/build.py [output_dir]   (default: assets/)
#
# The mascot is a front-facing, symmetric low-poly robin in a hero pose:
# folded wings form a cape, a sharp domino mask with white lenses, a crest,
# and a cut ruby for the red breast. Seven flat colours, mirrored shading.
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from wordmark import word  # noqa: E402

OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
CX = 256

# Seven flat colours. Shading is mirrored left/right, so the mark is symmetric.
INK, INK_LIGHT, INK_DARK = "#232c3d", "#3a4660", "#151b27"
MASK, WHITE, AMBER = "#07090d", "#ffffff", "#f6a723"
RUBY, RUBY_LIGHT, RUBY_DARK = "#e0244a", "#ff6f86", "#a10d2c"


def poly(pts):
    return "M" + " L".join(f"{round(x, 1):g} {round(y, 1):g}" for x, y in pts) + " Z"


def P(pts, fill):
    return f'<path d="{poly(pts)}" fill="{fill}"/>'


def mirror(right_half):
    """Closes a symmetric outline from its right half (top to bottom, on or right of centre)."""
    return right_half + [(2 * CX - x, y) for x, y in reversed(right_half) if x != CX]


def pair(pts):
    """A shape on the right and its mirror image on the left."""
    return [pts, [(2 * CX - x, y) for x, y in pts]]


# -- geometry ------------------------------------------------------------------

HEAD = mirror([(256, 34), (284, 86), (322, 52), (326, 104), (364, 152), (370, 210), (340, 252), (256, 268)])
CREST = mirror([(256, 34), (284, 86), (322, 52), (326, 104), (256, 132)])
CHEEK = [(364, 152), (370, 210), (340, 252), (316, 196)]
CAPE = mirror([(256, 240), (350, 236), (398, 264), (418, 334), (412, 416), (392, 402), (384, 458), (360, 436),
               (338, 480), (300, 466), (256, 472)])
SHOULDER = [(350, 236), (398, 264), (418, 334), (366, 300)]
WING = [(418, 334), (412, 416), (392, 402), (384, 458), (360, 436), (338, 480), (366, 300)]
TAIL = [(228, 462), (256, 530), (284, 462)]
MASK_SHAPE = mirror([(256, 170), (292, 148), (340, 144), (392, 116), (376, 166), (344, 198), (298, 200),
                     (256, 186)])
LENS = [(270, 178), (328, 160), (352, 164), (334, 186), (286, 192)]
BEAK = [(256, 190), (276, 210), (256, 268), (236, 210)]


def leg(side):
    x0, s = CX + side * 30, side
    return [(x0 - 5, 460), (x0 + 5, 460), (x0 + 4, 500), (x0 + s * 22, 512), (x0 + s * 20, 518), (x0 + 2, 508),
            (x0, 520), (x0 - 2, 508), (x0 - s * 18, 518), (x0 - s * 20, 512), (x0 - 4, 500)]


def gem_outline(cx=256, cy=352, rx=96, ry=112, n=8):
    rot = -math.pi / 2 + math.pi / n
    return [(cx + rx * math.cos(rot + 2 * math.pi * i / n), cy + ry * math.sin(rot + 2 * math.pi * i / n))
            for i in range(n)]


def gem_table(outline, cx=256, cy=352, scale=0.5):
    return [(cx + (x - cx) * scale, cy + (y - cy) * scale) for x, y in outline]


# Crown facets from the upper right, clockwise: light on top, dark below,
# identical on both sides.
FACET_TONES = [RUBY, RUBY, RUBY_DARK, RUBY_DARK, RUBY_DARK, RUBY, RUBY, RUBY_LIGHT]


def gem():
    outline = gem_outline()
    table = gem_table(outline)
    out = [P([outline[i], outline[(i + 1) % 8], table[(i + 1) % 8], table[i]], FACET_TONES[i]) for i in range(8)]
    out.append(P(table, RUBY_LIGHT))
    return out


# -- mascot ----------------------------------------------------------------------

def mascot(keyline=26, legs=True):
    lower = ([P(TAIL, INK)] + [P(leg(s), AMBER) for s in (1, -1)]) if legs else []
    silhouette = lower + [P(CAPE, WHITE), P(HEAD, WHITE)]
    out = [
        "<!-- white keyline: invisible on light backgrounds, outlines the bird on dark ones -->",
        f'<g fill="{WHITE}" stroke="{WHITE}" stroke-width="{keyline}" stroke-linejoin="round">{"".join(silhouette)}</g>',
    ]
    out += lower
    out.append("<!-- folded wings as a cape -->")
    out += [P(CAPE, INK)] + [P(p, INK_LIGHT) for p in pair(SHOULDER)] + [P(p, INK_DARK) for p in pair(WING)]
    out.append("<!-- the red breast is a cut ruby -->")
    out += gem()
    out.append("<!-- head with a crest -->")
    out += [P(HEAD, INK), P(CREST, INK_LIGHT)] + [P(p, INK_DARK) for p in pair(CHEEK)]
    out.append("<!-- domino mask -->")
    out += [P(MASK_SHAPE, MASK)] + [P(p, WHITE) for p in pair(LENS)]
    out += [P(BEAK, AMBER)]
    return "\n  ".join(out)


def svg(viewbox, body, title="Robin"):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{viewbox}" role="img" aria-label="{title}">\n'
            f"  <title>{title}</title>\n  {body}\n</svg>\n")


def write(name, text):
    with open(os.path.join(OUT, name), "w") as fh:
        fh.write(text)


MASCOT_BOX = "64 16 384 532"

# 1. mascot
write("robin.svg", svg(MASCOT_BOX, mascot()))

# 2. favicon: whole bird without legs, heavier keyline
write("favicon.svg", svg("22 14 468 492", mascot(keyline=36, legs=False)))

# 3. one-colour mark (currentColor) with the details cut out
outline = gem_outline()
spokes = " ".join(f"M{round(a[0], 1):g} {round(a[1], 1):g} L{round(b[0], 1):g} {round(b[1], 1):g}"
                  for a, b in zip(outline, gem_table(outline)))
mono = f'''<defs>
    <mask id="robin-cut" maskUnits="userSpaceOnUse" x="0" y="0" width="512" height="560">
      <rect width="512" height="560" fill="#fff"/>
      <path d="{poly(outline)}" fill="none" stroke="#000" stroke-width="10" stroke-linejoin="round"/>
      <path d="{poly(gem_table(outline))}" fill="none" stroke="#000" stroke-width="7" stroke-linejoin="round"/>
      <path d="{spokes}" stroke="#000" stroke-width="6"/>
      <path d="{poly(pair(LENS)[0])}" fill="#000"/>
      <path d="{poly(pair(LENS)[1])}" fill="#000"/>
      <path d="{poly(BEAK)}" fill="none" stroke="#000" stroke-width="9" stroke-linejoin="round"/>
      <path d="M146 300 L174 480 M366 300 L338 480" stroke="#000" stroke-width="9"/>
    </mask>
  </defs>
  <g fill="currentColor" mask="url(#robin-cut)">
    <path d="{poly(CAPE)}"/><path d="{poly(HEAD)}"/><path d="{poly(TAIL)}"/>
    <path d="{poly(leg(1))}"/><path d="{poly(leg(-1))}"/>
  </g>'''
write("robin-mono.svg", svg(MASCOT_BOX, mono))

# 4. wordmark: ruby red reads on both light and dark backgrounds
d, width = word()
wordmark_body = f'<path d="{d}" fill="{RUBY}" fill-rule="evenodd"/>'
write("robin-wordmark.svg", svg(f"-6 -6 {width + 12:.0f} 212", wordmark_body))

# 5. logo: mascot + wordmark, wordmark centred on the mascot's head/chest
scale = 0.78
logo = (f'<g transform="translate(0 0)">\n  {mascot()}\n  </g>\n'
        f'  <g transform="translate(470 196) scale({scale})"><path d="{d}" fill="{RUBY}" fill-rule="evenodd"/></g>')
write("robin-logo.svg", svg(f"64 16 {470 + width * scale - 64 + 24:.0f} 532", logo))

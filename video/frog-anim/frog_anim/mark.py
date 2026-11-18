"""The locked mark: its colours and the geometry constants the sprite is drawn in.

Everything here is copied from the mascot's sources of truth and checked against them by
tests/test_mark.py when run inside the frog repo:

- colours: design/tokens.json `mark-skin`, `mark-spot`, `mark-ink`, `mark-paper`
- the smile: the flattened path in apps/web/public/frog-mark.svg (its `M411.6 584.4 ...` path)
- the grid: the mark's 1024 grid (the SVG's pre-transform units, FrogKit's `FrogMark`)

Do not edit these to restyle the frog; the mark is locked."""
from __future__ import annotations

from typing import NamedTuple

RGB = tuple[int, int, int]


def hex_rgb(h: str) -> RGB:
    """'#51da60' -> (81, 218, 96)."""
    h = h.lstrip("#")
    if len(h) != 6:
        raise ValueError(f"expected #rrggbb, got {h!r}")
    return (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16))


class Palette(NamedTuple):
    """The frog's colours. The first four are the locked mark tokens; `well`, `edge` and `fg` are
    Frog's dark UI tokens, used only by the `carry` pose's chip."""
    skin: RGB = (0x51, 0xDA, 0x60)   # mark-skin
    spot: RGB = (0x36, 0xB3, 0x47)   # mark-spot
    ink: RGB = (0x15, 0x17, 0x1A)    # mark-ink
    paper: RGB = (0xFB, 0xFB, 0xF9)  # mark-paper
    well: RGB = (0x1A, 0x1A, 0x1A)
    edge: RGB = (0x38, 0x38, 0x38)
    fg: RGB = (0xEC, 0xEC, 0xEC)


MARK = Palette()
TOKENS = {"mark-skin": MARK.skin, "mark-spot": MARK.spot, "mark-ink": MARK.ink, "mark-paper": MARK.paper}

# The sprite canvas, in the mark's grid units: x -260..1284, y 60..1640 (room for the body).
X0, Y0, CW, CH = -260, 60, 1544, 1580
# The head: an ellipse centred (512, 568), rx 296, ry 224 on top and 234 below (the SVG's
# `M216 568 A296 224 ... A296 234 ...`, FrogKit's `silhouette`): (cx, cy, rx, ry_top, ry_bottom).
HEAD = (512, 568, 296, 224, 234)
HEAD_W = 592          # the head ellipse's width (216..808): `size`/`head_px` is this many pixels
FEET = (512, 1195)    # where the full-body frog rests (between its feet)
HEAD_FEET = (512, 802)  # the head's bottom centre: the head-only anchor, FrogKit's `FrogMark.feet`
PUPILS = ((360, 344), (664, 344))
PUPIL_R = 68
# FrogKit's FrogMark.box: the square the apps fit the head into (704 units, from (160, 200)).
APP_BOX = (160, 200, 704, 704)
# FrogKit's frown: the smile flipped about its middle and dropped 18, y -> 1194 - y.
FROWN_FLIP = 1194

# The smile polygon, verbatim from frog-mark.svg (116 points, grid units).
SMILE: tuple[tuple[float, float], ...] = (
    (411.6, 584.4), (415.5, 587.1), (419.6, 589.8), (423.7, 592.3), (427.8, 594.8), (431.9, 597.1),
    (436.1, 599.3), (440.2, 601.4), (444.4, 603.4), (448.5, 605.3), (452.7, 607.0), (456.9, 608.6),
    (461.1, 610.2), (465.3, 611.6), (469.5, 612.9), (473.7, 614.0), (477.9, 615.1), (482.2, 616.0),
    (486.4, 616.8), (490.7, 617.5), (494.9, 618.0), (499.2, 618.4), (503.5, 618.8), (507.7, 618.9),
    (512.0, 619.0), (516.3, 618.9), (520.5, 618.8), (524.8, 618.4), (529.1, 618.0), (533.3, 617.5),
    (537.6, 616.8), (541.8, 616.0), (546.1, 615.1), (550.3, 614.0), (554.5, 612.9), (558.7, 611.6),
    (562.9, 610.2), (567.1, 608.6), (571.3, 607.0), (575.5, 605.3), (579.6, 603.4), (583.8, 601.4),
    (587.9, 599.3), (592.1, 597.1), (596.2, 594.8), (600.3, 592.3), (604.4, 589.8), (608.5, 587.1),
    (612.4, 584.4), (615.9, 581.2), (618.1, 577.1), (619.0, 572.5), (618.4, 567.8), (616.4, 563.6),
    (613.2, 560.1), (609.1, 557.9), (604.5, 557.0), (599.8, 557.6), (595.6, 559.6), (591.8, 562.1),
    (588.3, 564.5), (584.7, 566.7), (581.1, 568.8), (577.6, 570.8), (574.1, 572.7), (570.5, 574.5),
    (567.0, 576.2), (563.5, 577.7), (560.0, 579.2), (556.5, 580.6), (553.1, 581.8), (549.6, 583.0),
    (546.2, 584.0), (542.7, 585.0), (539.3, 585.8), (535.9, 586.6), (532.4, 587.2), (529.0, 587.8),
    (525.6, 588.2), (522.2, 588.6), (518.8, 588.8), (515.4, 589.0), (512.0, 589.0), (508.6, 589.0),
    (505.2, 588.8), (501.8, 588.6), (498.4, 588.2), (495.0, 587.8), (491.6, 587.2), (488.1, 586.6),
    (484.7, 585.8), (481.3, 585.0), (477.8, 584.0), (474.4, 583.0), (470.9, 581.8), (467.5, 580.6),
    (464.0, 579.2), (460.5, 577.7), (457.0, 576.2), (453.5, 574.5), (449.9, 572.7), (446.4, 570.8),
    (442.9, 568.8), (439.3, 566.7), (435.7, 564.5), (432.2, 562.1), (428.4, 559.6), (424.2, 557.6),
    (419.5, 557.0), (414.9, 557.9), (410.8, 560.1), (407.6, 563.6), (405.6, 567.8), (405.0, 572.5),
    (405.9, 577.1), (408.1, 581.2),
)

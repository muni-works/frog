"""The frog, as a full character, drawn in code.

The head is the mark itself (apps/web/public/frog-mark.svg): the same ellipse, eye bulges, pupils,
highlights, spots and smile, in the mark's own coordinates and colours. The body is new: a round
body with a pale belly, short arms, big hind legs with darker feet. Because it is drawn, not
pasted, it can blink, wink, look somewhere, hop and hold things.

sprite(head_px, pose, ...) -> (RGBA image, (ax, ay)): the anchor is where the frog rests (between
its feet), in image pixels. place() pastes it with that anchor at a point, squashed or turned."""
import re
from functools import lru_cache
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

HERE = Path(__file__).resolve().parent
SVG = (HERE.parent.parent / "apps/web/public/frog-mark.svg").read_text()
SKIN, SPOT, INK, PAPER = (0x51, 0xda, 0x60), (0x36, 0xb3, 0x47), (0x15, 0x17, 0x1a), (0xfb, 0xfb, 0xf9)
WELL, EDGE, FG = (0x1a, 0x1a, 0x1a), (0x38, 0x38, 0x38), (0xec, 0xec, 0xec)
# the smile, straight from the mark's path
_SMILE = [(float(x), float(y)) for x, y in re.findall(r"[ML]?\s*([\d.]+) ([\d.]+)", SVG.split('<path d="M411.6')[1].split('"')[0].join(["411.6", ""]))] if '<path d="M411.6' in SVG else []
if _SMILE and _SMILE[0] != (411.6, 584.4):
    _SMILE = [(411.6, 584.4)] + _SMILE

# canvas, in the mark's pre-transform units: x -260..1284, y 60..1640
X0, Y0, CW, CH = -260, 60, 1544, 1580
HEAD_W = 592  # the head ellipse's width in those units
SS = 2        # supersample


@lru_cache(256)
def sprite(head_px, pose="sit", blink=False, wink=False, look=(0, 0), label=None):
    s = head_px / HEAD_W * SS
    im = Image.new("RGBA", (int(CW * s), int(CH * s)), (0, 0, 0, 0)); d = ImageDraw.Draw(im)
    P = lambda x, y: ((x - X0) * s, (y - Y0) * s)
    def ell(cx, cy, rx, ry, fill): d.ellipse([*P(cx - rx, cy - ry), *P(cx + rx, cy + ry)], fill=fill)
    def limb(pts, w, fill=SKIN):
        d.line([P(*p) for p in pts], fill=fill, width=int(w * s), joint="curve")
        for p in pts: ell(p[0], p[1], w / 2, w / 2, fill)

    anchor = (512, 1195)
    if pose in ("sit", "wave", "carry"):
        limb([(380, 876), (402, 1118)], 77)
        if pose == "wave": limb([(660, 870), (900, 620)], 77); ell(915, 600, 62, 62, SKIN)
        elif pose == "sit": limb([(644, 876), (622, 1118)], 77)
        for sx in (-1, 1):
            ell(512 + sx * 242, 1041, 132, 99, SKIN)
            ell(512 + sx * 297, 1151, 121, 44, SPOT)
        ell(512, 920, 242, 220, SKIN)
        if pose == "carry":
            x0, y0, x1, y1 = 512 - 420, 850, 512 + 420, 1080
            d.rounded_rectangle([*P(x0, y0), *P(x1, y1)], radius=40 * s, fill=WELL, outline=EDGE, width=max(1, int(5 * s)))
            if label:
                f = ImageFont.truetype(str(HERE / "fonts" / "IBMPlexMono-Regular.otf"), max(8, int(104 * s)))
                d.text(P(512, 965), label, font=f, fill=FG, anchor="mm")
            ell(x0, 965, 66, 78, SKIN); ell(x1, 965, 66, 78, SKIN)
        else:
            ell(512, 964, 143, 143, PAPER)
    elif pose == "hop":  # stretched out, legs trailing, arms forward
        anchor = (512, 1560)
        for sx in (-1, 1):
            limb([(512 + sx * 88, 1130), (512 + sx * 170, 1330), (512 + sx * 130, 1500)], 80)
            ell(512 + sx * 130, 1520, 100, 40, SPOT)
            limb([(512 + sx * 132, 850), (512 + sx * 330, 690)], 77)
        ell(512, 950, 190, 268, SKIN)
        ell(512, 990, 112, 168, PAPER)
    elif pose == "head":
        anchor = (512, 802)

    # the head: the mark's own shapes
    d.ellipse([*P(216, 344), *P(808, 802)], fill=SKIN)
    for cx in (360, 664): ell(cx, 352, 120, 120, SKIN)
    for cx, cy, r in ((290, 469, 18), (262, 523, 11), (742, 463, 16), (772, 510, 10), (323, 541, 30), (701, 541, 30)):
        ell(cx, cy, r, r, SPOT)
    if _SMILE: d.polygon([P(*p) for p in _SMILE], fill=INK)
    lx, ly = look
    for i, cx in enumerate((360, 664)):
        shut = blink or (wink and i == 1)
        if shut:
            d.arc([*P(cx - 62, 320), *P(cx + 62, 400)], 200, 340, fill=INK, width=int(22 * s))
        else:
            ex, ey = cx + lx * 30, 344 + ly * 30
            ell(ex, ey, 68, 68, INK)
            ell(ex + 22, ey - 22, 22, 22, PAPER); ell(ex - 24, ey + 24, 9, 9, PAPER)
    im = im.resize((im.width // SS, im.height // SS), Image.LANCZOS)
    ax, ay = P(*anchor)
    return im, (ax / SS, ay / SS)


def place(img, spr, x, y, squash=1.0, rot=0.0, alpha=1.0, clip_y=None):
    """paste a sprite with its anchor at (x, y). squash < 1 flattens it onto its feet; rot turns
    it about the anchor (degrees, counter-clockwise); clip_y hides everything below that line."""
    im, (ax, ay) = spr
    if squash != 1.0:
        w, h = int(im.width / squash ** 0.5), int(im.height * squash)
        ax, ay = ax * w / im.width, ay * h / im.height
        im = im.resize((w, h), Image.BICUBIC)
    if rot:
        big = Image.new("RGBA", (im.width * 2, im.height * 2), (0, 0, 0, 0))
        big.paste(im, (int(im.width - ax), int(im.height - ay)))
        im = big.rotate(rot, Image.BICUBIC, center=(im.width, im.height)); ax, ay = im.width / 2, im.height / 2
    px, py = int(round(x - ax)), int(round(y - ay))
    if clip_y is not None:
        keep = max(0, min(im.height, int(clip_y - py)))
        im = im.crop((0, 0, im.width, keep))
    if alpha < 1:
        a = im.getchannel("A").point(lambda v: int(v * alpha)); im.putalpha(a)
    img.paste(im, (px, py), im)

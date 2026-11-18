"""The frog as a full character, drawn in code (moved from video/hype-reel/frog.py).

The head is the mark itself (apps/web/public/frog-mark.svg): the same eye bulges, pupils,
highlights, spots and smile, in the mark's own coordinates and colours (`mark.py`). The body
(round body, pale belly, short arms, big hind legs with darker feet) was drawn for the hype reel
and exists nowhere else in the brand yet.

`sprite(head_px, pose, ...)` returns (RGBA image, (ax, ay)): the anchor is where the frog rests
(between its feet, or the head's bottom centre for `pose="head"`), in image pixels. `place()`
pastes it with that anchor at a point, squashed, turned or moved.

The drawing code is the reel's, unchanged; every parameter added since is keyword-only with a
default that draws the reel's pixels."""
from __future__ import annotations

import os
from functools import lru_cache
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont, ImageOps

from .mark import CH, CW, HEAD_W, MARK, SMILE, X0, Y0, FROWN_FLIP, Palette
from .motion import Move

SS = 2  # supersample
POSES = ("sit", "wave", "carry", "hop", "head")
Sprite = tuple[Image.Image, tuple[float, float]]

_HERE = Path(__file__).resolve().parent
# The `carry` chip's label font: $FROG_ANIM_FONT, else IBM Plex Mono (the apps' mono) from the
# hype reel's fonts/ when this package sits in the frog repo, else Pillow's built-in font.
_FONT_CANDIDATES = (_HERE.parent.parent / "hype-reel" / "fonts" / "IBMPlexMono-Regular.otf",)


def default_font() -> str | None:
    env = os.environ.get("FROG_ANIM_FONT")
    if env: return env
    return next((str(p) for p in _FONT_CANDIDATES if p.exists()), None)


def _font(path: str | None, px: int) -> ImageFont.FreeTypeFont | ImageFont.ImageFont:
    if path: return ImageFont.truetype(path, px)
    return ImageFont.load_default(px)


@lru_cache(256)
def sprite(head_px: float, pose: str = "sit", blink: bool = False, wink: bool = False,
           look: tuple[float, float] = (0, 0), label: str | None = None, *,
           eyes: Move | None = None, frown: bool = False, palette: Palette = MARK,
           font: str | None = None, mirror: bool = False) -> Sprite:
    """Draw the frog.

    head_px: the head's width in pixels (the mark's head ellipse, 592 grid units).
    pose: "sit", "wave", "carry" (holding a chip with `label`), "hop" (stretched, in the air) or
        "head" (the mark alone: the apps' FrogFace framing).
    blink / wink: both eyes / the right eye shut, drawn as the reel's closed-eye arc.
    look: where the pupils look, each axis -1..1 (30 grid units at 1).
    eyes: FrogKit's eye move (squash and drift of the pupils and glints about each pupil
        centre), applied after `look`; rotation is ignored (no mood uses it).
    frown: turn the smile down, FrogKit's sad mouth (flipped about its middle, dropped 18).
    palette: the colours; the default is the locked mark tokens.
    font: a font file for the carry label (default: `default_font()`).
    mirror: flip left to right (the frog facing the other way).
    """
    if pose not in POSES:
        raise ValueError(f"unknown pose {pose!r}; poses: {', '.join(POSES)}")
    SKIN, SPOT, INK, PAPER = palette.skin, palette.spot, palette.ink, palette.paper
    WELL, EDGE, FG = palette.well, palette.edge, palette.fg
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
                f = _font(font if font is not None else default_font(), max(8, int(104 * s)))
                if not mirror:
                    d.text(P(512, 965), label, font=f, fill=FG, anchor="mm")
                else:  # drawn flipped (the canvas is symmetric about x 512), so the final flip rights it
                    lay = Image.new("RGBA", im.size, (0, 0, 0, 0))
                    ImageDraw.Draw(lay).text(P(512, 965), label, font=f, fill=FG, anchor="mm")
                    im.alpha_composite(ImageOps.mirror(lay)); d = ImageDraw.Draw(im)
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
    smile = [(x, FROWN_FLIP - y) for x, y in SMILE] if frown else SMILE
    d.polygon([P(*p) for p in smile], fill=INK)
    lx, ly = look
    for i, cx in enumerate((360, 664)):
        shut = blink or (wink and i == 1)
        if shut:
            d.arc([*P(cx - 62, 320), *P(cx + 62, 400)], 200, 340, fill=INK, width=int(22 * s))
        elif eyes is None:
            ex, ey = cx + lx * 30, 344 + ly * 30
            ell(ex, ey, 68, 68, INK)
            ell(ex + 22, ey - 22, 22, 22, PAPER); ell(ex - 24, ey + 24, 9, 9, PAPER)
        else:  # FrogKit's MarkCanvas: pupil and glints moved together about the pupil centre
            ex, ey = cx + lx * 30, 344 + ly * 30
            m = lambda gx, gy: (ex + eyes.tx + eyes.sx * gx, ey + eyes.ty + eyes.sy * gy)
            ell(*m(0, 0), 68 * eyes.sx, 68 * eyes.sy, INK)
            ell(*m(22, -22), 22 * eyes.sx, 22 * eyes.sy, PAPER); ell(*m(-24, 24), 9 * eyes.sx, 9 * eyes.sy, PAPER)
    im = im.resize((im.width // SS, im.height // SS), Image.LANCZOS)
    ax, ay = P(*anchor)
    ax, ay = ax / SS, ay / SS
    if mirror:
        im = ImageOps.mirror(im); ax = im.width - ax
    return im, (ax, ay)


def place(img: Image.Image, spr: Sprite, x: float, y: float, squash: float = 1.0, rot: float = 0.0,
          alpha: float = 1.0, clip_y: float | None = None, *, body: Move | None = None,
          unit: float = 1.0) -> None:
    """Paste a sprite with its anchor at (x, y).

    squash < 1 flattens it onto its feet (keeping its area); rot turns it about the anchor
    (degrees, counter-clockwise); clip_y hides everything below that line; alpha fades it.
    body: a FrogKit body move about the anchor (scale, then clockwise rotation, then a
        translation in grid units, `unit` pixels each), applied after squash.
    On an RGBA image the sprite is alpha-composited (correct edges on transparency); on RGB it
    is pasted through its own alpha, as the reel always did."""
    im, (ax, ay) = spr
    if squash != 1.0:
        w, h = int(im.width / squash ** 0.5), int(im.height * squash)
        ax, ay = ax * w / im.width, ay * h / im.height
        im = im.resize((w, h), Image.BICUBIC)
    if body is not None and not body.is_rest:
        if (body.sx, body.sy) != (1.0, 1.0):
            w, h = max(1, int(round(im.width * body.sx))), max(1, int(round(im.height * body.sy)))
            ax, ay = ax * w / im.width, ay * h / im.height
            im = im.resize((w, h), Image.BICUBIC)
        rot = rot - body.rotation
        x, y = x + body.tx * unit, y + body.ty * unit
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
    if img.mode == "RGBA":
        layer = Image.new("RGBA", img.size, (0, 0, 0, 0)); layer.paste(im, (px, py))
        img.alpha_composite(layer)
    else:
        img.paste(im, (px, py), im)

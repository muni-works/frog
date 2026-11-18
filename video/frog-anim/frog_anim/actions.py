"""Named actions: the frog as a pure function of time and a few parameters.

Two families share one entry point, `draw(img, name, t, ...)`:

- moods, FrogKit's `FrogFace` loops (idle, thinking, reading, working, done, waiting, sad), on
  the head alone by default, as the apps draw it, or on the full body;
- actions from the hype reel (sit, hop, hop-in, peek, wave, wink, carry, look), on the full
  body by default.

The two building blocks the reel itself calls, `rest()` and `hop()`, are the reel's `frog_at`
and `hop` (video/hype-reel/comp.py) without its beat clock: the caller says when it blinks."""
from __future__ import annotations

import math
import random
from dataclasses import dataclass, field
from typing import Callable

from PIL import Image

from .mark import HEAD_W, MARK, Palette
from .motion import MOODS, REST, Move, hop_path, periodic_blink, squash_at
from .sprite import place, sprite


# ---- the reel's two building blocks

def rest(img: Image.Image, t: float, x: float, y: float, size: float, pose: str = "sit",
         land: float | None = None, look: tuple[float, float] = (0, 0), wink: bool = False,
         label: str | None = None, blink: bool = False, clip_y: float | None = None,
         rot: float = 0.0, *, eyes: Move | None = None, frown: bool = False, body: Move | None = None,
         palette: Palette = MARK, font: str | None = None, mirror: bool = False) -> None:
    """The frog resting with its anchor at (x, y), `size` px head width. `land` is when it last
    touched down (for the squash). The reel's `frog_at`, with `blink` passed in."""
    sq = squash_at(t, land)
    if mirror and body is not None:  # facing left mirrors the body's sway and tilt too
        body = Move(-body.tx, body.ty, body.sx, body.sy, -body.rotation)
    spr = sprite(size, pose, blink=blink, wink=wink, look=look, label=label,
                 **_extra(eyes, frown, palette, font, mirror))
    place(img, spr, x, y, squash=sq, rot=rot, clip_y=clip_y, **({"body": body, "unit": size / HEAD_W} if body else {}))


def hop(img: Image.Image, t: float, t0: float, t1: float, p0: tuple[float, float], p1: tuple[float, float],
        size: float, height: float = 260, look: tuple[float, float] = (0, 0), pose_end: str = "sit",
        label: str | None = None, blink: bool = False, *, palette: Palette = MARK,
        font: str | None = None, mirror: bool = False) -> bool:
    """A hop from p0 to p1 between t0 and t1: in the air stretched and turned along the arc,
    then resting at p1 with a squash. Before t0 nothing is drawn (returns False).
    `blink` applies once it has landed. The reel's `hop`."""
    if t < t0: return False
    if t >= t1:
        rest(img, t, p1[0], p1[1], size, pose_end, land=t1, look=look, label=label, blink=blink,
             palette=palette, font=font, mirror=mirror)
        return True
    x, y, rot, dx = hop_path(t, t0, t1, p0, p1, height)
    lx = 0.4 * (1 if dx > 0 else -1 if dx < 0 else 0) if dx else 0
    if mirror: lx = -lx  # the sprite is flipped after drawing; keep it looking where it goes
    spr = sprite(size, "hop", look=(lx, -0.5), **_extra(None, False, palette, font, mirror))
    place(img, spr, x, y + size * 0.9, rot=rot)
    return True


def _extra(eyes, frown, palette, font, mirror) -> dict:
    """Only the non-default keyword arguments, so the reel's calls hit the same sprite cache
    entries and draw the same pixels as before."""
    kw = {}
    if eyes is not None: kw["eyes"] = eyes
    if frown: kw["frown"] = True
    if palette != MARK: kw["palette"] = palette
    if font is not None: kw["font"] = font
    if mirror: kw["mirror"] = True
    return kw


# ---- named actions

@dataclass(frozen=True)
class Ctx:
    """Everything an action needs to draw one frame. (x, y) is where the frog rests (its anchor:
    between the feet, or the head's bottom centre for the head-only body), size the head width
    in px, room the canvas height (for actions that enter from below or above)."""
    x: float
    y: float
    size: float
    room: float
    body: str = "full"          # "full" or "head"
    facing: str = "right"       # "right" (as drawn) or "left" (mirrored)
    palette: Palette = MARK
    label: str | None = None
    font: str | None = None
    phase: float = 0.0          # seconds added to t (from --seed), so frogs don't sync

    @property
    def mirror(self) -> bool: return self.facing == "left"

    @property
    def pose(self) -> str: return "head" if self.body == "head" else "sit"


@dataclass(frozen=True)
class Action:
    name: str
    loop: float                 # seconds: a render this long loops seamlessly
    doc: str
    draw: Callable[[Image.Image, float, Ctx], None] = field(repr=False)
    kind: str = "action"        # "action" (from the reel) or "mood" (FrogKit)
    body: str = "full"          # default body


BLINK = periodic_blink(3.2, 0.13)  # the reel blinks for 0.3 beat every 8 beats; ~3.3 s at 145 BPM


def _mood(name: str) -> Callable[[Image.Image, float, Ctx], None]:
    mood = MOODS[name]
    def draw(img: Image.Image, t: float, c: Ctx) -> None:
        body, eyes = mood.pose(t + c.phase)
        rest(img, t, c.x, c.y, c.size, c.pose, eyes=eyes, frown=mood.frown, body=body,
             palette=c.palette, mirror=c.mirror)
    return draw


def _sit(img, t, c):
    rest(img, t, c.x, c.y, c.size, c.pose, blink=BLINK(t + c.phase), palette=c.palette, mirror=c.mirror)


def _wave(img, t, c):
    rest(img, t, c.x, c.y, c.size, "head" if c.body == "head" else "wave", look=(0.3, -0.1),
         blink=BLINK(t + c.phase), palette=c.palette, mirror=c.mirror)


def _wink(img, t, c):
    """sits, and winks for 0.4 s once a loop (the reel's last beat)."""
    f = (t + c.phase) % 2.4
    rest(img, t, c.x, c.y, c.size, c.pose, wink=1.4 <= f < 1.8, palette=c.palette, mirror=c.mirror)


def _carry(img, t, c):
    """holds a chip (a file name, a model) and glances up at it, as when it catches CLAUDE.md."""
    f = (t + c.phase) % 3.2
    look = (0, -0.6) if f < 1.6 else (0, 0)
    pose = "head" if c.body == "head" else "carry"
    rest(img, t, c.x, c.y, c.size, pose, look=look, label=c.label or "CLAUDE.md",
         blink=BLINK(t + c.phase), palette=c.palette, font=c.font, mirror=c.mirror)


LOOKS = ((0, 0), (0.9, 0.0), (0.9, -0.1), (-0.8, 0.0), (0, -0.6), (0, 0.8), (-0.7, -0.6))


def _look(img, t, c):
    """looks at the things it looks at in the reel, one place every 0.6 s."""
    i = int((t + c.phase) / 0.6) % len(LOOKS)
    rest(img, t, c.x, c.y, c.size, c.pose, look=LOOKS[i], blink=BLINK(t + c.phase), palette=c.palette, mirror=c.mirror)


HOP_T0, HOP_T1 = 0.3, 0.82  # take-off and landing in a 1.6 s loop: the reel's "just hopped in" (0.52 s)


def _hop(img, t, c):
    """hops in place: up, stretched, and back down with a squash, once a loop."""
    f = (t + c.phase) % 1.6
    if c.body == "head":  # the head alone can't stretch out; it rides FrogKit's done hop instead
        body, _ = MOODS["done"].pose(f / 1.6 * 2.4 * 0.4)
        rest(img, t, c.x, c.y, c.size, "head", body=body, palette=c.palette, mirror=c.mirror)
        return
    if f < HOP_T0:
        rest(img, f, c.x, c.y, c.size, "sit", land=HOP_T1 - 1.6, palette=c.palette, mirror=c.mirror)
        return
    if f >= HOP_T1:
        rest(img, f, c.x, c.y, c.size, "sit", land=HOP_T1, palette=c.palette, mirror=c.mirror)
        return
    # in the air: the reel's stretched pose, but with its feet on the arc (the reel's hop() hangs
    # them 0.9 head below it, fine for entrances from off-screen, not for a hop in place)
    x, y, rot, _ = hop_path(f, HOP_T0, HOP_T1, (c.x, c.y), (c.x, c.y), c.size * 0.45)
    place(img, sprite(c.size, "hop", look=(0, -0.5), **_extra(None, False, c.palette, None, c.mirror)), x, y, rot=rot)


def _hop_in(img, t, c):
    """hops in from off the edge behind it and lands with a squash (the reel's entrances).
    Plays once: 0.25 s empty, the hop, then it sits. The flight leans into the hop and
    straightens to land (the reel's hop() leans along the arc, which on a small canvas pushes
    its head off the far side at touchdown)."""
    t0, t1 = 0.25, 0.25 + 0.42
    if t < t0: return
    if t >= t1:
        rest(img, t, c.x, c.y, c.size, "sit", land=t1, blink=BLINK(t + c.phase), palette=c.palette, mirror=c.mirror)
        return
    way = -1 if c.mirror else 1
    start = (-c.size * 1.2, c.y) if not c.mirror else (2 * c.x + c.size * 1.2, c.y)
    x, y, _, _ = hop_path(t, t0, t1, start, (c.x, c.y), c.size * 0.4)
    k = (t - t0) / (t1 - t0)
    rot = -way * 30 * math.sin(math.pi * k)  # PIL turns counter-clockwise: lean forward
    place(img, sprite(c.size, "hop", look=(0.4, -0.5), **_extra(None, False, c.palette, None, c.mirror)), x, y, rot=rot)


def _peek(img, t, c):
    """the head rises over the bottom edge, looks up and left, and ducks back (the reel's open)."""
    f = (t + c.phase) % 3.0
    k = min(1.0, f / 0.5) if f < 2.2 else max(0.0, 1 - (f - 2.2) / 0.5)
    from .motion import ease
    k = ease(k)
    if k <= 0: return
    y = c.room + c.size * 1.1 - c.size * 1.03 * k
    rest(img, t, c.x, y, c.size, "head", look=(-0.7, -0.6), palette=c.palette, mirror=c.mirror)


ACTIONS: dict[str, Action] = {a.name: a for a in (
    Action("sit", 3.2, "sits and blinks", _sit),
    Action("hop", 1.6, "hops in place, squashes on landing", _hop),
    Action("hop-in", 1.2, "hops in from the side and lands (plays once)", _hop_in),
    Action("peek", 3.0, "head rises over the bottom edge, looks, ducks", _peek, body="head"),
    Action("wave", 3.2, "waves (the reel's 'own' shot)", _wave),
    Action("wink", 2.4, "sits and winks", _wink),
    Action("carry", 3.2, "holds a chip with --label and glances at it", _carry),
    Action("look", 4.2, "looks around: right, up, down, left", _look),
    *(Action(m.name, m.loop, m.doc, _mood(m.name), kind="mood", body="head") for m in MOODS.values()),
)}


def seed_phase(seed: int | None, loop: float) -> float:
    """A deterministic time offset for `seed` (None -> 0): several frogs with different seeds
    blink and breathe out of step. Uses random.Random(seed), never hash()."""
    return 0.0 if seed is None else random.Random(seed).uniform(0, loop)


def draw(img: Image.Image, name: str, t: float, ctx: Ctx) -> None:
    """Draw action or mood `name` at t seconds onto img (RGB or RGBA)."""
    if name not in ACTIONS:
        raise KeyError(f"unknown action {name!r}; try: {', '.join(ACTIONS)}")
    ACTIONS[name].draw(img, t, ctx)

"""Time: easing, keyframe tracks, and the apps' mood loops.

Two sources, kept apart:

- `ease`, `seg`, `lerp`, `squash_at` and `hop_path` come from the hype reel's compositor
  (video/hype-reel/comp.py), unchanged, so the reel renders the same through this package.
- `Move`, `Ease`, `Track` and `MOODS` are FrogKit's `FrogFace` motion
  (apps/FrogKit/UI/Basics/FrogFace.swift: `Move`, `Ease`, `Track`, `FrogPose`), transcribed as
  data, so a video frog and the apps' activity frog share one motion vocabulary. Keep them in
  step with the Swift when its keyframes change.

Everything is a pure function of time."""
from __future__ import annotations

from dataclasses import dataclass
from typing import Callable, Sequence

import numpy as np


# ---- the reel's curve and helpers (comp.py, from the board video)

def ease(x: float) -> float:
    """cubic-bezier(0.2, 0, 0, 1), the reel's one curve."""
    x = min(1.0, max(0.0, x)); lo, hi = 0.0, 1.0
    if x in (0.0, 1.0): return x
    for _ in range(18):
        u = (lo + hi) / 2
        if 3 * (1 - u) ** 2 * u * 0.2 + u ** 3 < x: lo = u
        else: hi = u
    return u ** 3


def seg(t: float, a: float, b: float) -> float:
    """0 before a, 1 after b, linear between."""
    return min(1.0, max(0.0, (t - a) / (b - a)))


def lerp(a: float, b: float, k: float) -> float:
    return a + (b - a) * k


def squash_at(t: float, land: float | None) -> float:
    """The landing squash: 1 at rest, 0.76 at touchdown, springing back with a 13/s decay."""
    return float(1.0 if land is None or t < land else 1 - 0.24 * np.exp(-(t - land) * 13))


def hop_path(t: float, t0: float, t1: float, p0: tuple[float, float], p1: tuple[float, float],
             height: float) -> tuple[float, float, float, float]:
    """Where a hop from p0 to p1 (t0..t1, apex `height` px above the line) is at t, as
    (x, y, rot_degrees, dx). rot turns the stretched frog along the arc, clamped to +-70."""
    k = (t - t0) / (t1 - t0)
    x = lerp(p0[0], p1[0], k); y = lerp(p0[1], p1[1], k) - height * 4 * k * (1 - k)
    dx = p1[0] - p0[0]; dy = (p1[1] - p0[1]) - height * 4 * (1 - 2 * k)
    rot = float(np.degrees(np.arctan2(-dx, -dy))) if abs(dx) > 1 else 0.0
    return x, y, max(-70, min(70, rot)), dx


# ---- FrogKit's motion (FrogFace.swift)

@dataclass(frozen=True)
class Move:
    """A CSS-style 2D move, as FrogKit's `Move`: translate (mark grid units), scale, and rotate
    (degrees, clockwise on screen), applied as translate . rotate . scale about a pivot."""
    tx: float = 0.0
    ty: float = 0.0
    sx: float = 1.0
    sy: float = 1.0
    rotation: float = 0.0

    def mix(self, to: "Move", f: float) -> "Move":
        m = lambda a, b: a + (b - a) * f
        return Move(m(self.tx, to.tx), m(self.ty, to.ty), m(self.sx, to.sx), m(self.sy, to.sy),
                    m(self.rotation, to.rotation))

    @property
    def is_rest(self) -> bool:
        return self == REST


REST = Move()


@dataclass(frozen=True)
class Ease:
    """A CSS cubic-bezier timing function (FrogKit's `Ease`)."""
    x1: float
    y1: float
    x2: float
    y2: float

    def __call__(self, x: float) -> float:
        def bez(s: float, a: float, b: float) -> float:
            u = 1 - s
            return 3 * u * u * s * a + 3 * u * s * s * b + s * s * s
        lo, hi = 0.0, 1.0
        for _ in range(24):
            s = (lo + hi) / 2
            if bez(s, self.x1, self.x2) < x: lo = s
            else: hi = s
        return bez((lo + hi) / 2, self.y1, self.y2)


EASE = Ease(0.25, 0.1, 0.25, 1)
IN_OUT = Ease(0.42, 0, 0.58, 1)
OUT = Ease(0, 0, 0.58, 1)


@dataclass(frozen=True)
class Track:
    """A looping keyframe track: stops at fractions of `period`, each with the easing of the
    segment leaving it. `alternate` plays every other loop backwards (CSS alternate)."""
    period: float
    stops: tuple[tuple[float, Move, Ease], ...]
    alternate: bool = False

    def at(self, t: float) -> Move:
        p = max(t, 0) / self.period
        f = p % 1
        if self.alternate and int(p) % 2 == 1: f = 1 - f
        i = max((j for j, s in enumerate(self.stops) if s[0] <= f), default=None)
        if i is None or i + 1 >= len(self.stops):
            return self.stops[-1][1] if self.stops else REST
        (a_at, a_move, a_ease), (b_at, b_move, _) = self.stops[i], self.stops[i + 1]
        local = (f - a_at) / (b_at - a_at) if b_at > a_at else 1
        return a_move.mix(b_move, a_ease(local))


def _track(period: float, stops: Sequence[tuple[float, Move, Ease]], alternate: bool = False) -> Track:
    return Track(period, tuple(stops), alternate)


BREATHE = _track(3.2, [(0, REST, IN_OUT), (0.5, Move(sx=1.012, sy=0.982), IN_OUT), (1, REST, IN_OUT)])
PUMP = _track(1.1, [(0, REST, IN_OUT), (0.45, Move(sx=1.05, sy=0.94), IN_OUT), (1, REST, IN_OUT)])


def blink_track(period: float) -> Track:
    """FrogKit's blink: the pupils squash to 8% tall near the end of each period."""
    return _track(period, [(0, REST, EASE), (0.92, REST, EASE), (0.95, Move(sy=0.08), EASE), (1, REST, EASE)])


PONDER = _track(4, [
    (0, Move(tx=22, ty=-44, sy=0.8), IN_OUT), (0.33, Move(tx=44, ty=-30, sy=0.8), IN_OUT),
    (0.66, Move(tx=-10, ty=-48, sy=0.8), IN_OUT), (1, Move(tx=22, ty=-44, sy=0.8), IN_OUT)])
SCAN = _track(2.4, [
    (0, Move(tx=-46, ty=12), EASE), (0.25, Move(tx=-16, ty=12), EASE),
    (0.5, Move(tx=16, ty=12), EASE), (0.75, Move(tx=46, ty=12), EASE),
    (0.88, Move(tx=-46, ty=22), EASE), (1, Move(tx=-46, ty=12), EASE)])
HOP = _track(2.4, [
    (0, REST, OUT),
    (0.08, Move(sx=1.1, sy=0.86), Ease(0.2, 0.8, 0.3, 1)),
    (0.20, Move(ty=-120, sx=0.94, sy=1.08), Ease(0.6, 0, 0.8, 0.4)),
    (0.31, Move(sx=1.12, sy=0.84), OUT),
    (0.36, Move(sx=0.98, sy=1.02), EASE),
    (0.40, REST, OUT), (1, REST, OUT)])
TILT = _track(1.8, [(0, Move(rotation=-7), IN_OUT), (0.5, Move(rotation=7), IN_OUT), (1, Move(rotation=-7), IN_OUT)])
WIDE = _track(1.8, [(0, Move(sx=1.12, sy=1.12), IN_OUT), (0.5, Move(sx=1.04, sy=1.04), IN_OUT),
                    (1, Move(sx=1.12, sy=1.12), IN_OUT)])
DROOP = _track(3, [(0, Move(ty=14, sy=0.5), IN_OUT), (1, Move(ty=18, sy=0.42), IN_OUT)], alternate=True)
SINK = _track(3, [(0, REST, IN_OUT), (1, Move(ty=12), IN_OUT)], alternate=True)


@dataclass(frozen=True)
class Mood:
    """One of FrogKit's moods: a body track (about the feet), an eye track (about each pupil),
    whether the smile turns down, and the loop length (seconds) a render should last to loop."""
    name: str
    body: Track | None
    eyes: Track | None
    frown: bool
    loop: float
    doc: str

    def pose(self, t: float) -> tuple[Move, Move]:
        """(body move, eye move) t seconds into the mood (FrogKit's `FrogPose`)."""
        return (self.body.at(t) if self.body else REST, self.eyes.at(t) if self.eyes else REST)


MOODS: dict[str, Mood] = {m.name: m for m in (
    Mood("idle", BREATHE, blink_track(5), False, 16.0, "breathes and blinks"),
    Mood("thinking", BREATHE, PONDER, False, 16.0, "looks up and drifts"),
    Mood("reading", None, SCAN, False, 2.4, "scans a line, left to right"),
    Mood("working", PUMP, blink_track(3.3), False, 3.3, "pumps its throat, blinks"),
    Mood("done", HOP, None, False, 2.4, "hops once a loop"),
    Mood("waiting", TILT, WIDE, False, 1.8, "tilts its head, wide eyes"),
    Mood("sad", SINK, DROOP, True, 6.0, "droops and sinks, smile turned down"),
)}

Clock = Callable[[float], bool]


def periodic_blink(period: float, length: float, at: float = 0.75, phase: float = 0.0) -> Clock:
    """A blink clock for the reel-style closed-eye arc: shut for `length` seconds once every
    `period`, starting `at` (a fraction) into each period, offset by `phase` seconds."""
    def shut(t: float) -> bool:
        f = ((t - phase) / period) % 1
        return at <= f < at + length / period
    return shut

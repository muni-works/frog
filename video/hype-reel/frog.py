"""The reel's frog, now drawn by the shared animator in video/frog-anim (frog_anim).

This shim keeps the reel's names: `sprite(head_px, pose, ...)` and `place(...)` are the package's,
with the carry chip's label in the reel's IBM Plex Mono."""
import sys
from functools import lru_cache
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "frog-anim"))
from frog_anim import place, sprite as _sprite  # noqa: E402
from frog_anim.actions import hop as _hop, rest as _rest  # noqa: E402

FONT = str(HERE / "fonts" / "IBMPlexMono-Regular.otf")
__all__ = ["sprite", "place", "rest", "hop"]


@lru_cache(256)
def sprite(head_px, pose="sit", blink=False, wink=False, look=(0, 0), label=None):
    return _sprite(head_px, pose, blink=blink, wink=wink, look=look, label=label, font=FONT)


def rest(*a, **kw): return _rest(*a, font=FONT, **kw)
def hop(*a, **kw): return _hop(*a, font=FONT, **kw)

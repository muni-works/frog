"""Frames and files: lay the frog out on a canvas, render an action's frames, encode them.

`frames(...)` yields PIL images (RGBA on a transparent canvas, RGB on a colour); `write(...)`
encodes them by the output's extension: .mp4, .webm, .mov, .gif, .apng, a single .png, or a
directory of numbered PNGs. Video encoding pipes raw frames to ffmpeg's stdin; nothing is
written to temporary files and nothing opens a window."""
from __future__ import annotations

import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Iterator

from PIL import Image

from .actions import ACTIONS, Ctx, draw, seed_phase
from .mark import MARK, RGB, Palette

# How much room the frog needs, in head widths (`size`), for every action of a body to fit
# without clipping: height above the anchor (the full body's hop is the tallest), below it, and
# width. One layout per body keeps the frog the same size whatever it is doing.
ROOM = {"full": (2.75, 0.1, 1.9), "head": (1.2, 0.05, 1.3)}
MARGIN = 0.12

FORMATS = {
    ".mp4": "mp4", ".m4v": "mp4", ".webm": "webm", ".mov": "mov", ".gif": "gif",
    ".apng": "apng", ".png": "png",
}
ALPHA_FORMATS = {"webm", "mov", "gif", "apng", "png", "frames"}


@dataclass(frozen=True)
class Layout:
    width: int
    height: int
    size: float   # head width, px
    x: float      # anchor
    y: float


def layout(width: int, height: int, body: str = "full", *, size: float | None = None,
           x: float | None = None, y: float | None = None, zoom: float = 1.0) -> Layout:
    """Where the frog goes on a width x height canvas: centred, feet near the bottom, as big as
    fits every action of that body. Any of size (head width px), x, y can be given instead."""
    up, down, wide = ROOM[body]
    fit = min(height / (up + down + 2 * MARGIN), width / (wide + 2 * MARGIN)) * zoom
    s = float(size) if size else fit
    return Layout(width, height, s, width / 2 if x is None else x,
                  height - (down + MARGIN) * s if y is None else y)


def frame_count(seconds: float, fps: float) -> int:
    return max(1, int(round(seconds * fps)))


def render_frame(action: str, t: float, lay: Layout, *, body: str | None = None, facing: str = "right",
                 background: RGB | None = None, palette: Palette = MARK, seed: int | None = None,
                 label: str | None = None, font: str | None = None) -> Image.Image:
    """One frame of `action` at t seconds: RGBA (transparent) if background is None, else RGB."""
    a = ACTIONS[action]
    ctx = Ctx(lay.x, lay.y, lay.size, lay.height, body or a.body, facing, palette, label, font,
              seed_phase(seed, a.loop))
    img = Image.new("RGBA", (lay.width, lay.height), (0, 0, 0, 0)) if background is None \
        else Image.new("RGB", (lay.width, lay.height), background)
    draw(img, action, t, ctx)
    return img


def frames(action: str, seconds: float, fps: float, lay: Layout, **kw) -> Iterator[Image.Image]:
    """Every frame of `seconds` of `action` at `fps` (frame i is at t = i / fps)."""
    for i in range(frame_count(seconds, fps)):
        yield render_frame(action, i / fps, lay, **kw)


def format_of(out: Path) -> str:
    """The output format from a path: a known extension, else a directory of PNG frames."""
    if out.suffix.lower() in FORMATS: return FORMATS[out.suffix.lower()]
    if out.suffix == "" or out.is_dir(): return "frames"
    raise ValueError(f"don't know how to write {out.suffix!r}; use one of {', '.join(sorted(FORMATS))} or a directory")


def _ffmpeg_args(fmt: str, w: int, h: int, fps: float, alpha: bool, out: Path) -> list[str]:
    src = ["-f", "rawvideo", "-pix_fmt", "rgba" if alpha else "rgb24", "-s", f"{w}x{h}", "-r", f"{fps:g}", "-i", "-"]
    if fmt == "mp4":
        enc = ["-c:v", "libx264", "-crf", "17", "-preset", "slow", "-pix_fmt", "yuv420p", "-movflags", "+faststart"]
    elif fmt == "webm":
        enc = ["-c:v", "libvpx-vp9", "-b:v", "0", "-crf", "28", "-row-mt", "1",
               *(["-pix_fmt", "yuva420p", "-auto-alt-ref", "0"] if alpha else ["-pix_fmt", "yuv420p"])]
    elif fmt == "mov":
        enc = ["-c:v", "prores_ks", "-profile:v", "4444" if alpha else "3",
               "-pix_fmt", "yuva444p10le" if alpha else "yuv422p10le", "-vendor", "apl0"]
    elif fmt == "gif":
        pal = "palettegen=reserve_transparent=1:stats_mode=full" if alpha else "palettegen=stats_mode=full"
        use = "paletteuse=alpha_threshold=128:dither=none" if alpha else "paletteuse=dither=none"
        enc = ["-filter_complex", f"split[a][b];[a]{pal}[p];[b][p]{use}", "-loop", "0"]
    elif fmt == "apng":
        enc = ["-c:v", "apng", "-pix_fmt", "rgba" if alpha else "rgb24", "-plays", "0", "-f", "apng"]
    else:
        raise ValueError(fmt)
    return ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", *src, *enc, str(out)]


def write(out: Path, imgs: Iterable[Image.Image], fmt: str, fps: float, size: tuple[int, int],
          alpha: bool) -> int:
    """Encode frames to `out` as `fmt`; returns the number of frames written."""
    w, h = size
    if fmt == "mp4" and alpha:
        raise ValueError("mp4 has no alpha: use --background, or .webm/.mov/.gif/.apng/PNGs for transparency")
    if fmt == "mp4" and (w % 2 or h % 2):
        raise ValueError(f"mp4 (yuv420p) needs even dimensions, got {w}x{h}")
    if fmt == "png":
        n = 0
        for im in imgs:
            im.save(out); n += 1
        return n
    if fmt == "frames":
        out.mkdir(parents=True, exist_ok=True)
        n = 0
        for n, im in enumerate(imgs, 1):
            im.save(out / f"{n - 1:04d}.png", compress_level=6)
        return n
    if not shutil.which("ffmpeg"):
        raise RuntimeError("ffmpeg not found on PATH (needed for video and GIF output)")
    proc = subprocess.Popen(_ffmpeg_args(fmt, w, h, fps, alpha, out), stdin=subprocess.PIPE)
    n = 0
    try:
        for im in imgs:
            proc.stdin.write(im.tobytes()); n += 1
    finally:
        proc.stdin.close()
        if proc.wait() != 0:
            raise RuntimeError(f"ffmpeg failed writing {out}")
    return n

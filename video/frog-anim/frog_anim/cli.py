"""frog-anim: render the Frog mascot in motion to a file.

  frog-anim list
  frog-anim render --action hop --size 512 --seconds 2 --fps 30 --out hop.mp4
  frog-anim render --action thinking --size 256 --transparent --out thinking.webm
  frog-anim render --action wave --size 1024 --at 0.5 --out wave.png
  frog-anim sheet --out sheet.png
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from PIL import Image, ImageDraw

from .actions import ACTIONS
from .mark import MARK, Palette, hex_rgb
from .render import ALPHA_FORMATS, format_of, frame_count, frames, layout, render_frame, write


def _palette(tokens: str | None) -> Palette:
    """The mark colours, from a tokens.json (design/tokens.json's shape) or the built-in lock."""
    if not tokens: return MARK
    rows = mark_tokens(json.loads(Path(tokens).read_text()))
    if not rows: raise SystemExit(f"{tokens}: no mark-* colours found")
    pick = lambda k, d: hex_rgb(rows[k]) if k in rows else d
    return MARK._replace(skin=pick("mark-skin", MARK.skin), spot=pick("mark-spot", MARK.spot),
                         ink=pick("mark-ink", MARK.ink), paper=pick("mark-paper", MARK.paper))


def mark_tokens(data: object) -> dict[str, str]:
    """Every {"css": "mark-…", "dark": "#…"} row anywhere in a tokens.json, as css -> hex."""
    found: dict[str, str] = {}
    if isinstance(data, dict):
        if str(data.get("css", "")).startswith("mark-") and "dark" in data:
            found[data["css"]] = data["dark"]
        for v in data.values(): found.update(mark_tokens(v))
    elif isinstance(data, list):
        for v in data: found.update(mark_tokens(v))
    return found


def cmd_list(_: argparse.Namespace) -> int:
    for kind, title in (("action", "actions (from the hype reel; full body by default)"),
                        ("mood", "moods (FrogKit's FrogFace; head only by default)")):
        print(title)
        for a in ACTIONS.values():
            if a.kind == kind:
                print(f"  {a.name:<9} {a.loop:>5.1f} s  {a.doc}")
        print()
    print("bodies: full, head    facing: right, left")
    print("outputs: .mp4 .webm .mov .gif .apng .png (still) or a directory (PNG frames)")
    return 0


def cmd_render(a: argparse.Namespace) -> int:
    out = Path(a.out)
    fmt = format_of(out)
    if a.transparent and a.background:
        raise SystemExit("--transparent and --background are exclusive")
    if a.transparent and fmt not in ALPHA_FORMATS:
        raise SystemExit(f"{out.suffix} has no alpha channel: use .webm, .mov, .gif, .apng, .png or a directory")
    bg = None if a.transparent else hex_rgb(a.background) if a.background else (None if fmt in ALPHA_FORMATS else (0, 0, 0))
    w, h = a.width or a.size, a.height or a.size
    act = ACTIONS[a.action]
    body = a.body or act.body
    lay = layout(w, h, body, size=a.frog_size, x=a.x, y=a.y, zoom=a.zoom)
    kw = dict(body=body, facing=a.facing, background=bg, palette=_palette(a.tokens), seed=a.seed,
              label=a.label, font=a.font)
    if fmt == "png":
        render_frame(a.action, a.at, lay, **kw).save(out)
        n = 1
    else:
        seconds = a.seconds if a.seconds is not None else act.loop
        n = write(out, frames(a.action, seconds, a.fps, lay, **kw), fmt, a.fps, (w, h), bg is None)
    print(f"{out}  {fmt}  {w}x{h}  {n} frame{'s' if n != 1 else ''}  {'alpha' if bg is None else 'opaque'}")
    return 0


def contact_sheet(names: list[str], cell: int = 192, cols: int = 6, body: str | None = None,
                  background=(0, 0, 0), label_rgb=(0x58, 0xCC, 0x6F)) -> Image.Image:
    """One row per action: `cols` frames evenly through its loop, with its name."""
    rows = []
    for name in names:
        act = ACTIONS[name]
        b = body or act.body
        lay = layout(cell, cell, b)
        row = Image.new("RGB", (cell * cols, cell + 22), background)
        for i in range(cols):
            t = act.loop * i / cols
            row.paste(render_frame(name, t, lay, body=b, background=background), (i * cell, 22))
        ImageDraw.Draw(row).text((6, 4), f"{name}  ({b} body, {act.loop:g} s loop, {cols} frames across it)",
                                 fill=label_rgb)
        rows.append(row)
    sheet = Image.new("RGB", (cell * cols, sum(r.height for r in rows)), background)
    y = 0
    for r in rows:
        sheet.paste(r, (0, y)); y += r.height
    return sheet


def cmd_sheet(a: argparse.Namespace) -> int:
    names = a.actions.split(",") if a.actions else list(ACTIONS)
    for n in names:
        if n not in ACTIONS: raise SystemExit(f"unknown action {n!r}")
    contact_sheet(names, a.cell, a.cols, a.body).save(a.out, optimize=True)
    print(a.out)
    return 0


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="frog-anim", description="Render the Frog mascot in motion.")
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("list", help="list actions and moods").set_defaults(fn=cmd_list)

    r = sub.add_parser("render", help="render an action to a file")
    r.add_argument("--action", required=True, choices=list(ACTIONS))
    r.add_argument("--out", required=True, help="output: .mp4 .webm .mov .gif .apng .png, or a directory for PNG frames")
    r.add_argument("--size", type=int, default=512, help="canvas width and height, px (default 512)")
    r.add_argument("--width", type=int, help="canvas width, px (overrides --size)")
    r.add_argument("--height", type=int, help="canvas height, px (overrides --size)")
    r.add_argument("--seconds", type=float, help="length (default: the action's loop)")
    r.add_argument("--fps", type=float, default=30)
    r.add_argument("--at", type=float, default=0.0, help="time of the frame for a .png still (s)")
    r.add_argument("--transparent", action="store_true", help="transparent background (not for .mp4)")
    r.add_argument("--background", help="background colour, #rrggbb (default: transparent where the format allows, else black)")
    r.add_argument("--body", choices=["full", "head"], help="full body or the head (mark) alone (default: per action)")
    r.add_argument("--facing", choices=["right", "left"], default="right", help="left mirrors the frog")
    r.add_argument("--seed", type=int, help="offsets the loops in time, so several frogs don't move in step")
    r.add_argument("--label", help="the chip's text for --action carry (default CLAUDE.md)")
    r.add_argument("--font", help="font file for the carry label (default: IBM Plex Mono if found)")
    r.add_argument("--frog-size", type=float, help="head width in px (default: as big as fits)")
    r.add_argument("--zoom", type=float, default=1.0, help="scale the fitted frog")
    r.add_argument("--x", type=float, help="anchor x, px (default: centre)")
    r.add_argument("--y", type=float, help="anchor y, px: where the feet rest (default: near the bottom)")
    r.add_argument("--tokens", help="read the mark-* colours from a tokens.json (default: the locked mark)")
    r.set_defaults(fn=cmd_render)

    s = sub.add_parser("sheet", help="a contact sheet: a row of frames per action")
    s.add_argument("--out", required=True)
    s.add_argument("--actions", help="comma-separated (default: all)")
    s.add_argument("--cell", type=int, default=192)
    s.add_argument("--cols", type=int, default=6)
    s.add_argument("--body", choices=["full", "head"])
    s.set_defaults(fn=cmd_sheet)
    return p


def main(argv: list[str] | None = None) -> int:
    a = parser().parse_args(argv)
    try:
        return a.fn(a)
    except (ValueError, RuntimeError) as e:
        print(f"frog-anim: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())

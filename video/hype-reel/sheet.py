#!/usr/bin/env python3
"""Render the frames at the given beats through comp.py and tile them into a contact sheet.

usage: sheet.py <out.png> [beat,beat,...]      (default: one per shot, plus mid-shot frames)"""
import subprocess, sys
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont
from beats import CUT, FPS, B, END_BEATS, NFRAMES

HERE = Path(__file__).resolve().parent
out = Path(sys.argv[1])
if len(sys.argv) > 2: beats = [float(b) for b in sys.argv[2].split(",")]
else:
    starts = sorted(CUT.values()) + [END_BEATS]
    beats = sorted({s + 1.5 for s in starts[:-1]} | {(a + b) / 2 + 1 for a, b in zip(starts, starts[1:])})
frames = [min(int(round(B(b) * FPS)), NFRAMES - 1) for b in beats]
tmp = HERE / "build" / "sheet_frames"
subprocess.run([sys.executable, str(HERE / "comp.py"), str(tmp), ",".join(map(str, frames))], check=True)
cols = 4; tw, th = 480, 270; rows = (len(frames) + cols - 1) // cols
sheet = Image.new("RGB", (cols * tw, rows * th))
font = ImageFont.truetype(str(HERE / "fonts" / "IBMPlexMono-Regular.otf"), 14)
for i, (b, f) in enumerate(zip(beats, frames)):
    im = Image.open(tmp / f"{f:04d}.png").resize((tw, th), Image.LANCZOS)
    ImageDraw.Draw(im).text((6, th - 20), f"beat {b:g} · {f / FPS:.1f} s", fill=(88, 204, 111), font=font)
    sheet.paste(im, ((i % cols) * tw, (i // cols) * th))
sheet.save(out)
print(out)

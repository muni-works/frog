#!/usr/bin/env python3
"""Composite the Frog hype reel, frame by frame. Every animated quantity is a pure function of
the time t, so any frame renders alone (contact sheets, re-rendering one shot).

usage: comp.py <out_dir> [frame,frame,...]

Footage: footage/ (web frames from capture/run.sh, 2560x1440) and the Mac app's checked-in
snapshots under docs/design/. Look: Frog's own tokens (design/tokens.json, dark): true black,
#ececec text, the frog green #58cc6f as the one accent, IBM Plex Sans and Mono."""
import json, os, sys
from functools import lru_cache
from multiprocessing import Pool
from pathlib import Path
import numpy as np
from PIL import Image, ImageDraw, ImageFont, ImageFilter
from beats import ASK, B, BEAT, CUT, DUR, FPS, JUMP, NFRAMES, OPTIONS, W, H
from frog import rest, hop as _hop  # the shared animator, video/frog-anim
from frog_anim import ease, seg, lerp

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
FOOT = HERE / "footage"
OUT = Path(sys.argv[1]) if len(sys.argv) > 1 else HERE / "build" / "frames"

# ---- Frog's tokens (design/tokens.json, dark)
def _hex(h): return tuple(int(h[i:i + 2], 16) for i in (1, 3, 5))
CANVAS, CARD, WELL = _hex("#000000"), _hex("#121212"), _hex("#1a1a1a")
FG, MUTED, FAINT = _hex("#ececec"), _hex("#a3a3a3"), _hex("#808080")
FROG, LINE = _hex("#58cc6f"), _hex("#2a2a2a")
FONTS = HERE / "fonts"
@lru_cache(None)
def sans(sz, bold=True): return ImageFont.truetype(str(FONTS / ("IBMPlexSans-SemiBold.otf" if bold else "IBMPlexSans-Regular.otf")), sz)
@lru_cache(None)
def mono(sz, bold=False): return ImageFont.truetype(str(FONTS / ("IBMPlexMono-SemiBold.otf" if bold else "IBMPlexMono-Regular.otf")), sz)

# ---- time helpers: ease, seg, lerp come from frog_anim (the board video's, unchanged)
def shot_of(t):
    names = sorted(CUT, key=CUT.get)
    cur = names[0]
    for n in names:
        if t >= B(CUT[n]): cur = n
    return cur

# ---- footage
@lru_cache(64)
def load(rel):
    p = FOOT / rel if not rel.startswith("docs/") else ROOT / rel
    return Image.open(p).convert("RGB")
def web(shot, i):
    n = len(list((FOOT / shot).glob("*.png")))
    return load(f"{shot}/{min(max(0, i), n - 1):04d}.png")

def view(img, cx, cy, z, out=(W, H)):
    """the camera: a window on img with out's aspect, centred at (cx, cy), z=1 the widest that
    fits. Cropped from the full-resolution source, so punch-ins stay sharp."""
    sw, sh = img.size; ow, oh = out
    rw = min(sw, sh * ow / oh) / z; rh = rw * oh / ow
    x0 = min(max(cx - rw / 2, 0), sw - rw); y0 = min(max(cy - rh / 2, 0), sh - rh)
    return img.resize(out, Image.LANCZOS, box=(x0, y0, x0 + rw, y0 + rh)), (x0, y0, rw / ow)

def to_screen(cam, x, y):
    x0, y0, s = cam
    return (x - x0) / s, (y - y0) / s

def scrim(img, where, depth=420, strength=1.0):
    """a black gradient so words over footage read: from the top or the bottom edge."""
    a = np.zeros((H, 1), np.float32)
    ramp = np.clip((depth - np.arange(depth)) / (depth * 0.5), 0, 1) ** 1.5 * strength  # solid for the first half
    if where == "top": a[:depth, 0] = ramp
    else: a[H - depth:, 0] = ramp[::-1]
    arr = np.asarray(img, np.float32) * (1 - a[..., None])
    return Image.fromarray(arr.astype(np.uint8))

def dim(img, k):
    return Image.fromarray((np.asarray(img, np.float32) * (1 - k)).astype(np.uint8))

# ---- the grid and the type scale: one system for every scene.
# A 12-column grid, 120 px margins, 140 px columns. Everything is flush left on a column edge.
# Type: IBM Plex Sans. Title 88 semibold, two lines (the claim, then its point in green), set
# solid; sub 42 regular, one line below; labels in Plex Mono 30. Nothing is centred.
MARGIN, COL = 120, 140
def col(i): return MARGIN + i * COL
TITLE, SUB, LABEL = 88, 42, 30
TITLE_Y, TITLE_LEAD, SUB_GAP = 176, 96, 76  # first baseline, line step, last line to sub baseline

def words(img, t, t0, parts, where="top", size=TITLE, x=MARGIN, sub=None, t1=None):
    """the title: each part is a line, flush left, landing whole on its beat; green marks the
    point. The sub sits one fixed step below the last line."""
    if t < t0 or (t1 is not None and t >= t1): return
    k = ease(seg(t, t0, t0 + 0.2))
    f = sans(size)
    lay = Image.new("RGBA", (W, H), (0, 0, 0, 0)); d = ImageDraw.Draw(lay)
    y = TITLE_Y + (1 - k) * 20
    for text, green in parts:
        d.text((x, y), text.strip(), font=f, fill=(FROG if green else FG) + (255,), anchor="ls")
        y += TITLE_LEAD
    if sub:
        d.text((x, y - TITLE_LEAD + SUB_GAP), sub, font=sans(SUB, False), fill=MUTED + (255,), anchor="ls")
    a = np.asarray(lay).copy(); a[..., 3] = (a[..., 3] * k).astype(np.uint8)
    img.paste(Image.fromarray(a), (0, 0), Image.fromarray(a))

def ring(img, box, t, t0, color=FROG):
    """a green outline drawn round something on screen, fading in."""
    k = ease(seg(t, t0, t0 + 0.3))
    if k <= 0: return
    lay = Image.new("RGBA", (W, H), (0, 0, 0, 0)); d = ImageDraw.Draw(lay)
    x0, y0, x1, y1 = box; g = 10 * (1 - k)
    d.rounded_rectangle([x0 - g, y0 - g, x1 + g, y1 + g], radius=14, outline=color + (int(255 * k),), width=4)
    img.paste(lay, (0, 0), lay)

def cursor(img, x, y, press=0.0):
    """a plain pointer; press 0..1 shrinks it a touch and puts a ring under it."""
    lay = Image.new("RGBA", (W, H), (0, 0, 0, 0)); d = ImageDraw.Draw(lay)
    if press > 0:
        r = 20 + 50 * press
        d.ellipse([x - r, y - r, x + r, y + r], outline=FROG + (int(220 * (1 - press)),), width=5)
    s = 1.6 * (1 - 0.12 * np.sin(np.pi * min(1, press * 2)) if press > 0 else 1.6)
    pts = [(0, 0), (0, 26), (7, 20), (12, 31), (17, 29), (12, 18), (21, 18)]
    poly = [(x + px * s, y + py * s) for px, py in pts]
    d.polygon(poly, fill=(255, 255, 255, 255), outline=(0, 0, 0, 255))
    d.line(poly + [poly[0]], fill=(0, 0, 0, 255), width=2)
    img.paste(lay, (0, 0), lay)

def punch(t, t0, amt=0.05):
    """a short zoom kick on a drop."""
    return 1 + amt * np.exp(-max(0.0, t - t0) * 9) if t >= t0 else 1.0

@lru_cache(4)
def mark(size):
    m = Image.open(FOOT / "mark.png").convert("RGBA")
    return m.resize((size, int(size * m.height / m.width)), Image.LANCZOS)

def paste_center(img, im, cx, cy, alpha=1.0):
    if im.mode != "RGBA": im = im.convert("RGBA")
    if alpha < 1:
        a = np.asarray(im).copy(); a[..., 3] = (a[..., 3] * alpha).astype(np.uint8); im = Image.fromarray(a)
    img.paste(im, (int(cx - im.width / 2), int(cy - im.height / 2)), im)

# ---- layout
LABELS = {"mine": "01  Your Mac", "pair": "02  Your machines", "swarm": "03  Agents", "how": "04  The pool",
          "price": "05  Frog Cloud", "setup": "06  Your setup", "own": "07  Yours"}
PAD = (0x1c, 0x4f, 0x27)
NOTICE, NOTICE_BG, WARN = _hex("#ff9f0a"), (0x2a, 0x1f, 0x0c), _hex("#e5775f")

def hud(img, name):
    """the section label, bottom left: the one thing that carries across the cuts."""
    if name not in LABELS: return
    d = ImageDraw.Draw(img)
    n, label = LABELS[name].split("  ")
    d.text((120, 1062), n, font=mono(24, True), fill=FROG, anchor="ls")
    d.text((120 + 52, 1062), label, font=mono(24), fill=FAINT, anchor="ls")

def glow(img, lay, r=18, k=1.0):
    """blur-and-add glow from a drawn layer. Used once: the bench numbers."""
    g = lay.filter(ImageFilter.GaussianBlur(r))
    arr = np.asarray(img, np.float32) + np.asarray(g, np.float32)[..., :3] * (np.asarray(g, np.float32)[..., 3:] / 255) * 0.9 * k
    img.paste(Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8)))
    img.paste(lay, (0, 0), lay)

def on_beat(t, b0, n, every=1.0):
    """how many of n steps have landed by t, one every `every` beats from beat b0."""
    return max(0, min(n, int((t - B(b0)) / (BEAT * every)) + 1)) if t >= B(b0) else 0

class Pond:
    """pads and ripples, drawn at 2x and scaled down so their edges are smooth."""
    def __init__(self): self.lay = Image.new("RGBA", (2 * W, 2 * H), (0, 0, 0, 0)); self.d = ImageDraw.Draw(self.lay)
    def pad(self, x, y, rx, out=False):
        ry = rx * 0.24; d = self.d
        if out:  # a machine that dropped out: an empty dashed outline
            for a in range(0, 360, 20): d.arc([2 * (x - rx), 2 * (y - ry), 2 * (x + rx), 2 * (y + ry)], a, a + 11, fill=WARN + (255,), width=6)
            return
        d.ellipse([2 * (x - rx), 2 * (y - ry), 2 * (x + rx), 2 * (y + ry)], fill=PAD + (255,), outline=_hex("#36b347") + (255,), width=5)
        d.polygon([(2 * x, 2 * y), (2 * (x + rx * 0.62), 2 * (y + ry * 1.05)), (2 * (x + rx * 0.80), 2 * (y + ry * 0.80))], fill=(0, 0, 0, 255))  # the lily pad's notch
    def ring(self, x, y, rx, alpha=1.0, width=3, ry=None):
        ry = rx * 0.24 if ry is None else ry
        self.d.ellipse([2 * (x - rx), 2 * (y - ry), 2 * (x + rx), 2 * (y + ry)], outline=FROG + (int(255 * max(0, min(1, alpha))),), width=2 * width)
    def onto(self, img):
        lay = self.lay.reduce(2); img.paste(lay, (0, 0), lay)

def pad_label(img, x, y, text, color=MUTED):
    ImageDraw.Draw(img).text((x, y), text, font=mono(30), fill=color, anchor="mt")

def splash(pond, t, t0, x, y, rx):
    """a ripple from a landing: two rings spreading for a beat and a half."""
    for j in range(2):
        k = seg(t, t0 + j * 0.12, t0 + j * 0.12 + 1.5 * BEAT)
        if 0 < k < 1: pond.ring(x, y, rx * (1.05 + 0.5 * ease(k)), alpha=1 - k)

def blinking(t):
    f = ((t - B(0)) / BEAT) % 8
    return 6.0 <= f < 6.3

def frog_at(img, t, x, y, size, pose="sit", land=None, look=(0, 0), wink=False, label=None, blink=None, clip_y=None, rot=0.0):
    """the frog resting at (x, y); `land` is when it touched down, for the squash. Blinks on the beat grid."""
    rest(img, t, x, y, size, pose, land=land, look=look, wink=wink, label=label,
         blink=blinking(t) if blink is None else blink, clip_y=clip_y, rot=rot)

def hop(img, t, t0, t1, p0, p1, size, height=260, look=(0, 0), pose_end="sit", label=None):
    """a hop from p0 to p1 between t0 and t1: in the air stretched and turned along the arc,
    then resting at p1 with a squash. Before t0 nothing is drawn."""
    return _hop(img, t, t0, t1, p0, p1, size, height=height, look=look, pose_end=pose_end, label=label, blink=blinking(t))

def chip(img, cx, cy, text, alpha=1.0, rot=0.0, size=40, kind="well"):
    """a small labelled chip: a file the frog picks up, or the limit notice."""
    f = mono(size) if kind == "well" else sans(size)
    tw = int(f.getlength(text)); w, h = tw + 64, int(size * 2.1)
    c = Image.new("RGBA", (w, h), (0, 0, 0, 0)); d = ImageDraw.Draw(c)
    d.rounded_rectangle([0, 0, w - 1, h - 1], radius=16, fill=(WELL if kind == "well" else NOTICE_BG) + (255,), outline=(LINE if kind == "well" else NOTICE) + (255,), width=2)
    d.text((w / 2, h / 2), text, font=f, fill=(FG if kind == "well" else NOTICE) + (255,), anchor="mm")
    if rot: c = c.rotate(rot, Image.BICUBIC, expand=True)
    paste_center(img, c, cx, cy, alpha)

# ---- shots. Each draws the frame at time t; lt = seconds into the shot.
def s_open(t, lt):
    """the intro: you ask another agent what's up, and it has hit its usage limit. The frog hops
    in on "just hopped in", and on "I got options" the title turns."""
    img = Image.new("RGB", (W, H), CANVAS); d = ImageDraw.Draw(img)
    x0, y0, x1, y1 = col(0), 380, col(7), 960
    d.rounded_rectangle([x0, y0, x1, y1], radius=28, fill=CARD)
    # frame 0 already reads: a task, two steps done, a third under way
    d.text((x0 + 56, y0 + 84), "Fix the flaky upload test", font=sans(52), fill=FG, anchor="ls")
    stopped = t >= B(4)
    rows = [("Read the code", True), ("Found the bug", True), ("Writing the fix", False)]
    for i, (label, done) in enumerate(rows):
        ry = y0 + 164 + i * 70
        if done:
            d.ellipse([x0 + 56, ry - 22, x0 + 100, ry + 22], fill=FG)
            d.line([(x0 + 67, ry), (x0 + 75, ry + 9), (x0 + 90, ry - 9)], fill=CARD, width=5, joint="curve")
            d.text((x0 + 124, ry), label, font=sans(42, False), fill=MUTED, anchor="lm")
        else:
            tint = NOTICE if stopped else FG
            d.ellipse([x0 + 56, ry - 22, x0 + 100, ry + 22], outline=tint, width=4)
            d.text((x0 + 124, ry), label, font=sans(42), fill=tint, anchor="lm")
            bx, bw = x0 + 520, 400
            fill = min(0.62, 0.30 + 0.08 * on_beat(t, 0, 4))  # it creeps forward a beat at a time, then stops
            d.rounded_rectangle([bx, ry - 8, bx + bw, ry + 8], radius=8, fill=LINE)
            d.rounded_rectangle([bx, ry - 8, bx + bw * fill, ry + 8], radius=8, fill=tint)
    if t >= ASK:  # "What's poppin'?": your message, on the lyric
        k = ease(seg(t, ASK, ASK + 0.15)); f = sans(42); msg = "What's poppin'?"
        tw = d.textlength(msg, font=f)
        bx1, by0 = x1 - 56, y0 + 366 + (1 - k) * 16
        d.rounded_rectangle([bx1 - tw - 64, by0, bx1, by0 + 84], radius=42, fill=WELL)
        d.text((bx1 - 32 - tw / 2, by0 + 42), msg, font=f, fill=FG, anchor="mm")
    if stopped:  # beat 4: the answer
        k = ease(seg(t, B(4), B(4) + 0.15))
        ax0, ay0, ax1, ay1 = x0 + 56, y1 - 120 + (1 - k) * 16, x1 - 56, y1 - 32 + (1 - k) * 16
        d.rounded_rectangle([ax0, ay0, ax1, ay1], radius=18, fill=NOTICE_BG, outline=NOTICE, width=2)
        d.text((ax0 + 30, ay0 + 44), "Usage limit reached", font=sans(40), fill=NOTICE, anchor="lm")
        if t < B(6):
            d.text((ax1 - 30, ay0 + 44), "Resets in 4 h 12 min", font=sans(34, False), fill=MUTED, anchor="rm")
        else:
            f = sans(32); label = "Buy extra usage  $$$"; tw = d.textlength(label, font=f)
            d.rounded_rectangle([ax1 - tw - 70, ay0 + 14, ax1 - 22, ay0 + 74], radius=30, fill=NOTICE)
            d.text((ax1 - 46 - tw / 2, ay0 + 44), label, font=f, fill=(0x1a, 0x12, 0x02), anchor="mm")
    if stopped and t < OPTIONS: words(img, t, B(4), [("Your agent ", False), ("ran out.", True)])
    if t >= OPTIONS: words(img, t, OPTIONS, [("You've got ", False), ("options.", True)])
    # the frog: peeks over the bottom edge when the work stops, then hops in on "just hopped in"
    fx, fy, size = col(10), 960, 220
    if t < JUMP[0]:
        k = ease(seg(t, B(4), B(4) + 0.25))
        if k > 0: frog_at(img, t, fx, H + 200 - 185 * k, size, "head", look=(-0.7, -0.6), blink=False)
    else:
        look = (-0.8, -0.3) if t < OPTIONS else (0, 0)
        hop(img, t, JUMP[0], JUMP[1], (fx, H + 280), (fx, fy), size, height=340, look=look)
    return img

LOCAL = _hex("#64a4ff")  # the place-local token: a model on your own machine
MAC_PAD, PC_PAD = (col(2) + 30, 900), (col(8) + 70, 900)

def _laptop(d, x, y, color):
    d.rounded_rectangle([x, y - 13, x + 34, y + 9], radius=4, outline=color, width=3)
    d.line([(x - 6, y + 14), (x + 40, y + 14)], fill=color, width=3)

def _cloud(d, x, y, color):
    d.arc([x - 4, y - 3, x + 12, y + 13], 90, 270, fill=color, width=3)
    d.arc([x + 4, y - 13, x + 24, y + 7], 180, 360, fill=color, width=3)
    d.arc([x + 20, y - 5, x + 38, y + 13], 270, 90, fill=color, width=3)
    d.line([(x + 4, y + 12), (x + 29, y + 12)], fill=color, width=3)

# the Mac app's model menu with a model downloaded (docs/design/first-run/after-mac-model-menu-local.png):
# "This Mac" first, each row "$0 a token", then Frog Cloud A to Z with its output price
_OUT = {r["name"]: r["out"] for r in json.loads((HERE / "prices.json").read_text())["rows"]}
MENU = [("h", "This Mac"), ("r", "Apple Intelligence", "$0 a token", True), ("r", "Qwen3 32B", "$0 a token", True), ("h", "Frog Cloud")] + \
       [("r", n, f"${_OUT[n]:.2f}/M out", False) for n in ("DeepSeek V4.1 Flash", "GLM-5.3 Flash", "Qwen3 Coder Next")]
LOCAL_ROW, CLOUD_ROW = 1, 4  # Qwen3 32B; Qwen3 Coder Next, where the chip starts

def composer(img, x0, y0, x1, y1, model, local, open_menu=False, hover=None, picked=CLOUD_ROW):
    """Frog's composer, redrawn from the app's tokens (card fill, field radius, Plex): the
    placeholder, the where chip, the mode, the model chip and the mic. With open_menu, the model
    menu above it: this Mac first, then Frog Cloud, as the Mac app lists them. Returns the points a pointer needs:
    "chip", and each menu row by index."""
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([x0, y0, x1, y1], radius=30, fill=CARD, outline=LINE, width=2)
    d.text((x0 + 44, y0 + 62), "What should we work on?", font=sans(40, False), fill=FAINT, anchor="lm")
    yb = y1 - 58
    d.line([(x0 + 44, yb), (x0 + 72, yb)], fill=MUTED, width=3); d.line([(x0 + 58, yb - 14), (x0 + 58, yb + 14)], fill=MUTED, width=3)
    fx = x0 + 120  # the where chip: folder, repo, branch
    d.rounded_rectangle([fx, yb - 12, fx + 34, yb + 12], radius=4, outline=MUTED, width=3)
    d.text((fx + 48, yb), "frog", font=sans(36), fill=FG, anchor="lm")
    d.text((fx + 62 + d.textlength("frog", font=sans(36)), yb), "main", font=sans(36, False), fill=MUTED, anchor="lm")
    mx = x1 - 64  # right to left: mic, model chip, mode
    d.ellipse([mx - 34, yb - 34, mx + 34, yb + 34], fill=WELL)
    d.rounded_rectangle([mx - 7, yb - 18, mx + 7, yb + 4], radius=7, outline=FG, width=3)
    d.arc([mx - 14, yb - 10, mx + 14, yb + 12], 0, 180, fill=FG, width=3); d.line([(mx, yb + 12), (mx, yb + 20)], fill=FG, width=3)
    f = sans(36, False); tw = d.textlength(model, font=f)
    cx1 = mx - 60; cx0 = cx1 - tw - 58
    if open_menu: d.rounded_rectangle([cx0 - 18, yb - 30, cx1 + 14, yb + 30], radius=14, fill=WELL)
    if local: _laptop(d, cx0, yb, LOCAL)
    else: d.ellipse([cx0 + 6, yb - 11, cx0 + 28, yb + 11], fill=FROG)
    d.text((cx0 + 52, yb), model, font=f, fill=FG if local else MUTED, anchor="lm")
    d.text((cx0 - 44, yb), "Auto", font=f, fill=MUTED, anchor="rm")
    pts = {"chip": ((cx0 + cx1) / 2, yb)}
    mw = 720; mh = 20 + sum(54 if r[0] == "h" else 68 for r in MENU) + 16
    mx1 = x1; mx0 = mx1 - mw; my1 = y0 - 16; my0 = my1 - mh
    if open_menu: d.rounded_rectangle([mx0, my0, mx1, my1], radius=24, fill=CARD, outline=LINE, width=2)
    y = my0 + 20; ri = 0
    for r in MENU:
        if r[0] == "h":
            if open_menu: d.text((mx0 + 32, y + 30), r[1], font=sans(28, False), fill=FAINT, anchor="lm")
            y += 54; continue
        if open_menu:
            if hover == ri: d.rounded_rectangle([mx0 + 12, y + 2, mx1 - 12, y + 66], radius=14, fill=(0x1f, 0x1f, 0x1f))
            (_laptop if r[3] else _cloud)(d, mx0 + 34, y + 34, LOCAL if r[3] else FROG)
            d.text((mx0 + 92, y + 34), r[1], font=sans(36), fill=FG, anchor="lm")
            d.text((mx0 + 110 + d.textlength(r[1], font=sans(36)), y + 36), r[2], font=sans(30, False), fill=FAINT, anchor="lm")
            if picked == ri: d.line([(mx1 - 62, y + 34), (mx1 - 52, y + 45), (mx1 - 34, y + 22)], fill=FG, width=4, joint="curve")
        pts[ri] = (mx0 + 240, y + 34); ri += 1; y += 68
    return pts

def s_mine(t, lt):
    """the bass drops. The frog lands on its pad; in the composer, the model menu opens and a
    model on this Mac is picked."""
    b = CUT["mine"]
    img = Image.new("RGB", (W, H), CANVAS)
    pond = Pond(); pond.pad(*MAC_PAD, 250); splash(pond, t, B(b + 1), *MAC_PAD, 250); pond.onto(img)
    pad_label(img, MAC_PAD[0], MAC_PAD[1] + 84, "this Mac")
    hop(img, t, B(b), B(b + 1), (-160, 760), (MAC_PAD[0], MAC_PAD[1] - 6), 180, height=300, look=(0.8, 0.1))
    opened, chosen = B(b + 3), B(b + 5)  # the two clicks, each on a beat
    is_open, local = opened <= t < chosen, t >= chosen
    box = (col(5), 770, col(12), 960)
    pts = composer(img, *box, "Qwen3 32B" if local else "Qwen3 Coder Next", local, open_menu=is_open, hover=LOCAL_ROW if t >= B(b + 4.6) else None)
    chip = composer(Image.new("RGB", (8, 8)), *box, "Qwen3 Coder Next", False)["chip"]
    row = pts[LOCAL_ROW]
    if B(b + 1.5) <= t < B(b + 6.5):
        if t < opened:
            k = ease(seg(t, B(b + 1.5), opened - 0.05)); x, y, press = lerp(col(8), chip[0], k), lerp(600, chip[1] + 6, k), 0
        elif t < chosen:
            k = ease(seg(t, opened + 0.1, chosen - 0.08)); x, y = lerp(chip[0], row[0], k), lerp(chip[1] + 6, row[1] + 6, k)
            press = seg(t, opened, opened + 0.25) if t < opened + 0.25 else 0
        else:
            x, y = row[0], row[1] + 6; press = seg(t, chosen, chosen + 0.25) if t < chosen + 0.25 else 0
        cursor(img, x, y, press)
    words(img, t, B(b), [("Open models, on the", False), ("Mac you have.", True)], sub="$0 a token." if local else None)
    return img

CODE = "482913"  # the pairing code in the scene: any six digits, it is typed once

def machines_panel(img, x0, y0, x1, rows, mode="button", typed=0, flash=0.0):
    """Settings › Models › Machines, redrawn from the app's tokens: a row per machine (name, what
    it is, its state), then "Pair a machine…", which turns into the six boxes of a pairing code.
    rows = [(name, tag, detail, state)]. Returns the points a pointer needs."""
    d = ImageDraw.Draw(img)
    d.text((x0, y0), "Machines", font=sans(40), fill=FG, anchor="ls")
    top = y0 + 30; rh = 116
    d.rounded_rectangle([x0, top, x1, top + rh * len(rows)], radius=24, fill=CARD)
    for i, (name, tag, detail, state) in enumerate(rows):
        y = top + i * rh
        if i: d.line([(x0 + 32, y), (x1 - 32, y)], fill=LINE, width=2)
        if i == len(rows) - 1 and flash > 0:  # the row that just joined
            d.rounded_rectangle([x0 + 3, y + 3, x1 - 3, y + rh - 3], radius=22, outline=tuple(int(c * flash + CARD[j] * (1 - flash)) for j, c in enumerate(FROG)), width=4)
        ix, iy = x0 + 40, y + rh / 2  # a screen for the Mac, a rack unit for the PC
        if i == 0:
            d.rounded_rectangle([ix, iy - 20, ix + 44, iy + 10], radius=5, outline=MUTED, width=3); d.line([(ix + 12, iy + 20), (ix + 32, iy + 20)], fill=MUTED, width=3)
        else:
            d.rounded_rectangle([ix, iy - 18, ix + 44, iy + 18], radius=5, outline=MUTED, width=3); d.line([(ix, iy), (ix + 44, iy)], fill=MUTED, width=3)
        d.text((x0 + 112, y + 44), name, font=sans(40), fill=FG, anchor="lm")
        if tag: d.text((x0 + 126 + d.textlength(name, font=sans(40)), y + 46), tag, font=sans(30, False), fill=FAINT, anchor="lm")
        d.text((x0 + 112, y + 86), detail, font=sans(30, False), fill=MUTED, anchor="lm")
        d.ellipse([x1 - 58, iy - 9, x1 - 40, iy + 9], fill=LOCAL)
        d.text((x1 - 76, iy), state, font=sans(34, False), fill=MUTED, anchor="rm")
    by = top + rh * len(rows) + 24
    pts = {"button": (x0 + 150, by + 36)}
    if mode == "button":
        f = sans(36); tw = d.textlength("Pair a machine…", font=f)
        d.rounded_rectangle([x0, by, x0 + tw + 64, by + 72], radius=16, fill=WELL)
        d.text((x0 + 32, by + 36), "Pair a machine…", font=f, fill=FG, anchor="lm")
    elif mode == "code":
        d.text((x0, by + 38), "Pairing code", font=sans(36, False), fill=MUTED, anchor="lm")
        bx = x0 + 250
        for i in range(6):
            x = bx + i * 78 + (24 if i >= 3 else 0)
            on = i == typed
            d.rounded_rectangle([x, by, x + 66, by + 76], radius=12, fill=WELL, outline=FROG if on else LINE, width=3 if on else 2)
            if i < typed: d.text((x + 33, by + 38), CODE[i], font=mono(44, True), fill=FG, anchor="mm")
    return pts

def s_pair(t, lt):
    """a second machine: its pad drifts in showing a pairing code; in Settings › Machines the
    code is typed, a digit at a time, and on beat 28 the pad settles and its row joins."""
    b = CUT["pair"]
    img = Image.new("RGB", (W, H), CANVAS); d = ImageDraw.Draw(img)
    joined = t >= B(b + 4)
    k = ease(seg(t, B(b), B(b + 4)))
    px = lerp(W + 320, PC_PAD[0], k)
    pond = Pond(); pond.pad(*MAC_PAD, 250); pond.pad(px, PC_PAD[1], 250); splash(pond, t, B(b + 4), *PC_PAD, 250); pond.onto(img)
    pad_label(img, MAC_PAD[0], MAC_PAD[1] + 84, "this Mac")
    pad_label(img, px, PC_PAD[1] + 84, "my gaming PC")
    frog_at(img, t, MAC_PAD[0], MAC_PAD[1] - 6, 180, look=(0.9, 0.0))
    if not joined:  # the code the new machine printed, riding in on its pad
        f = mono(44, True); txt = CODE[:3] + " " + CODE[3:]; tw = d.textlength(txt, font=f)
        d.rounded_rectangle([px - tw / 2 - 28, PC_PAD[1] - 150, px + tw / 2 + 28, PC_PAD[1] - 70], radius=16, fill=WELL, outline=LINE, width=2)
        d.text((px, PC_PAD[1] - 110), txt, font=f, fill=FG, anchor="mm")
    click = B(b + 1)
    typed = 0 if t < click else min(6, int((t - B(b + 1.5)) / (BEAT * 0.4)) + 1) if t >= B(b + 1.5) else 0
    rows = [("studio", "This Mac", "M4 Max · 64 GB unified", "idle")]
    if joined: rows.append(("gaming-pc", "", "RTX 3090 · 24 GB VRAM", "idle"))
    mode = "button" if (t < click or joined) else "code"
    flash = float(np.exp(-(t - B(b + 4)) * 2.2)) if joined else 0.0
    pts = machines_panel(img, col(5), 420, col(12), rows, mode=mode, typed=typed, flash=flash)
    if B(b + 0.2) <= t < B(b + 1.6):  # the pointer: to "Pair a machine…", a click on beat 25
        kk = ease(seg(t, B(b + 0.2), click - 0.05)); bx, by = pts["button"]
        cursor(img, lerp(col(9), bx, kk), lerp(820, by + 6, kk), seg(t, click, click + 0.25) if click <= t < click + 0.25 else 0)
    if not joined: words(img, t, B(b), [("Add a machine.", False)], sub="Type its 6-digit code once." if t >= click else None)
    else: words(img, t, B(b + 4), [("It joins the", False), ("pool.", True)])
    return img

SESSIONS = ["Fix the flaky upload test", "Docs search filters page titles", "Check every page against the code",
            "Warm the prompt cache on start", "Count stalls in the swarm bench", "Parse byte ranges in uploads"]

def sessions_panel(img, t, x0, y0, x1, rows):
    """the session list, redrawn from the app's tokens: a row per session, its title, "Working…"
    in the accent with a turning spinner, and the machine it runs on. rows = [(title, machine, since)]."""
    d = ImageDraw.Draw(img)
    d.text((x0, y0), "Sessions", font=sans(40), fill=FG, anchor="ls")
    if rows: d.text((x1, y0), f"{len(rows)} working", font=sans(34, False), fill=MUTED, anchor="rs")
    top = y0 + 30; rh = 92
    if rows: d.rounded_rectangle([x0, top, x1, top + rh * len(rows)], radius=24, fill=CARD)
    for i, (title, machine, since) in enumerate(rows):
        y = top + i * rh
        if i: d.line([(x0 + 32, y), (x1 - 32, y)], fill=LINE, width=2)
        k = ease(seg(t, since, since + 0.2)); f_col = lambda c: tuple(int(c[j] * k + CARD[j] * (1 - k)) for j in range(3))
        cx, cy = x0 + 54, y + rh / 2
        a0 = (t * 420 + i * 60) % 360
        d.arc([cx - 16, cy - 16, cx + 16, cy + 16], 0, 360, fill=f_col(LINE), width=4)
        d.arc([cx - 16, cy - 16, cx + 16, cy + 16], a0, a0 + 100, fill=f_col(FROG), width=4)
        d.text((x0 + 96, y + 32), title, font=sans(34), fill=f_col(FG), anchor="lm")
        fw = sans(28, False); ww = d.textlength("Working…", font=fw)
        d.text((x0 + 96, y + 66), "Working…", font=fw, fill=f_col(FROG), anchor="lm")
        d.ellipse([x0 + 96 + ww + 20, y + 59, x0 + 96 + ww + 34, y + 73], fill=f_col(LOCAL))
        d.text((x0 + 96 + ww + 46, y + 66), machine, font=fw, fill=f_col(MUTED), anchor="lm")

def s_swarm(t, lt):
    """a frog lands on a pad each beat, and with each one a session appears in the list, working,
    on the machine it landed on."""
    b = CUT["swarm"]
    img = Image.new("RGB", (W, H), CANVAS)
    pads = ((col(2) + 100, 650), (col(2) + 100, 950))  # this Mac above, the PC below
    names = ("this Mac", "gaming PC")
    spots = [(pads[i % 2][0] + dx, pads[i % 2][1] - 8) for i, dx in enumerate((-185, -185, 0, 0, 185, 185))]
    pond = Pond()
    for p in pads: pond.pad(*p, 330)
    for i, sp in enumerate(spots): splash(pond, t, B(b + i + 1), sp[0], sp[1] + 8, 90)
    pond.onto(img)
    d = ImageDraw.Draw(img)
    for p, label in zip(pads, ("this Mac", "my gaming PC")):
        d.text((p[0] + 360, p[1]), label, font=mono(LABEL), fill=MUTED, anchor="lm")
    for i, sp in enumerate(spots):
        hop(img, t, B(b + i), B(b + i + 1), (-160, sp[1] - 60), sp, 100, height=170, look=(0.6, 0.0))
    rows = [(SESSIONS[i], names[i % 2], B(b + i + 1)) for i in range(6) if t >= B(b + i + 1)]
    sessions_panel(img, t, col(7), 420, col(12), rows)
    words(img, t, B(b), [("As many agents as", False), ("they can hold.", True)])
    return img

STEPS = ["Read src/retry.rs", "Search for thread_rng", "Run cargo test", "Read tests/upload.rs", "Edit src/retry.rs",
         "Run cargo test", "Read src/backoff.rs", "Edit tests/upload.rs", "Run cargo test", "Write the summary"]

def calls_panel(img, t, x0, y0, x1, rows, machines):
    """where each call ran, redrawn from the app's tokens: a row per call with its step, a
    spinner until it lands and a tick after, and the machine it ran on. A call caught on a machine
    that dropped out says so in one line, then where it reran.
    rows = [(label, state, machine_text, tint)], state "run" or "done"."""
    d = ImageDraw.Draw(img)
    d.text((x0, y0), "Calls", font=sans(40), fill=FG, anchor="ls")
    d.text((x1, y0), "2 machines" if machines == 2 else "1 machine", font=sans(34, False), fill=MUTED if machines == 2 else WARN, anchor="rs")
    top = y0 + 30; rh = 84
    if rows: d.rounded_rectangle([x0, top, x1, top + rh * len(rows)], radius=24, fill=CARD)
    for i, (label, state, machine, tint) in enumerate(rows):
        y = top + i * rh
        if i: d.line([(x0 + 32, y), (x1 - 32, y)], fill=LINE, width=2)
        cx, cy = x0 + 54, y + rh / 2
        if state == "run":
            a0 = (t * 420 + i * 60) % 360
            d.arc([cx - 15, cy - 15, cx + 15, cy + 15], 0, 360, fill=LINE, width=4)
            d.arc([cx - 15, cy - 15, cx + 15, cy + 15], a0, a0 + 100, fill=FROG, width=4)
        else:
            d.line([(cx - 12, cy), (cx - 3, cy + 10), (cx + 13, cy - 10)], fill=MUTED, width=4, joint="curve")
        d.text((x0 + 96, y + 28), label, font=sans(32), fill=FG if state == "run" else MUTED, anchor="lm")
        d.ellipse([x0 + 96, y + 53, x0 + 110, y + 67], fill=tint)
        d.text((x0 + 122, y + 60), machine, font=sans(28, False), fill=WARN if tint == WARN else MUTED, anchor="lm")

def s_how(t, lt):
    """how the pool works. Three agents send calls; each goes to a machine and lands in the list.
    On beat 48 the gaming PC drops out: the call in flight turns round, lands on the Mac, and its
    row says so."""
    b = CUT["how"]
    img = Image.new("RGB", (W, H), CANVAS); d = ImageDraw.Draw(img)
    drop = B(b + 8); out = t >= drop
    agents = [(col(1), 620), (col(2) + 100, 620), (col(4) + 60, 620)]
    mac, pc = (col(1) + 40, 920), (col(4) + 40, 920)
    # the calls: (launch beat, landing beat, from, to the PC?, caught by the drop?)
    calls = []
    for i in range(10):
        cb = b + 1.5 + i
        to_pc = i % 2 == 0 and B(cb) < drop
        caught = to_pc and B(cb + 1) > drop
        calls.append((cb, cb + (1.5 if caught else 1), agents[i % 3], to_pc, caught))
    pond = Pond(); pond.pad(*mac, 180); pond.pad(*pc, 180, out=out)
    for cb, land, src, to_pc, caught in calls: splash(pond, t, B(land), *(pc if to_pc and not caught else mac), 100)
    pond.onto(img)
    pad_label(img, mac[0], mac[1] + 76, "this Mac")
    pad_label(img, pc[0], pc[1] + 76, "my gaming PC", WARN if out else MUTED)
    for i, a in enumerate(agents):
        if t >= B(b + i * 0.5): frog_at(img, t, a[0], a[1], 95, land=B(b + i * 0.5), look=(0, 0.8))
    rows = []
    for i, (cb, land, src, to_pc, caught) in enumerate(calls):
        if t < B(cb): continue
        done = t >= B(land)
        if caught:
            if t < drop: machine, tint = "gaming PC", LOCAL
            elif not done: machine, tint = "gaming PC dropped out", WARN
            else: machine, tint = "reran on this Mac", LOCAL
        else: machine, tint = ("gaming PC" if to_pc else "this Mac"), LOCAL
        rows.append((STEPS[i], "done" if done else "run", machine, tint))
        if done: continue
        k = seg(t, B(cb), B(land)); start = (src[0], src[1] + 10)  # the call in flight
        if caught and t >= drop:
            turn = seg(drop, B(cb), B(cb + 1)); mx, my = lerp(start[0], pc[0], ease(turn)), lerp(start[1], pc[1], ease(turn))
            kk = ease(seg(t, drop, B(land))); x, y = lerp(mx, mac[0], kk), lerp(my, mac[1], kk)
        else:
            dest = pc if to_pc else mac; kk = ease(seg(t, B(cb), B(cb + 1)))
            x, y = lerp(start[0], dest[0], kk), lerp(start[1], dest[1], kk)
        d.ellipse([x - 12, y - 12, x + 12, y + 12], fill=FROG)
    calls_panel(img, t, col(7), 420, col(12), rows[-6:], 1 if out else 2)
    if not out: words(img, t, B(b), [("Each call goes where it", False), ("finishes first.", True)])
    else: words(img, t, drop, [("A machine drops out.", False), ("The turn survives.", True)])
    return img

@lru_cache(1)
def prices():
    import json
    return json.loads((HERE / "prices.json").read_text())

def cloud_perch(pond, x, y):
    """Frog Cloud as somewhere to sit: a cloud drawn like the pads, same fill and edge."""
    parts = [(-150, 6, 112, 62), (0, -40, 150, 96), (150, 6, 112, 62), (0, 30, 232, 56)]
    for grow, fill in ((5, _hex("#36b347")), (0, PAD)):
        for dx, dy, rx, ry in parts:
            pond.d.ellipse([2 * (x + dx - rx - grow), 2 * (y + dy - ry - grow), 2 * (x + dx + rx + grow), 2 * (y + dy + ry + grow)], fill=fill + (255,))

def s_price(t, lt):
    """Frog Cloud, priced. The frog lands on a cloud; a model list drawn from the app's tokens
    gives Frog Cloud's three models with their output prices, then three other providers' list
    prices grow past them at the same dollars per beat."""
    b = CUT["price"]
    img = Image.new("RGB", (W, H), CANVAS)
    P = prices(); rows = P["rows"]
    perch = (col(2) + 30, 900)
    pond = Pond(); cloud_perch(pond, *perch); pond.onto(img)
    pad_label(img, perch[0], perch[1] + 104, "Frog Cloud")
    d = ImageDraw.Draw(img)
    x0, y0, x1 = col(5), 420, col(12)
    d.text((x0, y0), "Models", font=sans(40), fill=FG, anchor="ls")
    d.text((x1, y0), "output, per million tokens", font=sans(34, False), fill=MUTED, anchor="rs")
    top = y0 + 30; hh, rh = 56, 76
    d.rounded_rectangle([x0, top, x1, top + 2 * hh + 6 * rh + 12], radius=24, fill=CARD)
    bar0, per = x0 + 460, 18.0  # bars start on one edge; 18 px per dollar, so $20 is 360 px
    tip = None; y = top
    for sect, (head, frog) in enumerate((("Frog Cloud", True), ("Other providers, different models", False))):
        t_head = B(b) if frog else B(b + 3)
        if t >= t_head: d.text((x0 + 32, y + hh / 2 + 4), head, font=sans(28, False), fill=FAINT, anchor="lm")
        y += hh
        for i, r in enumerate([r for r in rows if r["frog"] == frog]):
            cy = y + rh / 2
            if frog:
                show = t >= B(b + i); k = ease(seg(t, B(b + i), B(b + i) + 0.2)); tint = FROG
            else:  # they start together on beat 55 and grow at five dollars a beat
                show = t >= B(b + 3); k = min(1.0, max(0.0, (t - B(b + 3)) / (BEAT * r["out"] / 5.0))); tint = _hex("#4a4a4a")
            if show:
                d.ellipse([x0 + 34, cy - 9, x0 + 52, cy + 9], fill=tint)
                d.text((x0 + 72, cy), r["name"], font=sans(36), fill=FG if frog else MUTED, anchor="lm")
                w = max(6, r["out"] * per * k)
                d.rounded_rectangle([bar0, cy - 12, bar0 + w, cy + 12], radius=6, fill=tint)
                txt = f"${r['out']:.2f}" if frog else (f"${r['out']:g}" if k >= 1 else f"${r['out'] * k:.0f}")
                d.text((x1 - 32, cy), txt, font=sans(36), fill=FROG if frog else (FG if k >= 1 else MUTED), anchor="rm")
                if not frog and k < 1: tip = (bar0 + w, cy)
            y += rh
        y += 6
    fx, fy = perch[0], perch[1] - 62
    look = (0.7, 0.0)
    if tip: look = (0.9, max(-1.0, min(1.0, (tip[1] - (fy - 230)) / 300)))
    hop(img, t, B(b), B(b + 1), (-160, fy - 40), (fx, fy), 180, height=280, look=look)
    words(img, t, B(b), [("Need more?", False), ("Frog Cloud.", True)],
          sub=f"List prices, {P['date']}." if t >= B(b + 3) else None)
    return img

def s_setup(t, lt):
    b = CUT["setup"]
    img = Image.new("RGB", (W, H), CANVAS)
    fx, fy, size = col(8) + 70, 960, 220
    got = t >= B(b + 1)
    lands = [B(b + 1), B(b + 3), B(b + 5)]
    last = max([l for l in lands if t >= l], default=None)
    frog_at(img, t, fx, fy, size, "carry" if got else "sit", land=last, look=(-0.8, 0.0) if not got else (0, -0.6 if t >= B(b + 3) else 0),
            label="CLAUDE.md" if got else None)
    items = [("CLAUDE.md", b, None), ("skills", b + 2, 0), ("MCP servers", b + 4, 1)]
    head_top = fy - size * 2.22
    for text, cb, stack in items:
        k = seg(t, B(cb), B(cb + 1))
        if k <= 0: continue
        if stack is None:
            if k < 1: chip(img, lerp(-200, fx, ease(k)), lerp(500, fy - 90, ease(k)) - 160 * 4 * k * (1 - k), text, rot=lerp(-20, 0, k))
        else:
            ty = head_top - 34 - stack * 88
            if k < 1: chip(img, lerp(-200, fx, ease(k)), lerp(300, ty, ease(k)) - 120 * 4 * k * (1 - k), text, rot=lerp(-20, 0, k))
            else: chip(img, fx, ty + 10 * np.exp(-(t - B(cb + 1)) * 13), text)
    words(img, t, B(b), [("It brings ", False), ("your setup.", True)],
          sub="Nothing to set up twice." if t >= B(b + 6) else None)
    return img

def s_own(t, lt):
    b = CUT["own"]
    img = Image.new("RGB", (W, H), CANVAS)
    cx, cy = col(5), 880
    pond = Pond(); pond.ring(cx, cy - 10, 480, alpha=0.9, width=3, ry=170); pond.pad(cx, cy, 250)
    hit = B(b + 4)
    if t >= hit:
        k = seg(t, hit, hit + BEAT)
        if k < 1: pond.ring(cx, cy - 10, 480 + 60 * ease(k), alpha=1 - k, width=3, ry=170 + 20 * ease(k))
    pond.onto(img)
    pad_label(img, cx, cy + 84, "yours")
    wave = hit <= t < B(b + 9)
    frog_at(img, t, cx, cy - 6, 200, "wave" if wave else "sit", look=(0.9, -0.1) if t < B(b + 8) else (0, 0))
    # the limit notice from the open flies in, meets the edge of the frog's pond on the beat, and bounces off
    edge = (cx + 560, cy - 60)
    if B(b + 1) <= t < hit:
        k = ease(seg(t, B(b + 1), hit))
        chip(img, lerp(W + 400, edge[0] + 150, k), lerp(540, edge[1], k), "Usage limit reached", size=40, kind="notice", rot=lerp(-8, 6, k))
    elif hit <= t < B(b + 8):
        k = seg(t, hit, B(b + 8))
        chip(img, edge[0] + 150 + 700 * k, edge[1] - 900 * k + 500 * k * k, "Usage limit reached", size=40, kind="notice", rot=6 - 300 * k, alpha=1 - k * k)
    words(img, t, B(b), [("Nobody can cap ", False), ("what you own.", True)],
          sub="Free and open source. Local models keep your code on your Mac." if t >= hit else None)
    return img

def s_end(t, lt):
    """the breakdown. Flush left on the grid like everything else: the line set as three lines,
    the install line, the address; the frog lands on the right and winks."""
    b = CUT["end"]
    img = Image.new("RGB", (W, H), CANVAS)
    ex, ey, size = col(10), 900, 300
    pond = Pond(); splash(pond, t, B(b + 1), ex, ey, 300); pond.onto(img)
    if t < B(b + 1): hop(img, t, B(b), B(b + 1), (ex, H + 400), (ex, ey), size, height=420)
    else: frog_at(img, t, ex, ey, size, land=B(b + 1), wink=B(b + 6) <= t < B(b + 7), blink=False)
    d = ImageDraw.Draw(img)
    f = sans(132)
    for i, (line, green) in enumerate((("No caps.", True), ("Your machines.", False), ("One agent.", False))):
        tb = B(b + 1 + i * 0.5)  # a line every half beat
        if t < tb: continue
        k = ease(seg(t, tb, tb + 0.15))
        d.text((MARGIN, 250 + i * 140 - (1 - k) * 18), line, font=f, fill=tuple(int(c * k) for c in (FROG if green else FG)), anchor="ls")
    if t >= B(b + 3):
        k = ease(seg(t, B(b + 3), B(b + 3) + 0.2))
        line = "curl -fsSL https://frog.toys/install.sh | sh"
        fm = mono(40); tw = d.textlength("$ " + line, font=fm)
        x0, y0 = MARGIN, 690
        d.rounded_rectangle([x0, y0, x0 + tw + 80, y0 + 96], radius=16, fill=tuple(int(c * k) for c in CARD))
        d.text((x0 + 40, y0 + 62), "$ ", font=fm, fill=tuple(int(c * k) for c in FROG), anchor="ls")
        d.text((x0 + 40 + d.textlength("$ ", font=fm), y0 + 62), line, font=fm, fill=tuple(int(c * k) for c in FG), anchor="ls")
    if t >= B(b + 5):
        k = ease(seg(t, B(b + 5), B(b + 5) + 0.2))
        d.text((MARGIN, 930 - (1 - k) * 16), "frog.toys", font=sans(TITLE), fill=tuple(int(c * k) for c in FG), anchor="ls")
    return img  # no fade: it ends on the beat, with the music

SHOTS = {"open": s_open, "mine": s_mine, "pair": s_pair, "swarm": s_swarm, "how": s_how,
         "price": s_price, "setup": s_setup, "own": s_own, "end": s_end}

def frame(f):
    t = f / FPS
    name = shot_of(t)
    img = SHOTS[name](t, t - B(CUT[name]))
    img.save(OUT / f"{f:04d}.png", compress_level=1)
    return f

if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    frames = [int(x) for x in sys.argv[2].split(",")] if len(sys.argv) > 2 else list(range(NFRAMES))
    with Pool(int(os.environ.get("NPROC", 6))) as pool:
        for i, _ in enumerate(pool.imap_unordered(frame, frames, chunksize=4)):
            if i % 200 == 0: print(f"{i}/{len(frames)}", flush=True)

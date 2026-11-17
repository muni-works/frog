#!/usr/bin/env python3
"""Composite the Frog hype reel, frame by frame. Every animated quantity is a pure function of
the time t, so any frame renders alone (contact sheets, re-rendering one shot).

usage: comp.py <out_dir> [frame,frame,...]

Footage: footage/ (web frames from capture/run.sh, 2560x1440) and the Mac app's checked-in
snapshots under docs/design/. Look: Frog's own tokens (design/tokens.json, dark): true black,
#ececec text, the frog green #58cc6f as the one accent, IBM Plex Sans and Mono."""
import os, sys
from functools import lru_cache
from multiprocessing import Pool
from pathlib import Path
import numpy as np
from PIL import Image, ImageDraw, ImageFont, ImageFilter
from beats import ASK, B, BEAT, CUT, DUR, FPS, JUMP, NFRAMES, OPTIONS, W, H
from frog import sprite, place

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

# ---- time helpers (from the board video's comp.py)
def ease(x):
    """cubic-bezier(0.2, 0, 0, 1), the one curve."""
    x = min(1.0, max(0.0, x)); lo, hi = 0.0, 1.0
    if x in (0.0, 1.0): return x
    for _ in range(18):
        u = (lo + hi) / 2
        if 3 * (1 - u) ** 2 * u * 0.2 + u ** 3 < x: lo = u
        else: hi = u
    return u ** 3
def seg(t, a, b): return min(1.0, max(0.0, (t - a) / (b - a)))
def lerp(a, b, k): return a + (b - a) * k
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

def words(img, t, t0, parts, where="bottom", size=92, x=120, sub=None, t1=None):
    """the on-screen words: a sentence, one phrase in frog green, rising into place on its beat.
    parts = [(text, green?), ...]."""
    if t < t0 or (t1 is not None and t >= t1): return
    k = ease(seg(t, t0, t0 + 0.35))
    out = 1.0 if t1 is None else 1 - seg(t, t1 - 0.12, t1)
    f = sans(size)
    y = (H - 150 - (70 if sub else 0) if where == "bottom" else 110) + (1 - k) * 28
    lay = Image.new("RGBA", (W, H), (0, 0, 0, 0)); d = ImageDraw.Draw(lay)
    cx = x
    for text, green in parts:
        d.text((cx, y), text, font=f, fill=(FROG if green else FG) + (255,), anchor="ls")
        cx += d.textlength(text, font=f)
    if sub:
        d.text((x + 2, y + 56), sub, font=sans(40, False), fill=MUTED + (255,), anchor="ls")
    a = np.asarray(lay).copy(); a[..., 3] = (a[..., 3] * k * out).astype(np.uint8)
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
    """the frog resting at (x, y); `land` is when it touched down, for the squash."""
    sq = 1.0 if land is None or t < land else 1 - 0.24 * np.exp(-(t - land) * 13)
    b = blinking(t) if blink is None else blink
    place(img, sprite(size, pose, blink=b, wink=wink, look=look, label=label), x, y, squash=float(sq), rot=rot, clip_y=clip_y)

def hop(img, t, t0, t1, p0, p1, size, height=260, look=(0, 0), pose_end="sit", label=None):
    """a hop from p0 to p1 between t0 and t1: in the air stretched and turned along the arc,
    then resting at p1 with a squash. Before t0 nothing is drawn."""
    if t < t0: return False
    if t >= t1:
        frog_at(img, t, p1[0], p1[1], size, pose_end, land=t1, look=look, label=label); return True
    k = (t - t0) / (t1 - t0)
    x = lerp(p0[0], p1[0], k); y = lerp(p0[1], p1[1], k) - height * 4 * k * (1 - k)
    dx = p1[0] - p0[0]; dy = (p1[1] - p0[1]) - height * 4 * (1 - 2 * k)
    rot = float(np.degrees(np.arctan2(-dx, -dy))) if abs(dx) > 1 else 0.0
    place(img, sprite(size, "hop", look=(0.4 * np.sign(dx) if dx else 0, -0.5)), x, y + size * 0.9, rot=max(-70, min(70, rot)))
    return True

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
    x0, y0, x1, y1 = 200, 250, 1240, 860
    d.rounded_rectangle([x0, y0, x1, y1], radius=28, fill=CARD)
    # frame 0 already reads: a task, two steps done, a third under way
    d.text((x0 + 56, y0 + 84), "Fix the flaky upload test", font=sans(52), fill=FG, anchor="ls")
    stopped = t >= B(4)
    rows = [("Read the code", True), ("Found the bug", True), ("Writing the fix", False)]
    for i, (label, done) in enumerate(rows):
        ry = y0 + 170 + i * 76
        if done:
            d.ellipse([x0 + 56, ry - 22, x0 + 100, ry + 22], fill=FG)
            d.line([(x0 + 67, ry), (x0 + 75, ry + 9), (x0 + 90, ry - 9)], fill=CARD, width=5, joint="curve")
            d.text((x0 + 124, ry), label, font=sans(42, False), fill=MUTED, anchor="lm")
        else:
            col = NOTICE if stopped else FG
            d.ellipse([x0 + 56, ry - 22, x0 + 100, ry + 22], outline=col, width=4)
            d.text((x0 + 124, ry), label, font=sans(42), fill=col, anchor="lm")
            bx, bw = x0 + 520, 440
            fill = min(0.62, 0.30 + 0.08 * on_beat(t, 0, 4))  # it creeps forward a beat at a time, then stops
            d.rounded_rectangle([bx, ry - 8, bx + bw, ry + 8], radius=8, fill=LINE)
            d.rounded_rectangle([bx, ry - 8, bx + bw * fill, ry + 8], radius=8, fill=col)
    if t >= ASK:  # "What's poppin'?": your message, on the lyric
        k = ease(seg(t, ASK, ASK + 0.15)); f = sans(42); msg = "What's poppin'?"
        tw = d.textlength(msg, font=f)
        bx1, by0 = x1 - 56, y0 + 410 + (1 - k) * 16
        d.rounded_rectangle([bx1 - tw - 64, by0, bx1, by0 + 84], radius=42, fill=WELL)
        d.text((bx1 - 32 - tw / 2, by0 + 42), msg, font=f, fill=FG, anchor="mm")
    if stopped:  # beat 4: the answer
        k = ease(seg(t, B(4), B(4) + 0.15))
        ax0, ay0, ax1, ay1 = x0 + 56, y1 - 104 + (1 - k) * 16, x1 - 56, y1 - 16 + (1 - k) * 16
        d.rounded_rectangle([ax0, ay0, ax1, ay1], radius=18, fill=NOTICE_BG, outline=NOTICE, width=2)
        d.text((ax0 + 30, ay0 + 44), "Usage limit reached", font=sans(40), fill=NOTICE, anchor="lm")
        if t < B(6):
            d.text((ax1 - 30, ay0 + 44), "Resets in 4 h 12 min", font=sans(34, False), fill=MUTED, anchor="rm")
        else:
            f = sans(32); label = "Buy extra usage  $$$"; tw = d.textlength(label, font=f)
            d.rounded_rectangle([ax1 - tw - 70, ay0 + 14, ax1 - 22, ay0 + 74], radius=30, fill=NOTICE)
            d.text((ax1 - 46 - tw / 2, ay0 + 44), label, font=f, fill=(0x1a, 0x12, 0x02), anchor="mm")
    if stopped and t < OPTIONS: words(img, t, B(4), [("Your agent ", False), ("ran out.", True)], where="top")
    if t >= OPTIONS: words(img, t, OPTIONS, [("You've got ", False), ("options.", True)], where="top")
    # the frog: peeks over the bottom edge when the work stops, then hops in on "just hopped in"
    fx, fy, size = 1570, 900, 220
    if t < JUMP[0]:
        k = ease(seg(t, B(4), B(4) + 0.25))
        if k > 0: frog_at(img, t, fx, H + 200 - 185 * k, size, "head", look=(-0.7, -0.6), blink=False)
    else:
        look = (-0.8, -0.3) if t < OPTIONS else (0, 0)
        hop(img, t, JUMP[0], JUMP[1], (fx, H + 280), (fx, fy), size, height=340, look=look)
    return img

@lru_cache(1)
def mac_model_chip():
    """the Mac composer's own right-hand end: Auto, and Qwen3 8B running on this Mac."""
    g = load("docs/design/composer/mac-new-folder-dark.png").crop((1100, 200, 1490, 292))
    return g.resize((int(g.width * 1.9), int(g.height * 1.9)), Image.LANCZOS)

def ui_card(img, im, cx, cy, pad=26):
    d = ImageDraw.Draw(img)
    x0, y0 = cx - im.width / 2 - pad, cy - im.height / 2 - pad
    d.rounded_rectangle([x0, y0, x0 + im.width + 2 * pad, y0 + im.height + 2 * pad], radius=22, fill=CARD, outline=LINE, width=2)
    img.paste(im, (int(cx - im.width / 2), int(cy - im.height / 2)))

MAC_PAD, PC_PAD = (520, 860), (1340, 860)

def s_mine(t, lt):
    b = CUT["mine"]
    img = Image.new("RGB", (W, H), CANVAS)
    pond = Pond(); pond.pad(*MAC_PAD, 250); splash(pond, t, B(b + 1), *MAC_PAD, 250); pond.onto(img)
    pad_label(img, MAC_PAD[0], MAC_PAD[1] + 84, "this Mac")
    hop(img, t, B(b), B(b + 1), (-160, 760), (MAC_PAD[0], MAC_PAD[1] - 6), 190, height=300, look=(0.7, -0.2))
    if t >= B(b + 1):
        k = ease(seg(t, B(b + 1), B(b + 1) + 0.2))
        ui_card(img, mac_model_chip(), 1340, 560 + (1 - k) * 20)
    words(img, t, B(b), [("Open models, on the ", False), ("Mac you have.", True)], where="top",
          sub="$0 a token." if t >= B(b + 2) else None)
    return img

@lru_cache(1)
def machines_card():
    """the Mac's Settings › Models › Machines: this Mac and the paired RTX 3090. The account and
    credit rows below it are left out."""
    m = load("docs/design/parity/models-settings-mac-dark.png").crop((40, 0, 1240, 312))
    m = m.resize((int(m.width * 0.82), int(m.height * 0.82)), Image.LANCZOS)
    mask = Image.new("L", m.size, 0); ImageDraw.Draw(mask).rounded_rectangle([0, 0, m.width - 1, m.height - 1], radius=20, fill=255)
    c = Image.new("RGB", m.size, CANVAS); c.paste(m, (0, 0), mask)
    return c

def s_pair(t, lt):
    b = CUT["pair"]
    img = Image.new("RGB", (W, H), CANVAS); d = ImageDraw.Draw(img)
    k = ease(seg(t, B(b), B(b + 4)))  # the second pad drifts in and settles on beat 16
    px = lerp(W + 320, PC_PAD[0], k)
    pond = Pond(); pond.pad(*MAC_PAD, 250); pond.pad(px, PC_PAD[1], 250); splash(pond, t, B(b + 4), *PC_PAD, 250); pond.onto(img)
    pad_label(img, MAC_PAD[0], MAC_PAD[1] + 84, "this Mac")
    pad_label(img, px, PC_PAD[1] + 84, "a PC with an RTX 3090")
    frog_at(img, t, MAC_PAD[0], MAC_PAD[1] - 6, 190, look=(0.9, 0.0))
    if t < B(b + 4):
        f = mono(38); cmd = "curl -fsSL https://frog.toys/node | sh"
        tw = d.textlength("$ " + cmd, font=f); x0, y0 = 1340 - tw / 2 - 36, 400
        d.rounded_rectangle([x0, y0, x0 + tw + 72, y0 + 92], radius=16, fill=CARD)
        d.text((x0 + 36, y0 + 60), "$ ", font=f, fill=FROG, anchor="ls")
        d.text((x0 + 36 + d.textlength("$ ", font=f), y0 + 60), cmd, font=f, fill=FG, anchor="ls")
        if t >= B(b + 2): d.text((1340, y0 + 150), "prints a 6-digit pairing code", font=sans(34, False), fill=MUTED, anchor="ms")
        words(img, t, B(b), [("Add a machine.", False)], where="top")
    else:
        m = machines_card(); kk = ease(seg(t, B(b + 4), B(b + 4) + 0.2))
        img.paste(m, (int(1310 - m.width / 2), int(300 + (1 - kk) * 20)))
        words(img, t, B(b + 4), [("It joins the ", False), ("pool.", True)], where="top")
    return img

def s_swarm(t, lt):
    b = CUT["swarm"]
    img = Image.new("RGB", (W, H), CANVAS); d = ImageDraw.Draw(img)
    pads = ((470, 880), (1160, 880))
    spots = [(pads[i % 2][0] + dx, pads[i % 2][1] - 8) for i, dx in enumerate((-185, -185, 0, 0, 185, 185))]
    pond = Pond()
    for p in pads: pond.pad(*p, 330)
    for i, sp in enumerate(spots): splash(pond, t, B(b + i + 1), sp[0], sp[1] + 8, 90)
    pond.onto(img)
    pad_label(img, pads[0][0], pads[0][1] + 96, "this Mac"); pad_label(img, pads[1][0], pads[1][1] + 96, "the PC")
    for i, sp in enumerate(spots):  # a frog lands on each beat
        hop(img, t, B(b + i), B(b + i + 1), (sp[0] + (-500 if i % 2 == 0 else 500), -200), sp, 100, height=120, look=(0, 0.3))
    n = on_beat(t, b + 1, 6)
    d.text((1800, 420), str(n), font=sans(300), fill=FROG if n else LINE, anchor="rs")
    d.text((1800, 480), "agents, working at once", font=sans(36, False), fill=MUTED, anchor="rs")
    words(img, t, B(b), [("As many agents as ", False), ("they can hold.", True)], where="top")
    return img

def s_how(t, lt):
    b = CUT["how"]
    img = Image.new("RGB", (W, H), CANVAS); d = ImageDraw.Draw(img)
    out = t >= B(b + 8)  # the PC drops out
    agents = [(520, 470), (960, 470), (1400, 470)]
    mac, pc = (600, 900), (1320, 900)
    pond = Pond(); pond.pad(*mac, 280); pond.pad(*pc, 280, out=out)
    # calls: once the agents are in, one leaves every half beat for the machine that is free
    calls = []
    for i in range(0, 24):
        cb = b + 2 + i * 0.5
        if cb + 1 > b + 12: break
        src = agents[i % 3]; to_pc = (i % 2 == 1)
        calls.append((cb, src, to_pc))
    for cb, src, to_pc in calls:
        splash(pond, t, B(cb + 1), *(pc if to_pc and cb + 1 <= b + 8 else mac), 120)
    pond.onto(img)
    pad_label(img, mac[0], mac[1] + 90, "this Mac")
    pad_label(img, pc[0], pc[1] + 90, "the PC dropped out" if out else "the PC", WARN if out else MUTED)
    for i, a in enumerate(agents):
        if t >= B(b + i): frog_at(img, t, a[0], a[1], 120, land=B(b + i), look=(0, 0.8))
    for cb, src, to_pc in calls:
        k = seg(t, B(cb), B(cb + 1))
        if not (0 < k < 1): continue
        start = (src[0], src[1] + 10)
        if to_pc and cb + 1 > b + 8:  # in flight when the PC drops: it turns round and lands on the Mac
            turn = seg(B(b + 8), B(cb), B(cb + 1))
            if t < B(b + 8): x, y = lerp(start[0], pc[0], ease(k)), lerp(start[1], pc[1], ease(k))
            else:
                mx, my = lerp(start[0], pc[0], ease(turn)), lerp(start[1], pc[1], ease(turn))
                kk = ease(seg(t, B(b + 8), B(cb + 1))); x, y = lerp(mx, mac[0], kk), lerp(my, mac[1], kk)
        else:
            dest = pc if to_pc else mac
            x, y = lerp(start[0], dest[0], ease(k)), lerp(start[1], dest[1], ease(k))
        d.ellipse([x - 13, y - 13, x + 13, y + 13], fill=FROG)
    if not out:
        words(img, t, B(b), [("Each call goes where it ", False), ("finishes first.", True)], where="top", size=84)
    else:
        words(img, t, B(b + 8), [("A machine drops out. ", False), ("The turn survives.", True)], where="top", size=84)
    return img

@lru_cache(1)
def prices():
    import json
    return json.loads((HERE / "prices.json").read_text())

def s_price(t, lt):
    b = CUT["price"]
    img = Image.new("RGB", (W, H), CANVAS); d = ImageDraw.Draw(img)
    P = prices(); rows = P["rows"]
    x_label, x_bar, per = 120, 640, 50.0  # 50 px per dollar: $20 is 1000 px
    ys = [300, 386, 472, 610, 696, 782]
    tip = None
    for i, r in enumerate(rows):
        y = ys[i]
        if r["frog"]:
            if t < B(b + i): continue
            k = ease(seg(t, B(b + i), B(b + i) + 0.2)); col = FROG
        else:  # the others start on beat 47 and keep growing, at the same dollars per beat
            t0 = B(b + 3)
            if t < t0: continue
            k = min(1.0, (t - t0) / (BEAT * r["out"] / 5.0)); col = _hex("#383838")
        w = max(8, r["out"] * per * k)
        d.text((x_label, y + 30), r["name"], font=sans(40, r["frog"]), fill=FROG if r["frog"] else MUTED, anchor="lm")
        d.rounded_rectangle([x_bar, y + 6, x_bar + w, y + 54], radius=8, fill=col)
        shown = r["out"] * k
        txt = f"${r['out']:.2f}" if r["frog"] else (f"${r['out']:g}" if k >= 1 else f"${shown:.0f}")
        d.text((x_bar + w + 20, y + 30), txt, font=sans(40), fill=FROG if r["frog"] else (FG if k >= 1 else MUTED), anchor="lm")
        if not r["frog"] and k < 1: tip = (x_bar + w, y + 30)
    d.text((x_label, 900), f"List price per million output tokens, {P['date']}. Different models: this compares price only.",
           font=sans(30, False), fill=FAINT, anchor="lm")
    fx, fy = 1500, 540
    look = (0.0, 0.2)
    if tip: look = (max(-1, min(1, (tip[0] - fx) / 500)), 0.9)
    frog_at(img, t, fx, fy, 120, land=B(b), look=look)
    words(img, t, B(b), [("Need more? ", False), ("Frog Cloud.", True)], where="top")
    return img

def s_setup(t, lt):
    b = CUT["setup"]
    img = Image.new("RGB", (W, H), CANVAS)
    fx, fy, size = 1180, 900, 230
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
    words(img, t, B(b), [("It brings ", False), ("your setup.", True)], where="top",
          sub="Nothing to set up twice." if t >= B(b + 6) else None)
    return img

def s_own(t, lt):
    b = CUT["own"]
    img = Image.new("RGB", (W, H), CANVAS)
    cx, cy = 760, 860
    pond = Pond(); pond.ring(cx, cy - 10, 560, alpha=0.9, width=3, ry=190); pond.pad(cx, cy, 250)
    hit = B(b + 4)
    if t >= hit:
        k = seg(t, hit, hit + BEAT)
        if k < 1: pond.ring(cx, cy - 10, 560 + 60 * ease(k), alpha=1 - k, width=3, ry=190 + 20 * ease(k))
    pond.onto(img)
    pad_label(img, cx, cy + 84, "yours")
    wave = hit <= t < B(b + 9)
    frog_at(img, t, cx, cy - 6, 200, "wave" if wave else "sit", look=(0.9, -0.1) if t < B(b + 8) else (0, 0))
    # the limit notice from the open flies in, meets the edge of the frog's pond on the beat, and bounces off
    edge = (cx + 610, cy - 60)
    if B(b + 1) <= t < hit:
        k = ease(seg(t, B(b + 1), hit))
        chip(img, lerp(W + 400, edge[0] + 150, k), lerp(540, edge[1], k), "Usage limit reached", size=40, kind="notice", rot=lerp(-8, 6, k))
    elif hit <= t < B(b + 8):
        k = seg(t, hit, B(b + 8))
        chip(img, edge[0] + 150 + 700 * k, edge[1] - 900 * k + 500 * k * k, "Usage limit reached", size=40, kind="notice", rot=6 - 300 * k, alpha=1 - k * k)
    words(img, t, B(b), [("Nobody can cap ", False), ("what you own.", True)], where="top",
          sub="Free and open source. Local models keep your code on your Mac." if t >= hit else None)
    return img

END_FROG = (W // 2, 440, 170)  # where the frog sits on the end card: x, y, head size

def s_end(t, lt):
    b = CUT["end"]
    img = Image.new("RGB", (W, H), CANVAS)
    ex, ey, size = END_FROG
    pond = Pond(); splash(pond, t, B(b + 1), ex, ey, 260); pond.onto(img)
    hop(img, t, B(b), B(b + 1), (ex, H + 300), (ex, ey), size, height=380) if t < B(b + 1) else \
        frog_at(img, t, ex, ey, size, land=B(b + 1), wink=B(b + 6) <= t < B(b + 7), blink=False)
    d = ImageDraw.Draw(img)
    k1 = ease(seg(t, B(b + 1), B(b + 1) + 0.2))
    f = sans(88); parts = [("No caps. ", True), ("Your machines. One agent.", False)]
    x = W / 2 - sum(d.textlength(p, font=f) for p, _ in parts) / 2
    for p, g in parts:
        if k1 > 0: d.text((x, 590 - (1 - k1) * 18), p, font=f, fill=tuple(int(c * k1) for c in (FROG if g else FG)), anchor="ls")
        x += d.textlength(p, font=f)
    k3 = ease(seg(t, B(b + 3), B(b + 3) + 0.2))
    if k3 > 0:
        line = "curl -fsSL https://frog.toys/install.sh | sh"
        f = mono(40); tw = d.textlength("$ " + line, font=f)
        bx0, by0 = W / 2 - tw / 2 - 40, 670
        d.rounded_rectangle([bx0, by0, W - bx0, by0 + 96], radius=16, fill=tuple(int(c * k3) for c in CARD))
        d.text((bx0 + 40, by0 + 62), "$ ", font=f, fill=tuple(int(c * k3) for c in FROG), anchor="ls")
        d.text((bx0 + 40 + d.textlength("$ ", font=f), by0 + 62), line, font=f, fill=tuple(int(c * k3) for c in FG), anchor="ls")
    k4 = ease(seg(t, B(b + 5), B(b + 5) + 0.2))
    if k4 > 0:
        d.text((W / 2, 900 - (1 - k4) * 16), "frog.toys", font=sans(96), fill=tuple(int(c * k4) for c in FG), anchor="ms")
    fo = seg(t, DUR - 0.7, DUR)
    return dim(img, fo) if fo > 0 else img

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

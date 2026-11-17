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
from beats import B, BEAT, CUT, DUR, FPS, NFRAMES, W, H

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

def view(img, cx, cy, z):
    """the camera: a 16:9 window on img centred at (cx, cy), z=1 the widest that fits."""
    sw, sh = img.size
    rw = min(sw, sh * 16 / 9) / z; rh = rw * 9 / 16
    x0 = min(max(cx - rw / 2, 0), sw - rw); y0 = min(max(cy - rh / 2, 0), sh - rh)
    return img.resize((W, H), Image.LANCZOS, box=(x0, y0, x0 + rw, y0 + rh)), (x0, y0, rw / W)

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
        d.text((x + 2, y + 62), sub, font=sans(40, False), fill=MUTED + (255,), anchor="ls")
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

# ---- shots. Each draws the frame at time t; lt = seconds into the shot.
def s_open(t, lt):
    img = Image.new("RGB", (W, H), CANVAS)
    k = ease(seg(lt, 0.1, 0.9))
    if k > 0: paste_center(img, mark(int(lerp(150, 300, k))), W / 2, H / 2 - 70, k)
    k2 = ease(seg(lt, 0.9, 1.3))
    if k2 > 0:
        d = ImageDraw.Draw(img)
        d.text((W / 2, H / 2 + 175 - (1 - k2) * 16), "Frog", font=sans(110), fill=tuple(int(c * k2) for c in FG), anchor="ms")
    return img

def s_type(t, lt):
    # typed a character per ~2 frames from b4.5 to b12, menu opens b12.5, lilypad picked b14.5
    nchars = 56
    p = seg(t, B(4.5), B(12))
    i = int(round(p * nchars))
    if t >= B(14.5): i = 58
    elif t >= B(12.5): i = 57
    src = web("type", i)
    z = lerp(1.0, 1.55, ease(seg(t, B(4), B(12.5))))
    cx = lerp(1280, 1450, ease(seg(t, B(4), B(12.5))))
    cy = lerp(720, 1080, ease(seg(t, B(4), B(12.5))))
    img, cam = view(src, cx, cy, z)
    img = scrim(img, "top", 360)
    words(img, t, B(5), [("A free, ", False), ("open-source", True), (" coding agent.", False)], where="top")
    return img

@lru_cache(1)
def mac_menu():
    """the Mac composer's where menu (This Mac, then Frog Cloud) on a black margin, so the
    words above clear it."""
    m = load("docs/design/composer/mac-where-menu-dark.png")
    c = Image.new("RGB", (2300, 1500), CANVAS); c.paste(m, (382, 380))
    return c

def s_mac(t, lt):
    src = mac_menu()
    z = lerp(1.0, 1.06, seg(lt, 0, 4 * BEAT)) * punch(t, B(CUT["mac"]))
    img, cam = view(src, 1150, 1500, z)
    img = scrim(img, "top", 300)
    words(img, t, B(CUT["mac"]) + 0.05, [("On your ", False), ("Mac.", True)], where="top")
    return img

def s_cloud(t, lt):
    src = web("models", 1)  # the web app's model menu: Frog Cloud's models, priced per token
    z = lerp(1.75, 1.9, seg(lt, 0, 4 * BEAT))
    img, cam = view(src, 1800, 900, z)
    img = scrim(img, "top", 400)
    words(img, t, B(CUT["cloud"]) + 0.05, [("Or in ", False), ("Frog Cloud.", True)], where="top")
    return img

def s_stream(t, lt):
    i = 4 + int(seg(t, B(CUT["stream"]), B(CUT["stream"] + 10)) * 27)  # from the first read to the ask
    src = web("stream", i)
    k = ease(seg(lt, 0, 12 * BEAT))
    img, cam = view(src, lerp(1500, 1560, k), lerp(520, 640, k), lerp(1.3, 1.4, k))
    img = scrim(img, "bottom", 380)
    words(img, t, B(CUT["stream"]) + 0.5, [("It reads, runs ", False), ("and edits.", True)])
    return img

def s_sandbox(t, lt):
    src = web("stream", 99)  # the last frame: the ask card
    k = ease(seg(lt, 0, 8 * BEAT))
    img, cam = view(src, lerp(1560, 1420, k), lerp(900, 980, k), lerp(1.45, 1.85, k))
    img = scrim(img, "top", 400)
    x0, y0 = to_screen(cam, 930, 1050); x1, y1 = to_screen(cam, 1255, 1105)
    ring(img, (x0, y0, x1, y1), t, B(CUT["sandbox"] + 2))
    words(img, t, B(CUT["sandbox"]) + 0.1, [("Every session in its own ", False), ("sandbox.", True)], where="top")
    return img

def s_parallel(t, lt):
    if t < B(CUT["parallel"] + 4):
        src = web("type", 0)  # the new-session screen's pitch cards
        z = lerp(2.5, 2.2, seg(lt, 0, 4 * BEAT)) * punch(t, B(CUT["parallel"]), 0.07)
        img, cam = view(src, 1560, 780, z)
        x0, y0 = to_screen(cam, 1330, 645); x1, y1 = to_screen(cam, 1785, 905)
        ring(img, (x0, y0, x1, y1), t, B(CUT["parallel"] + 0.5))
        return img
    src = web("stream", 12)  # the sidebar: four sessions, one working, one with a PR
    k = ease(seg(t, B(CUT["parallel"] + 4), B(CUT["pr"])))
    img, cam = view(src, 0, 560, lerp(1.45, 1.6, k))  # pinned to the left edge
    img = scrim(img, "bottom", 330)
    words(img, t, B(CUT["parallel"] + 4) + 0.05, [("Several at once, ", False), ("laptop closed.", True)])
    return img

def s_pr(t, lt):
    t0 = B(CUT["pr"])
    if t >= B(CUT["pr"] + 5.5):
        img = Image.new("RGB", (W, H), CANVAS)
        g = load("docs/design/composer/mac-git-pr-dark.png")  # the Mac composer: the PR, checking
        k = ease(seg(t, B(CUT["pr"] + 5.5), B(CUT["pr"] + 6.2)))
        s = lerp(1.14, 1.24, seg(t, B(CUT["pr"] + 5.5), B(CUT["price"])))
        paste_center(img, g.resize((int(g.width * s), int(g.height * s)), Image.LANCZOS), W / 2, H / 2 + 40, k)
        words(img, t, t0 + 0.05, [("It opens the ", False), ("pull request.", True)], where="top")
        return img
    src = web("inspector", 0)
    k = ease(seg(t, t0 + BEAT, B(CUT["pr"] + 4)))
    img, cam = view(src, lerp(1280, 2100, k), lerp(720, 1100, k), lerp(1.0, 1.7, k))
    img = scrim(img, "top", 400)
    bx, by = to_screen(cam, 2322, 1373)
    m = ease(seg(t, B(CUT["pr"] + 2), B(CUT["pr"] + 4)))
    press = seg(t, B(CUT["pr"] + 4), B(CUT["pr"] + 5))
    cursor(img, lerp(bx - 420, bx, m), lerp(by - 260, by, m), press)
    words(img, t, t0 + 0.05, [("It opens the ", False), ("pull request.", True)], where="top")
    return img

def s_price(t, lt):
    src = web("models", 1)
    img, cam = view(src, 1880, 920, 2.2)
    img = scrim(scrim(dim(img.filter(ImageFilter.GaussianBlur(2)), 0.55), "bottom", 380), "top", 300)
    words(img, t, B(CUT["price"]) + 0.05, [("Pay per ", False), ("token.", True)], where="bottom", size=120, sub=None)
    words(img, t, B(CUT["price"] + 2), [("At cost, ", False), ("plus 10%.", True)], where="top", size=64)
    return img

def s_credit(t, lt):
    img = Image.new("RGB", (W, H), CANVAS)
    d = ImageDraw.Draw(img)
    k = ease(seg(lt, 0, 0.35))
    y = H / 2 - 20 + (1 - k) * 24
    col = tuple(int(c * k) for c in FROG); col2 = tuple(int(c * k) for c in FG)
    d.text((W / 2, y), "$1 free credit.", font=sans(150), fill=col, anchor="ms")
    k2 = ease(seg(lt, 2 * BEAT, 2 * BEAT + 0.35))
    d.text((W / 2, y + 120), "No plan needed. Your own machines: $0.", font=sans(56, False), fill=tuple(int(c * k2) for c in FG), anchor="ms")
    return img

def s_end(t, lt):
    img = Image.new("RGB", (W, H), CANVAS)
    d = ImageDraw.Draw(img)
    k = ease(seg(lt, 0, 0.6)); s = punch(t, B(CUT["end"]), 0.08)
    paste_center(img, mark(int(260 * s)), W / 2, 330, k)
    k2 = ease(seg(lt, 2 * BEAT, 2 * BEAT + 0.4))
    d.text((W / 2, 610 - (1 - k2) * 20), "frog.toys", font=sans(120), fill=tuple(int(c * k2) for c in FG), anchor="ms")
    k3 = ease(seg(lt, 4 * BEAT, 4 * BEAT + 0.4))
    if k3 > 0:
        line = "curl -fsSL https://frog.toys/install.sh | sh"
        f = mono(40); tw = d.textlength("$ " + line, font=f)
        bx0, by0 = W / 2 - tw / 2 - 40, 700
        d.rounded_rectangle([bx0, by0, W - bx0, by0 + 96], radius=16, fill=tuple(int(c * k3) for c in CARD))
        d.text((bx0 + 40, by0 + 62), "$ ", font=f, fill=tuple(int(c * k3) for c in FROG), anchor="ls")
        d.text((bx0 + 40 + d.textlength("$ ", font=f), by0 + 62), line, font=f, fill=tuple(int(c * k3) for c in FG), anchor="ls")
        d.text((W / 2, by0 + 170), "Free and open source. Frog Cloud when you want more.", font=sans(40, False), fill=tuple(int(c * k3) for c in MUTED), anchor="ms")
    fo = seg(t, DUR - 1.0, DUR)
    return dim(img, fo) if fo > 0 else img

SHOTS = {"open": s_open, "type": s_type, "mac": s_mac, "cloud": s_cloud, "stream": s_stream, "sandbox": s_sandbox,
         "parallel": s_parallel, "pr": s_pr, "price": s_price, "credit": s_credit, "end": s_end}

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

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

@lru_cache(1)
def mac_menu():
    """the Mac composer's where menu (This Mac, then Frog Cloud) on a black margin, so the
    words above clear it."""
    m = load("docs/design/composer/mac-where-menu-dark.png")
    c = Image.new("RGB", (2300, 1500), CANVAS); c.paste(m, (382, 380))
    return c

# ---- shots. Each draws the frame at time t; lt = seconds into the shot.
def typed_line(d, xy, text, font, k, cursor_on, anchor="ls", parts=None):
    """text typed on: the first k (0..1) of it, then a green block cursor."""
    n = int(round(len(text) * k)); shown = text[:n]
    x, y = xy
    if anchor == "ms": x -= d.textlength(text, font=font) / 2
    cx = x
    for seg_text, green in (parts or [(text, False)]):
        piece = shown[:len(seg_text)]; shown = shown[len(seg_text):]
        if piece: d.text((cx, y), piece, font=font, fill=FROG if green else FG, anchor="ls")
        cx += d.textlength(piece, font=font)
    if cursor_on:
        a = d.textbbox((cx, y), "M", font=font, anchor="ls")
        d.rectangle([cx + 6, a[1], cx + 6 + font.size * 0.45, a[3]], fill=FROG)

def s_open(t, lt):
    img = Image.new("RGB", (W, H), CANVAS); d = ImageDraw.Draw(img)
    line = "Your agent shouldn't run out."
    k = seg(lt, 0.6, 2.6)
    blink = (int(lt / BEAT) % 2 == 0) or 0 < k < 1
    typed_line(d, (W / 2, H / 2 + 40), line, sans(112), k, blink, anchor="ms")
    return img

def s_mine(t, lt):
    src = mac_menu()
    z = lerp(1.0, 1.08, seg(lt, 0, 8 * BEAT))
    img, cam = view(src, 1150, 1500, z)
    img = scrim(img, "top", 360)
    words(img, t, B(CUT["mine"]) + 0.05, [("Open models, on the ", False), ("Mac you have.", True)], where="top",
          sub="$0 a token." if t >= B(CUT["mine"] + 3) else None)
    return img

@lru_cache(1)
def machines():
    """the Mac's Settings › Models, Machines section only (this Mac and a paired RTX 3090), on a
    black margin. The rows below it (account, credit) are left out."""
    m = load("docs/design/parity/models-settings-mac-dark.png").crop((0, 0, 1240, 312))
    mask = Image.new("L", m.size, 0); ImageDraw.Draw(mask).rounded_rectangle([0, 0, m.width - 1, m.height - 1], radius=28, fill=255)
    c = Image.new("RGB", (1500, 844), CANVAS); c.paste(m, (130, 330), mask)
    return c

def s_pair(t, lt):
    if t < B(CUT["pair"] + 4):
        img = Image.new("RGB", (W, H), CANVAS); d = ImageDraw.Draw(img)
        k = ease(seg(lt, 0, 0.3)) * punch(t, B(CUT["pair"]), 0.0)
        f = mono(44)
        cmd = "curl -fsSL https://frog.toys/node | sh"
        note = "# installs tang-llm, prints a pairing code"
        tw = max(d.textlength("$ " + cmd, font=f), d.textlength(note, font=f))
        x0, y0 = W / 2 - tw / 2 - 48, 450
        d.rounded_rectangle([x0, y0, W - x0, y0 + 210], radius=18, fill=CARD)
        d.text((x0 + 48, y0 + 80), "$ ", font=f, fill=FROG, anchor="ls")
        kt = seg(t, B(CUT["pair"] + 0.3), B(CUT["pair"] + 2.2))
        typed_line(d, (x0 + 48 + d.textlength("$ ", font=f), y0 + 80), cmd, f, kt, kt < 1)
        if t >= B(CUT["pair"] + 2.5):
            d.text((x0 + 48, y0 + 150), note, font=f, fill=FAINT, anchor="ls")
        words(img, t, B(CUT["pair"]) + 0.05, [("Add a machine.", False)], where="top")
        return img
    src = machines()
    z = lerp(1.0, 1.1, seg(t, B(CUT["pair"] + 4), B(CUT["swarm"]))) * punch(t, B(CUT["pair"] + 4), 0.04)
    img, cam = view(src, 750, 500, z)
    words(img, t, B(CUT["pair"] + 4) + 0.05, [("It joins the ", False), ("pool.", True)], where="top")
    return img

def s_swarm(t, lt):
    i = 4 + int(seg(t, B(CUT["swarm"]), B(CUT["swarm"] + 10)) * 27)  # the live turn, first read to the ask
    src = web("stream", i)
    k = ease(seg(lt, 0, 12 * BEAT))
    img, cam = view(src, lerp(0, 400, k), lerp(560, 640, k), lerp(1.4, 1.25, k))
    img = scrim(img, "bottom", 360)
    words(img, t, B(CUT["swarm"]) + 0.3, [("As many agents as ", False), ("they can hold.", True)])
    return img

def s_proof(t, lt):
    img = Image.new("RGB", (W, H), CANVAS); d = ImageDraw.Draw(img)
    words(img, t, B(CUT["proof"]) + 0.05, [("More machines, ", False), ("more done.", True)], where="top", size=84)
    d = ImageDraw.Draw(img)
    stats = [(41, "tasks passed on Mac + PC", FROG), (21, "on the PC alone", FG), (0, "rate-limit errors", FROG)]
    for j, (n, label, col) in enumerate(stats):
        t0 = B(CUT["proof"] + 1 + j * 1.5)
        k = ease(seg(t, t0, t0 + 0.35))
        if k <= 0: continue
        cx = W / 2 + (j - 1) * 560
        shown = int(round(n * ease(seg(t, t0, t0 + 0.8))))
        c = tuple(int(v * k) for v in col)
        d.text((cx, 600 - (1 - k) * 24), str(shown), font=sans(240), fill=c, anchor="ms")
        d.text((cx, 680), label, font=sans(40, False), fill=tuple(int(v * k) for v in MUTED), anchor="ms")
    k = ease(seg(t, B(CUT["proof"] + 5), B(CUT["proof"] + 5.5)))
    if k > 0:
        d.text((W / 2, 930), "Six agents for 15 minutes on Qwen3-8B: an M4 Max Mac added to a PC with an RTX 3090.",
               font=sans(34, False), fill=tuple(int(v * k) for v in FAINT), anchor="ms")
    return img

def s_cloud(t, lt):
    src = web("models", 1)  # the web app's model menu: Frog Cloud's models, priced per token
    z = lerp(1.75, 1.95, seg(lt, 0, 8 * BEAT)) * punch(t, B(CUT["cloud"]), 0.06)
    img, cam = view(src, 1800, 900, z)
    img = scrim(img, "top", 420)
    words(img, t, B(CUT["cloud"]) + 0.05, [("Need more? ", False), ("Frog Cloud.", True)], where="top",
          sub="Per token, at cost plus 10%." if t >= B(CUT["cloud"] + 2) else None)
    return img

def s_pr(t, lt):
    t0 = B(CUT["pr"])
    title = [("Then it opens the ", False), ("pull request.", True)]
    if t >= B(CUT["pr"] + 5.5):
        img = Image.new("RGB", (W, H), CANVAS)
        g = load("docs/design/composer/mac-git-pr-dark.png")  # the Mac composer: the PR, checking
        k = ease(seg(t, B(CUT["pr"] + 5.5), B(CUT["pr"] + 6.2)))
        s = lerp(1.14, 1.24, seg(t, B(CUT["pr"] + 5.5), B(CUT["free"])))
        paste_center(img, g.resize((int(g.width * s), int(g.height * s)), Image.LANCZOS), W / 2, H / 2 + 40, k)
        words(img, t, t0 + 0.05, title, where="top")
        return img
    src = web("inspector", 0)
    k = ease(seg(t, t0 + BEAT, B(CUT["pr"] + 4)))
    img, cam = view(src, lerp(1280, 2100, k), lerp(720, 1100, k), lerp(1.0, 1.7, k))
    img = scrim(img, "top", 400)
    bx, by = to_screen(cam, 2322, 1373)
    m = ease(seg(t, B(CUT["pr"] + 2), B(CUT["pr"] + 4)))
    press = seg(t, B(CUT["pr"] + 4), B(CUT["pr"] + 5))
    cursor(img, lerp(bx - 420, bx, m), lerp(by - 260, by, m), press)
    words(img, t, t0 + 0.05, title, where="top")
    return img

def s_free(t, lt):
    img = Image.new("RGB", (W, H), CANVAS); d = ImageDraw.Draw(img)
    k = ease(seg(lt, 0, 0.35))
    d.text((W / 2, H / 2 + 10 - (1 - k) * 24), "Free and open source.", font=sans(130), fill=tuple(int(c * k) for c in FG), anchor="ms")
    k2 = ease(seg(lt, 2 * BEAT, 2 * BEAT + 0.35))
    d.text((W / 2, H / 2 + 110), "MIT or Apache-2.0. Fork it, build on it.", font=sans(52, False), fill=tuple(int(c * k2) for c in MUTED), anchor="ms")
    return img

def s_end(t, lt):
    img = Image.new("RGB", (W, H), CANVAS)
    d = ImageDraw.Draw(img)
    k = ease(seg(lt, 0, 0.6)); s = punch(t, B(CUT["end"]), 0.08)
    paste_center(img, mark(int(220 * s)), W / 2, 250, k)
    k1 = ease(seg(lt, 1 * BEAT, 1 * BEAT + 0.4))
    if k1 > 0:
        f = sans(88); parts = [("No caps. ", True), ("Your machines. One agent.", False)]
        x = W / 2 - sum(d.textlength(p, font=f) for p, _ in parts) / 2
        for p, g in parts:
            d.text((x, 510 - (1 - k1) * 18), p, font=f, fill=tuple(int(c * k1) for c in (FROG if g else FG)), anchor="ls"); x += d.textlength(p, font=f)
    k3 = ease(seg(lt, 4 * BEAT, 4 * BEAT + 0.4))
    if k3 > 0:
        line = "curl -fsSL https://frog.toys/install.sh | sh"
        f = mono(40); tw = d.textlength("$ " + line, font=f)
        bx0, by0 = W / 2 - tw / 2 - 40, 600
        d.rounded_rectangle([bx0, by0, W - bx0, by0 + 96], radius=16, fill=tuple(int(c * k3) for c in CARD))
        d.text((bx0 + 40, by0 + 62), "$ ", font=f, fill=tuple(int(c * k3) for c in FROG), anchor="ls")
        d.text((bx0 + 40 + d.textlength("$ ", font=f), by0 + 62), line, font=f, fill=tuple(int(c * k3) for c in FG), anchor="ls")
    k4 = ease(seg(lt, 5 * BEAT, 5 * BEAT + 0.4))
    if k4 > 0:
        d.text((W / 2, 840 - (1 - k4) * 16), "frog.toys", font=sans(96), fill=tuple(int(c * k4) for c in FG), anchor="ms")
    fo = seg(t, DUR - 1.0, DUR)
    return dim(img, fo) if fo > 0 else img

SHOTS = {"open": s_open, "mine": s_mine, "pair": s_pair, "swarm": s_swarm, "proof": s_proof,
         "cloud": s_cloud, "pr": s_pr, "free": s_free, "end": s_end}

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

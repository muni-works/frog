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

# ---- layout: the title zone on top, the UI as a card with a margin, the section label below
CARD_BOX = (222, 200, 1698, 1030)  # 1476 x 830, 16:9
LABELS = {"mine": "01  Your Mac", "pair": "02  Your machines", "swarm": "03  Agents", "proof": "04  Measured",
          "cloud": "05  Frog Cloud", "pr": "06  Pull request", "free": "07  Open source"}

def hud(img, name):
    """the section label, bottom left: the one thing that carries across the cuts."""
    if name not in LABELS: return
    d = ImageDraw.Draw(img)
    n, label = LABELS[name].split("  ")
    d.text((120, 1062), n, font=mono(24, True), fill=FROG, anchor="ls")
    d.text((120 + 52, 1062), label, font=mono(24), fill=FAINT, anchor="ls")

def persp_coeffs(src, dst):
    """PIL PERSPECTIVE coefficients mapping output points dst to input points src."""
    A, bvec = [], []
    for (x, y), (u, v) in zip(dst, src):
        A.append([x, y, 1, 0, 0, 0, -u * x, -u * y]); bvec.append(u)
        A.append([0, 0, 0, x, y, 1, -v * x, -v * y]); bvec.append(v)
    return np.linalg.solve(np.array(A, float), np.array(bvec, float)).tolist()

def card(img, ui, tilt=0.0):
    """paste a UI frame as a rounded card in CARD_BOX; tilt 0..1 turns it into a 3/4 view."""
    x0, y0, x1, y1 = CARD_BOX; w, h = x1 - x0, y1 - y0
    c = ui.convert("RGBA")
    m = Image.new("L", (w, h), 0); ImageDraw.Draw(m).rounded_rectangle([0, 0, w - 1, h - 1], radius=22, fill=255)
    c.putalpha(m)
    ImageDraw.Draw(c).rounded_rectangle([0, 0, w - 1, h - 1], radius=22, outline=LINE + (255,), width=2)
    if tilt > 0:
        dx, dy = 0.10 * w * tilt, 0.09 * h * tilt
        dst = [(0, 0), (w - dx, dy), (w - dx, h - dy), (0, h)]
        c = c.transform((w, h), Image.PERSPECTIVE, persp_coeffs([(0, 0), (w, 0), (w, h), (0, h)], dst), Image.BICUBIC)
    img.paste(c, (x0, y0), c)

def card_view(src, cx, cy, z):
    ui, cam = view(src, cx, cy, z, out=(CARD_BOX[2] - CARD_BOX[0], CARD_BOX[3] - CARD_BOX[1]))
    return ui, cam

def card_to_screen(cam, x, y):
    sx, sy = to_screen(cam, x, y)
    return CARD_BOX[0] + sx, CARD_BOX[1] + sy

def glow(img, lay, r=18, k=1.0):
    """blur-and-add glow from a drawn layer. Used once: the bench numbers."""
    g = lay.filter(ImageFilter.GaussianBlur(r))
    arr = np.asarray(img, np.float32) + np.asarray(g, np.float32)[..., :3] * (np.asarray(g, np.float32)[..., 3:] / 255) * 0.9 * k
    img.paste(Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8)))
    img.paste(lay, (0, 0), lay)

def callout(img, pt, label, t, t0, dx=150, dy=-90):
    """a dot on the thing, a leader line, a green label: grows in over a third of a beat."""
    k = ease(seg(t, t0, t0 + BEAT / 2))
    if k <= 0: return
    d = ImageDraw.Draw(img)
    x, y = pt; ex, ey = x + dx * k, y + dy * k
    d.ellipse([x - 7, y - 7, x + 7, y + 7], fill=FROG)
    d.line([(x, y), (ex, ey), (ex + 30 * k, ey)], fill=FROG, width=3)
    if k > 0.6:
        d.text((ex + 42, ey), label, font=sans(38), fill=tuple(int(c * seg(k, 0.6, 1)) for c in FROG), anchor="lm")

def on_beat(t, b0, n, every=1.0):
    """how many of n steps have landed by t, one every `every` beats from beat b0."""
    return max(0, min(n, int((t - B(b0)) / (BEAT * every)) + 1)) if t >= B(b0) else 0

@lru_cache(1)
def mac_menu():
    """the Mac composer's where menu (This Mac, then Frog Cloud) on a black margin, so the
    words above clear it."""
    m = load("docs/design/composer/mac-where-menu-dark.png")
    c = Image.new("RGB", (2300, 1500), CANVAS); c.paste(m, (382, 380))
    return c

@lru_cache(2)
def machines(rows):
    """the Mac's Settings › Models › Machines, cut to the header and `rows` rows (1: this Mac;
    2: and the paired RTX 3090). The account and credit rows below it are left out."""
    m = load("docs/design/parity/models-settings-mac-dark.png").crop((0, 0, 1240, 205 if rows == 1 else 312))
    mask = Image.new("L", m.size, 0); ImageDraw.Draw(mask).rounded_rectangle([0, 0, m.width - 1, m.height - 1], radius=28, fill=255)
    c = Image.new("RGB", (1500, 844), CANVAS); c.paste(m, (130, 330), mask)
    return c

# ---- shots. Each draws the frame at time t; lt = seconds into the shot.
def s_open(t, lt):
    img = Image.new("RGB", (W, H), CANVAS)
    lay = Image.new("RGBA", (W, H), (0, 0, 0, 0)); d = ImageDraw.Draw(lay)
    f = sans(124)
    parts = [("Your ", False), ("agent ", False), ("shouldn't ", False), ("run out.", True)]
    x = W / 2 - sum(d.textlength(p, font=f) for p, _ in parts) / 2
    for i, (p, g) in enumerate(parts):  # a word a beat, landing whole
        k = ease(seg(t, B(i), B(i) + 0.2))
        if k > 0:
            d.text((x, H / 2 + 40 - (1 - k) * 22), p, font=f, fill=(FROG if g else FG) + (int(255 * k),), anchor="ls")
        x += d.textlength(p, font=f)
    img.paste(lay, (0, 0), lay)
    return img

def s_mine(t, lt):
    src = mac_menu()
    z = lerp(1.0, 1.07, seg(lt, 0, 4 * BEAT)) * punch(t, B(CUT["mine"]), 0.04)
    img, cam = view(src, 1150, 1500, z)
    img = scrim(img, "top", 360)
    words(img, t, B(CUT["mine"]), [("Open models, on the ", False), ("Mac you have.", True)], where="top",
          sub="$0 a token." if t >= B(CUT["mine"] + 2) else None)
    return img

def s_pair(t, lt):
    b = CUT["pair"]
    if t < B(b + 2):
        img = Image.new("RGB", (W, H), CANVAS); d = ImageDraw.Draw(img)
        f = mono(44)
        cmd = "curl -fsSL https://frog.toys/node | sh"
        note = "# installs tang-llm, prints a pairing code"
        tw = max(d.textlength("$ " + cmd, font=f), d.textlength(note, font=f))
        x0, y0 = W / 2 - tw / 2 - 48, 450
        d.rounded_rectangle([x0, y0, W - x0, y0 + 210], radius=18, fill=CARD)
        d.text((x0 + 48, y0 + 80), "$ ", font=f, fill=FROG, anchor="ls")
        d.text((x0 + 48 + d.textlength("$ ", font=f), y0 + 80), cmd, font=f, fill=FG, anchor="ls")
        if t >= B(b + 1):
            d.text((x0 + 48, y0 + 150), note, font=f, fill=FAINT, anchor="ls")
        words(img, t, B(b), [("Add a machine.", False)], where="top")
        return img
    rows = 2 if t >= B(b + 4) else 1
    src = machines(rows)
    img, cam = view(src, 750, 500, 1.0 * punch(t, B(b + 4), 0.035))
    if rows == 2:
        x, y = to_screen(cam, 130 + 560, 330 + 306)  # under the paired PC's row
        callout(img, (x, y), "joined", t, B(b + 4), dx=0, dy=110)
    words(img, t, B(b + 2), [("Add a machine.", False)], where="top", t1=B(b + 4))
    words(img, t, B(b + 4), [("It joins the ", False), ("pool.", True)], where="top")
    return img

def s_swarm(t, lt):
    b = CUT["swarm"]
    i = min(31, 4 + 2 * on_beat(t, b, 16, 0.5))  # the live turn steps forward every half beat
    src = web("stream", i)
    img = Image.new("RGB", (W, H), CANVAS)
    k = ease(seg(t, B(b), B(b + 2)))  # the one perspective move: a 3/4 view that turns flat
    ui, cam = card_view(src, 1100, 640, lerp(1.0, 1.08, seg(lt, 0, 8 * BEAT)))
    card(img, ui, tilt=1 - k)
    words(img, t, B(b), [("As many agents as ", False), ("they can hold.", True)], where="top")
    return img

def s_proof(t, lt):
    b = CUT["proof"]
    img = Image.new("RGB", (W, H), CANVAS)
    if t < B(b + 4):  # the dip: the claim alone, then the numbers hit on the drop
        d = ImageDraw.Draw(img)
        k = ease(seg(t, B(b), B(b) + 0.25)); f = sans(124)
        parts = [("More machines, ", False), ("more done.", True)]
        x = W / 2 - sum(d.textlength(p, font=f) for p, _ in parts) / 2
        for p, g in parts:
            d.text((x, H / 2 + 40), p, font=f, fill=tuple(int(c * k) for c in (FROG if g else FG)), anchor="ls"); x += d.textlength(p, font=f)
        return img
    words(img, t, B(b + 4), [("More machines, ", False), ("more done.", True)], where="top", size=84)
    lay = Image.new("RGBA", (W, H), (0, 0, 0, 0)); d = ImageDraw.Draw(lay)
    stats = [(41, "tasks passed on Mac + PC", FROG, b + 4), (21, "on the PC alone", FG, b + 6), (0, "rate-limit errors", FROG, b + 8)]
    for j, (n, label, col, sb) in enumerate(stats):
        if t < B(sb): continue
        k = ease(seg(t, B(sb), B(sb) + 0.18))
        shown = n if t >= B(sb + 1) else int(n * seg(t, B(sb), B(sb + 1)))  # lands on the next beat and holds
        cx = W / 2 + (j - 1) * 560
        d.text((cx, 610 - (1 - k) * 30), str(shown), font=sans(260), fill=col + (int(255 * k),), anchor="ms")
        d.text((cx, 690), label, font=sans(40, False), fill=MUTED + (int(255 * k),), anchor="ms")
    glow(img, lay, 22, ease(seg(t, B(b + 4), B(b + 5))))
    if t >= B(b + 10):
        k = ease(seg(t, B(b + 10), B(b + 10) + 0.3))
        ImageDraw.Draw(img).text((W / 2, 930), "Six agents for 15 minutes on Qwen3-8B: an M4 Max Mac added to a PC with an RTX 3090.",
                                 font=sans(34, False), fill=tuple(int(c * k) for c in FAINT), anchor="ms")
    return img

def s_cloud(t, lt):
    b = CUT["cloud"]
    img = Image.new("RGB", (W, H), CANVAS)
    ui, cam = card_view(web("models", 1), 1870, 960, 2.35)  # a hold, after the push and the turn
    card(img, ui)
    words(img, t, B(b), [("Need more? ", False), ("Frog Cloud.", True)], where="top",
          sub="Per token, at cost plus 10%." if t >= B(b + 2) else None)
    return img

def s_pr(t, lt):
    b = CUT["pr"]
    title = [("Then it opens the ", False), ("pull request.", True)]
    img = Image.new("RGB", (W, H), CANVAS)
    if t >= B(b + 8):
        g = load("docs/design/composer/mac-git-pr-dark.png")  # the Mac composer: the PR, its checks running
        s = 1.14 * punch(t, B(b + 8), 0.03)
        gi = g.resize((int(g.width * s), int(g.height * s)), Image.LANCZOS)
        paste_center(img, gi, W / 2, H / 2 + 40)
        gx0, gy0 = W / 2 - gi.width / 2, H / 2 + 40 - gi.height / 2
        callout(img, (gx0 + 1277 * s, gy0 + 96 * s), "checks running", t, B(b + 9), dx=-90, dy=-170)
        words(img, t, B(b), title, where="top")
        hud(img, "pr")
        return img
    k = ease(seg(t, B(b + 1), B(b + 5)))
    ui, cam = card_view(web("inspector", 0), lerp(1280, 2050, k), lerp(720, 1080, k), lerp(1.0, 1.8, k))
    card(img, ui)
    bx, by = card_to_screen(cam, 2322, 1373)
    m = ease(seg(t, B(b + 4), B(b + 5)))
    press = seg(t, B(b + 5), B(b + 6))  # the click lands on beat b + 5
    cursor(img, lerp(bx - 420, bx, m), lerp(by - 260, by, m), press)
    words(img, t, B(b), title, where="top")
    return img

def s_free(t, lt):
    img = Image.new("RGB", (W, H), CANVAS); d = ImageDraw.Draw(img)
    b = CUT["free"]
    k = ease(seg(t, B(b), B(b) + 0.25))
    d.text((W / 2, H / 2 + 10 - (1 - k) * 24), "Free and open source.", font=sans(130), fill=tuple(int(c * k) for c in FG), anchor="ms")
    k2 = ease(seg(t, B(b + 2), B(b + 2) + 0.25))
    d.text((W / 2, H / 2 + 110), "MIT or Apache-2.0. Fork it, build on it.", font=sans(52, False), fill=tuple(int(c * k2) for c in MUTED), anchor="ms")
    return img

MARK_Y, MARK_SIZE = 250, 220

def s_morph(t, lt):
    """the breakdown: a green ring draws itself a quarter a beat, then fills into the mark."""
    b = CUT["morph"]
    img = Image.new("RGB", (W, H), CANVAS)
    cx, cy, r = W / 2, H / 2, 150
    q = on_beat(t, b, 4)  # quarters landed
    arc = 90 * q if t < B(b + 4) else 360
    d = ImageDraw.Draw(img)
    if t < B(b + 5):
        d.arc([cx - r, cy - r, cx + r, cy + r], -90, -90 + arc, fill=FROG, width=8)
    k = ease(seg(t, B(b + 4), B(b + 6)))  # ring -> mark, sliding up to where the end card keeps it
    if k > 0:
        y = lerp(cy, MARK_Y, ease(seg(t, B(b + 5), B(b + 6))))
        paste_center(img, mark(int(lerp(2 * r, MARK_SIZE, k))), cx, y, k)
    return img

def s_end(t, lt):
    b = CUT["end"]
    img = Image.new("RGB", (W, H), CANVAS)
    d = ImageDraw.Draw(img)
    paste_center(img, mark(int(MARK_SIZE * punch(t, B(b), 0.1))), W / 2, MARK_Y)
    k1 = ease(seg(t, B(b), B(b) + 0.2))
    f = sans(88); parts = [("No caps. ", True), ("Your machines. One agent.", False)]
    x = W / 2 - sum(d.textlength(p, font=f) for p, _ in parts) / 2
    for p, g in parts:
        d.text((x, 510 - (1 - k1) * 18), p, font=f, fill=tuple(int(c * k1) for c in (FROG if g else FG)), anchor="ls"); x += d.textlength(p, font=f)
    k3 = ease(seg(t, B(b + 2), B(b + 2) + 0.25))
    if k3 > 0:
        line = "curl -fsSL https://frog.toys/install.sh | sh"
        f = mono(40); tw = d.textlength("$ " + line, font=f)
        bx0, by0 = W / 2 - tw / 2 - 40, 600
        d.rounded_rectangle([bx0, by0, W - bx0, by0 + 96], radius=16, fill=tuple(int(c * k3) for c in CARD))
        d.text((bx0 + 40, by0 + 62), "$ ", font=f, fill=tuple(int(c * k3) for c in FROG), anchor="ls")
        d.text((bx0 + 40 + d.textlength("$ ", font=f), by0 + 62), line, font=f, fill=tuple(int(c * k3) for c in FG), anchor="ls")
    k4 = ease(seg(t, B(b + 4), B(b + 4) + 0.25))
    if k4 > 0:
        d.text((W / 2, 840 - (1 - k4) * 16), "frog.toys", font=sans(96), fill=tuple(int(c * k4) for c in FG), anchor="ms")
    fo = seg(t, DUR - 1.0, DUR)
    return dim(img, fo) if fo > 0 else img

SHOTS = {"open": s_open, "mine": s_mine, "pair": s_pair, "swarm": s_swarm, "proof": s_proof,
         "cloud": s_cloud, "pr": s_pr, "free": s_free, "morph": s_morph, "end": s_end}

def frame(f):
    t = f / FPS
    name = shot_of(t)
    img = SHOTS[name](t, t - B(CUT[name]))
    if name != "pr": hud(img, name)
    img.save(OUT / f"{f:04d}.png", compress_level=1)
    return f

if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    frames = [int(x) for x in sys.argv[2].split(",")] if len(sys.argv) > 2 else list(range(NFRAMES))
    with Pool(int(os.environ.get("NPROC", 6))) as pool:
        for i, _ in enumerate(pool.imap_unordered(frame, frames, chunksize=4)):
            if i % 200 == 0: print(f"{i}/{len(frames)}", flush=True)

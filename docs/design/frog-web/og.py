# frog.toys social preview (apps/web/public/og.png and og.mp4; run: python3 og.py [frames], then
# ffmpeg -framerate 24 -i frames/%04d.png -c:v libx264 -pix_fmt yuv420p -crf 26 -movflags +faststart og.mp4): the home page's night pond (perspective ripples, lily pads,
# amber fireflies) with the frog and the line. Still: og.png. Loop: frames/ for ffmpeg.
import math, random, sys, os
from PIL import Image, ImageDraw, ImageFilter, ImageFont

W, H = 1200, 630
BG = (22, 22, 22)
GREEN = (88, 204, 111)
AMBER = (255, 176, 64)
HORIZON = H * 0.40
random.seed(7)
mark = Image.open('/private/tmp/claude-501/og/mark.png').convert('RGBA')
font = lambda size, w=700: ImageFont.truetype('/System/Library/Fonts/SFNS.ttf', size)
def ft(size, weight):
    f = ImageFont.truetype('/Users/cam/Library/Fonts/Inter-VariableFont_opsz,wght.ttf', size)
    f.set_variation_by_axes([32 if size > 30 else 14, weight])
    return f

depth = lambda y: max(0.15, (y - HORIZON) / (H - HORIZON))
pads = [dict(x=random.uniform(0, W), y=random.uniform(HORIZON + 60, H - 10), r=random.uniform(22, 40), a=random.uniform(0, 6.28), notch=random.uniform(.4, .6), ph=random.uniform(0, 9)) for _ in range(7)]
flies = [dict(x=random.uniform(60, W - 60), y=random.uniform(H * .12, H * .8), ph=random.uniform(0, 9), sp=random.uniform(.6, 1.3), dx=random.uniform(-14, 14), dy=random.uniform(-8, 8)) for _ in range(6)]
drops = [dict(x=random.uniform(W * .1, W * .9), y=random.uniform(HORIZON + 30, H - 20), t0=i * 0.75, size=random.uniform(120, 230)) for i in range(6)]
LOOP = 4.5  # seconds; everything below is periodic in it

def frame(t):
    img = Image.new('RGB', (W, H), BG)
    layer = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    # Glints on the water.
    for i in range(34):
        gy = HORIZON + ((i * 97) % 100) / 100 * (H - HORIZON)
        gx = ((i * 233 + t / LOOP * (W + 160) * (1 + i % 3)) % (W + 160)) - 80
        ln = 12 + depth(gy) * 60
        a = int(255 * (0.04 + 0.05 * (0.5 + 0.5 * math.sin(2 * math.pi * t / LOOP + i))))
        d.line([(gx, gy), (gx + ln, gy)], fill=GREEN + (a,), width=1)
    # Ripples: three rings per drop, flattened by depth, fading as they spread.
    for r in drops:
        p0 = ((t - r['t0']) % LOOP) / LOOP
        for k in range(3):
            p = p0 - k * 0.09
            if p <= 0: continue
            e = 1 - (1 - p) ** 3
            rx = e * r['size'] * depth(r['y']) * 1.6
            ry = rx * 0.28
            a = int(255 * (1 - p) ** 1.6 * 0.34 * (1 - k * 0.28))
            d.ellipse([r['x'] - rx, r['y'] - ry, r['x'] + rx, r['y'] + ry], outline=GREEN + (a,), width=max(1, int(1.5 * depth(r['y']))))
    # Lily pads, bobbing.
    for pd in pads:
        dd = depth(pd['y'])
        bob = math.sin(2 * math.pi * t / LOOP + pd['ph']) * 1.6 * dd
        rx, ry = pd['r'] * dd * 1.6, pd['r'] * dd * 1.6 * 0.34
        cx, cy = pd['x'], pd['y'] + bob
        start = math.degrees(pd['a'] + pd['notch'] / 2); end = math.degrees(pd['a'] + 2 * math.pi - pd['notch'] / 2)
        d.pieslice([cx - rx, cy - ry, cx + rx, cy + ry], start, end, fill=GREEN + (int(255 * (0.08 + 0.06 * dd)),), outline=GREEN + (int(255 * (0.2 + 0.1 * dd)),))
    img.paste(layer, (0, 0), layer)
    # Fireflies: soft amber glows.
    glow = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    g = ImageDraw.Draw(glow)
    for f in flies:
        ang = 2 * math.pi * t / LOOP
        x = f['x'] + math.sin(ang + f['ph']) * f['dx']
        y = f['y'] + math.cos(ang * 1 + f['ph']) * f['dy']
        pulse = max(0, math.sin(ang * f['sp'] * 2 + f['ph'])) ** 2
        rad = 10 + pulse * 10
        g.ellipse([x - rad, y - rad, x + rad, y + rad], fill=AMBER + (int(255 * (0.10 + pulse * 0.35)),))
        g.ellipse([x - 1.6, y - 1.6, x + 1.6, y + 1.6], fill=AMBER + (int(255 * min(.95, .2 + pulse * .8)),))
    glow = glow.filter(ImageFilter.GaussianBlur(4))
    img.paste(glow, (0, 0), glow)
    # Vignette, so the edges fall away like the home page.
    vig = Image.new('L', (W, H), 0)
    vd = ImageDraw.Draw(vig)
    for i in range(60):
        vd.rectangle([i * 6, i * 4, W - i * 6, H - i * 4], outline=int(255 * (1 - i / 60) ** 2 * 0.55))
    img.paste(Image.new('RGB', (W, H), BG), (0, 0), vig.filter(ImageFilter.GaussianBlur(30)))
    # The frog and the words.
    top = 128
    img.paste(mark, (W // 2 - mark.width // 2, top), mark)
    d2 = ImageDraw.Draw(img)
    h1 = ft(58, 700); sub = ft(25, 400); url = ft(21, 600)
    line = 'Hand it off. Come back to a PR.'
    tw = d2.textlength(line, font=h1)
    d2.text((W / 2 - tw / 2, top + mark.height + 40), line, font=h1, fill=(236, 236, 236))
    s2 = 'A coding agent in its own cloud machine, on open models.'
    sw = d2.textlength(s2, font=sub)
    d2.text((W / 2 - sw / 2, top + mark.height + 122), s2, font=sub, fill=(155, 155, 155))
    uw = d2.textlength('frog.toys', font=url)
    d2.text((W / 2 - uw / 2, H - 58), 'frog.toys', font=url, fill=GREEN)
    return img

out = '/private/tmp/claude-501/og'
frame(1.2).save(f'{out}/og.png', optimize=True)
if len(sys.argv) > 1:
    os.makedirs(f'{out}/frames', exist_ok=True)
    fps = 24
    for i in range(int(LOOP * fps)):
        frame(i / fps).save(f'{out}/frames/{i:04d}.png')

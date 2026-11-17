#!/usr/bin/env python3
"""The reel's music: an original track, synthesized here from sine, saw and noise, on the same
beat grid as the picture (beats.py). No samples, no recordings.

usage: music.py <out.wav>

Sections follow the cuts: intro (pad and pluck) under the opening line, drop 1 when a second
machine joins, a break under the bench numbers, drop 2 from Frog Cloud to the free beat, then the
end card rings out.
Am - F - C - G, one chord per bar (4 beats)."""
import sys, wave
import numpy as np
from beats import B, BEAT, DUR, CUT

SR = 48000
N = int(DUR * SR)
rng = np.random.default_rng(7)  # fixed seed: the same wav every run
mix = np.zeros((N, 2))


def note(m): return 440.0 * 2 ** ((m - 69) / 12)

CHORDS = [[57, 60, 64], [53, 57, 60], [48, 52, 55], [55, 59, 62]]  # Am F C G (midi)
BASS = [45, 41, 36, 43]


def chord_at(beat): return int(beat // 4) % 4


def add(sig, t0, gain=1.0, pan=0.0):
    i0 = int(t0 * SR)
    if i0 >= N: return
    sig = sig[: N - i0]
    l, r = np.sqrt(0.5 * (1 - pan)), np.sqrt(0.5 * (1 + pan))
    mix[i0:i0 + len(sig), 0] += sig * gain * l
    mix[i0:i0 + len(sig), 1] += sig * gain * r


def env(n, a, d, s=0.0, rel=None):
    t = np.arange(n) / SR
    e = np.minimum(1, t / max(a, 1e-4))
    e = np.where(t > a, s + (1 - s) * np.exp(-(t - a) / d), e)
    if rel: e *= np.clip((n / SR - t) / rel, 0, 1)
    return e


def saw(f, n, detune=0.0):
    t = np.arange(n) / SR
    out = np.zeros(n)
    for d in (-detune, 0, detune):
        ph = (t * f * (1 + d)) % 1.0
        out += 2 * ph - 1
    return out / 3


def lowpass(x, cutoff):
    """one-pole low-pass; cutoff may be an array (a sweep)."""
    a = np.exp(-2 * np.pi * np.broadcast_to(cutoff, x.shape) / SR)
    y = np.empty_like(x); acc = 0.0
    for i in range(len(x)):  # short signals only
        acc = (1 - a[i]) * x[i] + a[i] * acc; y[i] = acc
    return y


def kick():
    n = int(0.45 * SR); t = np.arange(n) / SR
    f = 45 + 110 * np.exp(-t * 28)
    return np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t * 7) + 0.3 * np.sin(2 * np.pi * 3000 * t) * np.exp(-t * 300)


def hat(open_=False):
    n = int((0.25 if open_ else 0.06) * SR)
    x = rng.standard_normal(n); x = x - lowpass(x, 7000)
    return x * env(n, 0.001, 0.08 if open_ else 0.015)


def clap():
    n = int(0.3 * SR); x = rng.standard_normal(n); x = lowpass(x - lowpass(x, 900), 5000)
    e = sum(env(n, 0.001, 0.01) * (np.arange(n) >= int(k * SR)) for k in (0, 0.012, 0.024)) + env(n, 0.001, 0.12)
    return x * e * 0.6


def pluck(m, dur):
    n = int(dur * SR)
    x = saw(note(m), n, 0.003)
    return lowpass(x, 600 + 3600 * np.exp(-np.arange(n) / SR * 9)) * env(n, 0.003, 0.18)


def pad(ms, dur, bright):
    n = int(dur * SR)
    x = sum(saw(note(m), n, 0.006) for m in ms) / len(ms)
    x = lowpass(x, bright)
    return x * env(n, 0.35, 10, 1.0, rel=0.4)


def bass(m, dur):
    n = int(dur * SR); t = np.arange(n) / SR
    x = np.sin(2 * np.pi * note(m) * t) + 0.35 * saw(note(m), n)
    return lowpass(x, 500) * env(n, 0.005, 0.25, 0.5, rel=0.03)


def riser(dur):
    n = int(dur * SR); x = rng.standard_normal(n)
    x = lowpass(x, np.linspace(300, 9000, n))
    return x * np.linspace(0, 1, n) ** 2


K, H, HO, C = kick(), hat(), hat(True), clap()
DROP1, BREAK, DROP2, END = CUT["pair"], CUT["proof"], CUT["cloud"], CUT["end"]
LAST = int(DUR / BEAT)

for b in range(LAST):
    t = B(b); ch = chord_at(b); full = DROP1 <= b < BREAK or DROP2 <= b < END
    # pad: every bar, brighter in the drops, the last chord rings out on the end card
    if b % 4 == 0 and b < END:
        add(pad(CHORDS[ch], 4 * BEAT + 0.4, 1800 if full else 900), t, 0.22)
    # pluck: an eighth-note arpeggio from the intro's second bar, through the break
    if 4 <= b < END:
        arp = CHORDS[ch] + [CHORDS[ch][0] + 12]
        for h in range(2):
            add(pluck(arp[(2 * b + h) % 4] + 12, 0.3), t + h * BEAT / 2, 0.16 if full else 0.12, pan=-0.3 if h else 0.3)
    if full:
        add(K, t, 0.9)
        add(bass(BASS[ch], BEAT / 2), t + BEAT / 2, 0.45)
        add(bass(BASS[ch], BEAT / 2 - 0.02), t, 0.3)
        add(H, t + BEAT / 2, 0.22, pan=0.2)
        if b % 2 == 1: add(C, t, 0.35)
    elif 8 <= b < DROP1 or BREAK <= b < DROP2:
        add(H, t + BEAT / 2, 0.15, pan=0.2)  # hats only
    if BREAK <= b < DROP2 and b % 2 == 0:
        add(K, t, 0.35)  # a soft half-time pulse under the break

# risers into each drop, an open hat on each downbeat
add(riser(4 * BEAT), B(DROP1 - 4), 0.18)
add(riser(4 * BEAT), B(DROP2 - 4), 0.18)
for b in (DROP1, DROP2, END): add(HO, B(b), 0.25)
# the end: one last hit and the tonic ringing out
add(K, B(END), 1.0)
add(pad([45, 57, 60, 64, 69], DUR - B(END), 1400), B(END), 0.3)
add(bass(33, DUR - B(END)) * np.exp(-np.arange(int((DUR - B(END)) * SR)) / SR * 0.8), B(END), 0.5)

# a little stereo room: a 23 ms slap on the right, 31 ms on the left
for ch, ms in ((0, 31), (1, 23)):
    d = int(ms / 1000 * SR); mix[d:, ch] += 0.18 * mix[:-d, 1 - ch]
# fades, then normalise to -2 dBFS peak with a soft clip (headroom for the aac encode)
fade_in = int(0.05 * SR); mix[:fade_in] *= np.linspace(0, 1, fade_in)[:, None]
fo = int(2.0 * SR); mix[-fo:] *= np.linspace(1, 0, fo)[:, None] ** 1.5
mix = np.tanh(mix * 1.3)
mix *= 10 ** (-2 / 20) / np.max(np.abs(mix))
with wave.open(sys.argv[1], "wb") as w:
    w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR)
    w.writeframes((mix * 32767).astype("<i2").tobytes())
print(sys.argv[1], f"{DUR:.2f} s")

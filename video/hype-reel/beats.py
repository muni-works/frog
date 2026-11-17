"""The beat grid and the cut list: the one timeline the picture (comp.py) and the music share.

The grid is fitted to the track (Lackvill, "No Jumper"): 129.98 BPM, first kick at 0.098 s
(librosa beat track, a straight-line fit over 159 beats, phase checked against the kick band;
drift over 74 s is under 10 ms). B(i) is beat i's time. Every cut is a beat index.
music.py synthesizes a stand-in on the same grid for when the track isn't there.
Energy in the track: dips at beats 4-8 and 28-32, a breakdown at 72-80, the big drop at 80."""

BPM = 129.984
PHASE = 0.098
BEAT = 60 / BPM
FPS = 30
W, H = 1920, 1080


def B(i): return PHASE + i * BEAT


# shot -> first beat. Each shot runs to the next one's beat.
CUT = {
    "open": 0,     # "Your agent shouldn't run out.", a word a beat; the dip at 4-8 holds it
    "mine": 8,     # open models on the Mac you have, $0 a token
    "pair": 12,    # add a machine (12), it joins the pool (16)
    "swarm": 20,   # as many agents as they can hold
    "proof": 28,   # the dip: the title alone; the drop at 32: 41, 21, 0
    "cloud": 44,   # need more? Frog Cloud, at cost plus 10%
    "pr": 52,      # then it opens the pull request
    "free": 64,    # free and open source
    "morph": 74,   # the breakdown: a ring draws itself and becomes the mark
    "end": 80,     # the drop: No caps. Your machines. One agent. frog.toys
}
END_BEATS = 92
DUR = B(END_BEATS)  # 42.5 s
NFRAMES = int(round(DUR * FPS))

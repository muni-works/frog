"""The beat grid and the cut list: the one timeline the picture (comp.py) and the music
(music.py) share. 120 BPM, so a beat is 0.5 s, exactly 15 frames at 30 fps; B(i) is beat i's time.
Every cut is a beat index, never a timestamp. README.md has this table with each claim's source."""

BPM = 120
BEAT = 60 / BPM
FPS = 30
W, H = 1920, 1080


def B(i): return i * BEAT


# shot -> first beat. Each shot runs to the next one's beat.
CUT = {
    "open": 0,     # "Your agent shouldn't run out."
    "mine": 8,     # open models on the Mac you have, $0 a token
    "pair": 16,    # drop 1: add a machine, it joins the pool
    "swarm": 24,   # as many agents as they can hold
    "proof": 36,   # break: the bench, 41 vs 21, 0 rate-limit errors
    "cloud": 44,   # drop 2: need more? Frog Cloud, at cost plus 10%
    "pr": 52,      # then it opens the pull request
    "free": 60,    # free and open source
    "end": 68,     # No caps. Your machines. One agent. frog.toys
}
END_BEATS = 80
DUR = B(END_BEATS)  # 40.0 s
NFRAMES = int(round(DUR * FPS))

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
    "open": 0,       # the mark lands
    "type": 4,       # the prompt is typed on the web
    "mac": 16,       # drop 1: on your Mac
    "cloud": 20,     # or in Frog Cloud
    "stream": 24,    # it reads, runs and edits
    "sandbox": 36,   # break: every session in its own sandbox
    "parallel": 44,  # drop 2: five at once, laptop closed
    "pr": 52,        # it opens the pull request
    "price": 60,     # pay per token
    "credit": 64,    # $1 free credit, no plan needed
    "end": 68,       # mascot, frog.toys, the install line
}
END_BEATS = 80
DUR = B(END_BEATS)  # 40.0 s
NFRAMES = int(round(DUR * FPS))

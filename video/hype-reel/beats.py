"""The beat grid and the cut list: the one timeline the picture (comp.py) and the music share.

The grid is fitted to the track (Jack Harlow, "WHATS POPPIN"): 144.99 BPM, first beat at 0.034 s
(librosa beat track, period and phase refined against the kick band). B(i) is beat i's time.
Every cut is a beat index. The track's shape: a bass-free intro for beats 0-16, the bass drops
at 16, a small dip at 44-48, and a breakdown from 80. The reel ends in that breakdown.
music.py synthesizes a stand-in on the same grid for when the track isn't there."""

BPM = 144.9875
PHASE = 0.0345
BEAT = 60 / BPM
FPS = 30
W, H = 1920, 1080


def B(i): return PHASE + i * BEAT


# shot -> first beat. Each shot runs to the next one's beat.
CUT = {
    "open": 0,     # the intro: another agent hits its usage limit; the frog hops in on "hopped in"
    "mine": 16,    # the bass drops: open models on the Mac you have, $0 a token
    "pair": 24,    # add a machine (24), it joins the pool (28)
    "swarm": 32,   # six frogs, a landing a beat: as many agents as they can hold
    "how": 40,     # how the pool works: calls find a machine; at 48 one drops out and the turn survives
    "price": 52,   # Frog Cloud's three models next to other providers' list prices
    "setup": 64,   # it brings your setup: CLAUDE.md, skills, MCP servers
    "own": 72,     # nobody can cap what you own: the limit notice bounces off on 76
    "end": 80,     # the breakdown: No caps. Your machines. One agent. frog.toys
}
# Words in the track the picture answers (whisper word timings, seconds):
ASK = 1.10            # "What's poppin'?": the question lands in the other agent's chat
JUMP = (2.76, 3.28)   # "just hopped in": the frog leaves the ground on "just" and lands as the line ends
OPTIONS = 4.00        # "I got options": the title turns to "You've got options."
END_BEATS = 88
DUR = B(END_BEATS)  # 36.45 s
NFRAMES = int(round(DUR * FPS))

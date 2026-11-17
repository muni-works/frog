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
    "open": 0,     # another agent hits its usage limit; the frog hops in on "no jumper" (2.5-3.1 s)
    "mine": 8,     # open models on the Mac you have, $0 a token
    "pair": 12,    # add a machine (12), it joins the pool (16)
    "swarm": 20,   # six frogs, a landing a beat: as many agents as they can hold
    "how": 28,     # how the pool works; the drop at 32 starts the calls; 36 a machine drops out; 40 the bench
    "price": 44,   # Frog Cloud's three models next to other providers' list prices
    "setup": 52,   # it brings your setup: CLAUDE.md, skills, MCP servers
    "own": 60,     # nobody can cap what you own: the limit card bounces off
    "morph": 72,   # the breakdown: ripples, then the frog
    "end": 80,     # the drop: No caps. Your machines. One agent. frog.toys
}
# "no jumper", as sung in the track (whisper word timings): the frog leaves the ground on "no"
# and lands as "jumper" ends.
JUMP = (2.50, 2.98)
END_BEATS = 92
DUR = B(END_BEATS)  # 42.5 s
NFRAMES = int(round(DUR * FPS))

# Frog hype reel

A 42.6 second, 1920x1080, 30 fps reel telling the "no caps" story, rendered entirely from code.
It uses real frames of the web app (captured from a mock gateway in headless Chrome) and the Mac
app's checked-in snapshots. A compositor moves them, with every animation a pure function of time,
cut to the beat grid of the track it is timed to (see Music). No screen recording, no generative models, no paid
services; it renders on a Mac's CPU in a few minutes.

The pipeline is the board video's (vcad `hardware/pcb-motor-video/`): beat grid, pure-function
compositor, contact sheets, ffmpeg encode. The footage step is new.

![contact sheet](contact-sheet.png)

## Re-render

```bash
TRACK=~/Downloads/"Lackvill - No Jumper.mp3" video/hype-reel/render.sh
```

It composites `build/frames/`, prepares `build/music.wav` (the track, or the synthesized
stand-in without `TRACK`) and encodes `frog-hype-reel.mp4`
(h264 crf 17, aac 256k), then writes `contact-sheet.png` from the mp4. Needs `uv`, `ffmpeg` and
`rsvg-convert`; Python deps are pinned in the script. `NPROC` (default 6) sets the workers.
The mp4, `build/` and `footage/` are not committed (`.gitignore`).

## Recapture the footage

```bash
video/hype-reel/capture/run.sh
```

Run it after the web app changes, then `render.sh`. It starts `capture/gateway.mjs` (port 8811),
vite dev against it (port 5211) and `capture/capture.mjs`, which drives the app in headless Chrome
(its own throwaway profile; nothing opens a window or takes the keyboard) and writes
`footage/<shot>/NNNN.png` at 2560x1440. Needs `npm ci` in `apps/web` and Google Chrome.

- The gateway serves an account (no name, the $1.00 sign-up credit), the pricing page's three Frog Cloud
  models, three repos and six sessions. `s_live` plays the parity fixture
  (`docs/design/parity/fixture.jsonl`, "Fix flaky upload retry") one step per frame, up to its ask
  card; replies stream three words a step. Steps are counted, not timed, so the turn's frames come out the same; the new-session screen's
  suggestion chips are random per load, so those differ.
- Shots: `type`, `stream`, `inspector`, `models`, `docs`. The current cut uses none of the web
  frames (it leans on the frog and two Mac snapshots); they stay for the next cut. `run.sh probe` writes two stills for checking selectors.
- Mac footage is the checked-in offscreen snapshots, not a capture: `docs/design/composer/mac-new-folder-dark.png`
  (`ComposerSnapshotTests`) and `docs/design/parity/models-settings-mac-dark.png`. Re-run those
  harnesses to refresh them; they build their own copy of the app.
- The mark is `apps/web/public/frog-mark.svg`, rasterized by `run.sh`.

## Files

| file | what |
|---|---|
| `beats.py` | the beat grid (`B(i)`) and the cut list, shared by picture and music |
| `comp.py` | the compositor: one function per shot, the pond, words, chips |
| `frog.py` | the frog as a full character: poses, blink, wink, hop, squash |
| `prices.json` | the pricing shot's numbers, with a source per row and a date |
| `music.py` | the track: kick, clap, hats, bass, pad, pluck arpeggio, risers; Am F C G |
| `sheet.py` | renders chosen beats through `comp.py` into a contact sheet, for review while editing |
| `render.sh` | the one command |
| `capture/` | gateway, CDP driver, shot list, `run.sh` |
| `fonts/` | IBM Plex Sans and Mono (SIL OFL, `OFL-IBM-Plex.txt`), the app's own type |

## Beat sheet

The story is the site's own line, "No caps. Your machines. One agent.": another agent runs out;
Frog doesn't, because it runs open models on machines you own. The frog is the lead: machines
are lily pads, agents are frogs, the pool is the pond (the web app's own new-session imagery).

Cut to Lackvill, "No Jumper": 129.98 BPM, first kick at 0.098 s, so beat i is at
0.098 + i × 0.4616 s (`beats.py`). The frog's first hop is timed to the words "no jumper"
(2.50 to 2.98 s, from whisper word timings): it leaves the ground on "no" and lands as "jumper" ends.

| beats | time | shot | on screen | source of the claim |
|---|---|---|---|---|
| 0–8 | 0.1–3.8 s | an unnamed agent's task card streams, then stops on the track's dip: "Usage limit reached. Resets in 4 h 12 min", then "Buy extra usage $$$". The frog peeks over the bottom edge and hops in on "no jumper" | Your agent ran out. | a drawn, generic card: no product is named or copied |
| 8–12 | 3.8–5.6 s | the frog hops onto a lily pad, "this Mac"; the Mac composer's model chip (Qwen3 8B on this Mac) | Open models, on the Mac you have. / $0 a token. | `README.md:29`, `site/pricing.html` ("On your own machines: $0") |
| 12–20 | 5.6–9.3 s | the node install line; a second pad drifts in and settles on beat 16 with a ripple; Settings › Machines shows studio (M4 Max) and mew (RTX 3090) | Add a machine. / It joins the pool. | `README.md:13,59`, `site/index.html` (6-digit pairing code) |
| 20–28 | 9.3–13.0 s | a frog lands on a pad each beat, a counter runs to 6 | As many agents as they can hold. | `README.md:6-7` |
| 28–36 | 13.0–16.7 s | three agent frogs above two pads; from the drop at beat 32, calls travel to a pad every half beat | Each call goes where it finishes first. | `README.md:59` ("A scheduler sends each call to the machine that will finish it first") |
| 36–40 | 16.7–18.6 s | the PC's pad empties to a dashed outline; a call in flight turns round and lands on the Mac | A machine drops out. The turn survives. | `README.md:14` ("if a machine drops out mid-turn, the turn finishes on another one") |
| 40–44 | 18.6–20.4 s | 41, 21, 0, a beat apart, the reel's only glow | More machines, more done. / 41 tasks passed on Mac + PC / 21 on the PC alone / 0 rate-limit errors / the bench's setup line | `docs/no-caps-bench.md`, `site/index.html`, `README.md:15-17` |
| 44–52 | 20.4–24.1 s | bars: Frog Cloud's three models land on beats 44–46, then three other providers' bars grow at the same dollars per beat while the frog watches the tip | Need more? Frog Cloud. / the six prices / List price per million output tokens, 17 Nov 2026. Different models: this compares price only. | `prices.json` (each row's source URL) |
| 52–60 | 24.1–27.8 s | `CLAUDE.md` flies in and the frog catches it; `skills` and `MCP servers` land stacked on its head | It brings your setup. / Nothing to set up twice. | `site/index.html` "Brings your setup" |
| 60–72 | 27.8–33.3 s | the frog on its own pad inside a ring; the limit notice from the open flies in, meets the ring on beat 64 and tumbles away; the frog waves | Nobody can cap what you own. / Free and open source. Local models keep your code on your Mac. | `README.md:55` ("Your code and prompts stay on your machine unless you pick a cloud model"), License |
| 72–80 | 33.3–37.0 s | the breakdown: a ripple a beat, then the frog hops up through them | | |
| 80–92 | 37.0–42.6 s | the drop: the frog lands, the line, the install line, frog.toys; it winks on beat 88; fade | No caps. Your machines. One agent. / `curl -fsSL https://frog.toys/install.sh \| sh` / frog.toys | `README.md:3,10` |

The frog (`frog.py`) is drawn in code. Its head is the mark's own shapes and colours, read from
`apps/web/public/frog-mark.svg`; the body (belly, arms, hind legs) is new for this reel and is
not yet anywhere else in the brand. Poses: sit, hop, wave, carry, head only; it blinks, winks,
looks at things and squashes when it lands.

The pricing shot names other providers. Its numbers live in `prices.json` with a source per row
and a date; re-read the sources before publishing. Cheaper tiers exist at those providers (for
example $0.50 output models) and are not on the chart, and Frog Cloud's OpenRouter-served prices
are "from" prices. The bench shot leaves out the site's caveat that one task got slower with the
second machine (`docs/no-caps-bench.md`).

Editing rules, from the board video's notes: text lands whole, motion steps on beats, the frame
changes completely on the drops, glow is on the bench numbers only, and push-ins alternate with holds.

## Music

The cut is timed to **Lackvill, "No Jumper"** (Cam's mp3, not in the repo). It is a commercial
release: fine for a private cut, but publishing the reel needs a licence for it, or the stand-in
below. Its lyrics are explicit (profanity, a racial slur, guns), which matters for a product video. `TRACK=<path to the mp3> render.sh` uses it from its start, cut to 42.6 s, 1.5 dB down,
2 s fade. Measured on the encoded mp4: −12.6 LUFS integrated, true peak −1.3 dBFS. The grid was
fitted, not heard: nobody has checked the sync by ear.

Without `TRACK`, `music.py` synthesizes an original stand-in on the same grid (Am F C G, sine,
saw and noise, fixed seed, no samples), safe to publish but plainer.

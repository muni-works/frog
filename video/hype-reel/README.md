# Frog hype reel

A 36.5 second, 1920x1080, 30 fps reel telling the "no caps" story, rendered entirely from code.
It uses real frames of the web app (captured from a mock gateway in headless Chrome) and the Mac
app's checked-in snapshots. A compositor moves them, with every animation a pure function of time,
cut to the beat grid of the track it is timed to (see Music). No screen recording, no generative models, no paid
services; it renders on a Mac's CPU in a few minutes.

The pipeline is the board video's (vcad `hardware/pcb-motor-video/`): beat grid, pure-function
compositor, contact sheets, ffmpeg encode. The footage step is new.

![contact sheet](contact-sheet.png)

## Re-render

```bash
TRACK=~/Downloads/"Jack Harlow - WHATS POPPIN (Lyrics).mp3" video/hype-reel/render.sh
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
- No captured product pixels are left in the current cut. The composer, its model menu,
  Settings › Machines, the session list and the call list are redrawn in `comp.py` from the app's tokens, so check them against the
  apps when those screens change.
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

Cut to Jack Harlow, "WHATS POPPIN": 144.99 BPM, first beat at 0.034 s, so beat i is at
0.034 + i × 0.4138 s (`beats.py`). The track's bass-free intro (beats 0–16) carries the open, the
bass drops on "Open models", and the reel ends in the breakdown at beat 80. Three lyrics are
answered on screen (whisper word timings): "What's poppin'?" (1.10 s) is the message sent to the
other agent, the frog hops in on "just hopped in" (2.76 to 3.28 s), and "I got options" (4.00 s)
turns the title.

| beats | time | shot | on screen | source of the claim |
|---|---|---|---|---|
| 0–16 | 0.0–6.7 s | an unnamed agent's task card: two steps done, "Writing the fix" under way. "What's poppin'?" is asked; on beat 4 it stops: "Usage limit reached. Resets in 4 h 12 min", then "Buy extra usage $$$". The frog peeks, then hops in | Your agent ran out. / You've got options. | a drawn, generic card: no product is named or copied |
| 16–24 | 6.7–10.0 s | the bass drops; the frog hops onto a lily pad, "this Mac". In the composer (redrawn from the app's tokens) the model menu opens on beat 19 (Qwen3 32B and Qwen3 Coder 30B on this Mac, then Frog Cloud's three) and Qwen3 32B is picked on beat 21 | Open models, on the Mac you have. / $0 a token. | `README.md:29`, `site/pricing.html` ("On your own machines: $0") |
| 24–32 | 10.0–13.3 s | a second pad drifts in carrying a pairing code. In Settings › Machines (redrawn from the app's tokens) "Pair a machine…" is clicked on beat 25, the six digits are typed, and on beat 28 the pad settles and the PC's row ("gaming-pc") joins | Add a machine. / Type its 6-digit code once. / It joins the pool. | `README.md:13,59`, `docs/app/models/your-own-nodes.md:13-16` |
| 32–40 | 13.3–16.6 s | two pads, this Mac above and "my gaming PC" below; a frog lands on one each beat, and with each a row appears in the session list (redrawn from the app's tokens): its title, "Working…" with a turning spinner, and the machine it runs on; the header counts to "6 working" | As many agents as they can hold. | `README.md:6-7` |
| 40–48 | 16.6–19.9 s | three agent frogs above two pads; a call leaves every beat for a machine, and each one lands as a row in a call list (redrawn from the app's tokens): the step, a spinner then a tick, and the machine it ran on | Each call goes where it / finishes first. | `README.md:59` ("A scheduler sends each call to the machine that will finish it first") |
| 48–52 | 19.9–21.6 s | on beat 48 the gaming PC's pad empties to a dashed outline and the list's header goes from "2 machines" to "1 machine"; the call in flight turns round, lands on the Mac, and its row reads "gaming PC dropped out", then "reran on this Mac" | A machine drops out. / The turn survives. | `README.md:14`, `site/index.html` ("the turn reruns on the next node with that model, with one line saying so"); the row's wording is this reel's, not the app's |
| 52–64 | 21.6–26.5 s | bars: Frog Cloud's three models land on beats 52–54, then three other providers' bars grow at the same dollars per beat while the frog watches the tip | Need more? Frog Cloud. / the six prices / List price per million output tokens, 17 Nov 2026. Different models: this compares price only. | `prices.json` (each row's source URL) |
| 64–72 | 26.5–29.8 s | `CLAUDE.md` flies in and the frog catches it; `skills` and `MCP servers` land stacked on its head | It brings your setup. / Nothing to set up twice. | `site/index.html` "Brings your setup" |
| 72–80 | 29.8–33.1 s | the frog on its own pad inside a ring; the limit notice from the open flies in, meets the ring on beat 76 and tumbles away; the frog waves | Nobody can cap what you own. / Free and open source. Local models keep your code on your Mac. | `README.md:55`, License |
| 80–88 | 33.1–36.5 s | the breakdown: the frog hops in and lands with a ripple; the line, the install line, frog.toys; it winks on beat 86; no fade, picture and music stop on the last beat | No caps. Your machines. One agent. / `curl -fsSL https://frog.toys/install.sh \| sh` / frog.toys | `README.md:3,10` |

The frog (`frog.py`) is drawn in code. Its head is the mark's own shapes and colours, read from
`apps/web/public/frog-mark.svg`; the body (belly, arms, hind legs) is new for this reel and is
not yet anywhere else in the brand. Poses: sit, hop, wave, carry, head only; it blinks, winks,
looks at things and squashes when it lands.

The pricing shot names other providers. Its numbers live in `prices.json` with a source per row
and a date; re-read the sources before publishing. Cheaper tiers exist at those providers (for
example $0.50 output models) and are not on the chart, and Frog Cloud's OpenRouter-served prices
are "from" prices.

Layout, the same in every scene (`comp.py`, "the grid and the type scale"): a 12-column grid with
120 px margins; everything flush left on a column edge, nothing centred. Titles are IBM Plex Sans
88 semibold on two lines (the claim, then its point in green), the sub is 42 regular one fixed
step below, labels are Plex Mono 30. One accent, true black, no rules or boxes that don't hold
content.

Editing rules, from the board video's notes: text lands whole, motion steps on beats, the frame
changes completely on the drop, and nothing glows.

## Music

The cut is timed to **Jack Harlow, "WHATS POPPIN"** (Cam's mp3, not in the repo). It is a
commercial release: fine for a private cut, but publishing the reel needs a licence for it, or
the stand-in below. Its lyrics are explicit in places (profanity in the part the reel uses; the
reel ends at 36.5 s, before the most explicit lines). `TRACK=<path to the mp3> render.sh` uses it
from its start, cut to 36.5 s, 3.5 dB down, with no fade: it stops on the last beat. The grid was fitted, not heard: nobody has
checked the sync by ear.

Without `TRACK`, `music.py` synthesizes an original stand-in on the same grid (Am F C G, sine,
saw and noise, fixed seed, no samples), safe to publish but plainer.

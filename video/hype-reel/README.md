# Frog hype reel

A 40 second, 1920x1080, 30 fps reel telling the "no caps" story, rendered entirely from code: real frames of the web app
(captured from the mock gateway in headless Chrome) and the Mac app's checked-in snapshots, moved
by a compositor in which every animation is a pure function of time, cut to a 120 BPM beat grid,
over an original track synthesized in numpy. No screen recording, no generative models, no paid
services; it renders on a Mac's CPU in a few minutes.

The pipeline is the board video's (vcad `hardware/pcb-motor-video/`): beat grid, pure-function
compositor, contact sheets, ffmpeg encode. The footage step is new.

![contact sheet](contact-sheet.png)

## Re-render

```bash
video/hype-reel/render.sh
```

It composites `build/frames/`, synthesizes `build/music.wav` and encodes `frog-hype-reel.mp4`
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
- Shots: `type` (the prompt typed a character a frame, the where menu, lilypad picked), `stream`
  (the live turn), `inspector` (Changes, Commit, Open PR), `models` (the model menu with prices),
  `docs` (captured, not used yet). `run.sh probe` writes two stills for checking selectors.
- Mac footage is the checked-in offscreen snapshots, not a capture: `docs/design/composer/mac-where-menu-dark.png`
  and `mac-git-pr-dark.png` (`ComposerSnapshotTests`, see `docs/design/composer/`). Re-run those
  harnesses to refresh them; they build their own copy of the app.
- The mark is `apps/web/public/frog-mark.svg`, rasterized by `run.sh`.

## Files

| file | what |
|---|---|
| `beats.py` | the beat grid (`B(i)`) and the cut list, shared by picture and music |
| `comp.py` | the compositor: one function per shot, `view()` camera, words, rings, cursor |
| `music.py` | the track: kick, clap, hats, bass, pad, pluck arpeggio, risers; Am F C G |
| `sheet.py` | renders chosen beats through `comp.py` into a contact sheet, for review while editing |
| `render.sh` | the one command |
| `capture/` | gateway, CDP driver, shot list, `run.sh` |
| `fonts/` | IBM Plex Sans and Mono (SIL OFL, `OFL-IBM-Plex.txt`), the app's own type |

## Beat sheet

The story is the site's own line, "No caps. Your machines. One agent." (`site/index.html`,
`README.md:3`): an agent that doesn't run out, because it runs open models on machines you own,
and every machine you add makes the pool bigger. No other product is named or shown.

120 BPM: beat i is at i × 0.5 s, 15 frames a beat. Cuts land on beats (`beats.py`).

| beats | time | shot | on screen | source of the claim |
|---|---|---|---|---|
| 0–8 | 0–4 s | black; the line types on with a green cursor | Your agent shouldn't run out. | the premise of `README.md:3,6-7` ("No caps", "no rate limits") |
| 8–16 | 4–8 s | Mac composer's where menu: This Mac (frog, zest), Frog Cloud below; model Qwen3 8B on this Mac | Open models, on the Mac you have. / $0 a token. | `README.md:29` ("Local models run on this machine and cost nothing"), `site/pricing.html` ("On your own machines: $0") |
| 16–20 | 8–10 s | drop 1. A terminal card types the node install line | Add a machine. | `README.md:59`, `site/index.html` ("installs tang-llm, prints a pairing code") |
| 20–24 | 10–12 s | Mac Settings › Models › Machines: studio (This Mac, M4 Max) and mew (RTX 3090, Qwen3-4B at 58 tok/s) | It joins the pool. | `README.md:13` ("Pair another Mac or a Linux GPU box with a 6-digit code and it joins one pool") |
| 24–36 | 12–18 s | web: six sessions in the sidebar, the open one streaming a turn (read, search, failing test, edit, reply, ask) | As many agents as they can hold. | `README.md:6-7` ("Run as many agents as your machines can hold, with no rate limits") |
| 36–44 | 18–22 s | break. Three numbers count up | More machines, more done. / 41 tasks passed on Mac + PC / 21 on the PC alone / 0 rate-limit errors / Six agents for 15 minutes on Qwen3-8B: an M4 Max Mac added to a PC with an RTX 3090. | `site/index.html` "No caps" section, `docs/no-caps-bench.md` (run `swarm-2026-11-11-mac-mew-8b`), `README.md:15-17` |
| 44–52 | 22–26 s | drop 2. Web model menu: Frog Cloud's models, "from $0.13/M" | Need more? Frog Cloud. / Per token, at cost plus 10%. | `README.md:7` ("Frog Cloud is billed by the token"), `site/pricing.html` (OpenRouter models "billed at what each request cost there plus 10%") |
| 52–57.5 | 26–28.75 s | web Changes panel; the cursor clicks Open PR | Then it opens the pull request. | `docs/releases/v0.6.0.md` (`open_pr_when_done = "auto"`), `apps/web/README.md` (Open PR is a message to the agent) |
| 57.5–60 | 28.75–30 s | Mac composer: `frog/sidebar-polish`, +48 −12, "#412 checking", Push | (same) | as above |
| 60–68 | 30–34 s | type only | Free and open source. / MIT or Apache-2.0. Fork it, build on it. | `README.md:5`, License section |
| 68–80 | 34–40 s | end card: the mark, the line, the install line, frog.toys; fade over the last second | No caps. Your machines. One agent. / `curl -fsSL https://frog.toys/install.sh \| sh` / frog.toys | `README.md:3,10` |

The bench beat leaves out the site's caveat ("one task got slower with the second machine") and
the doc's note that the baseline was slightly flattered; both are in `docs/no-caps-bench.md`.
The six web sessions are Frog Cloud sessions from the capture gateway; the web app streams only
the open one, so only it shows "Working…".

Prices on screen ("from $0.13/M", "from $0.17/M") are the pricing page's static table
(`site/pricing.html`), served by the capture gateway. The live page loads current prices from
`api.frog.toys/v1/models`, so recapture if they move. "Plus 10%" is the rule for models served
through OpenRouter; Frog Cloud's own GPUs list their own prices.

## Music

`music.py`, original, written for this reel: 120 BPM, A minor (Am F C G, a bar each), all
synthesized from sine, saw and noise with a fixed seed, so every render is the same wav. Intro
(pad, pluck from beat 4, hats from beat 8, a riser into beat 16), drop 1 at beat 16 when a machine
joins, a half-time break at beat 36 under the bench numbers, drop 2 at beat 44, a final hit at beat 68 with the tonic
ringing out, 2 s fade. Measured on the encoded mp4: −13.4 LUFS integrated, true peak −1.0 dBFS
(the wav is normalised to −2 dBFS for the aac encode's overshoot). Not checked by ear.

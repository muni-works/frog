# Frog hype reel

A 40 second, 1920x1080, 30 fps reel, rendered entirely from code: real frames of the web app
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
  models, three repos and four sessions. `s_live` plays the parity fixture
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

120 BPM: beat i is at i × 0.5 s, 15 frames a beat. Cuts land on beats (`beats.py`).

| beats | time | shot | on screen | source of the claim |
|---|---|---|---|---|
| 0–4 | 0.0–2.0 s | the mark lands, "Frog" | Frog | `apps/web/public/frog-mark.svg` |
| 4–16 | 2.0–8.0 s | web new-session screen: the prompt is typed, the where menu picks `muni-works/lilypad`; slow push-in | A free, open-source coding agent. | `README.md:5` ("A free, open-source coding agent") |
| 16–20 | 8.0–10.0 s | drop 1. Mac composer's where menu: This Mac (frog, zest), then Frog Cloud; the model is Qwen3 8B on this Mac | On your Mac. | `README.md:29` (local models run on this machine), `site/index.html` "Every model, and where it runs" |
| 20–24 | 10.0–12.0 s | web model menu: Frog Cloud's models, "from $0.13/M" | Or in Frog Cloud. | `README.md:7`, `docs/app/models/frog-cloud.md:1` |
| 24–36 | 12.0–18.0 s | the live turn streams: thought, read, search, a failing test, the edit, the reply | It reads, runs and edits. | `README.md:35` ("frog reads the code, runs commands and edits files") |
| 36–44 | 18.0–22.0 s | break. Push in on the ask card; a ring around "Runs in your cloud sandbox" | Every session in its own sandbox. | `docs/app/models/frog-cloud.md:10` ("every session runs in Frog Cloud: the model, and a sandbox with a copy of your repo") |
| 44–48 | 22.0–24.0 s | drop 2. The new-session screen's card, ringed: "Five at once, laptop closed" | (the card's own words) | `apps/web/src/ui/Pond.tsx:173` |
| 48–52 | 24.0–26.0 s | the sidebar: four sessions, one working, one child session, one with PR 412 | Several at once, laptop closed. | `apps/web/src/ui/Pond.tsx:173`, `README.md:6-7` ("Run as many agents as your machines can hold") |
| 52–57.5 | 26.0–28.75 s | web Changes panel; the cursor clicks Open PR | It opens the pull request. | `docs/releases/v0.6.0.md` (`open_pr_when_done = "auto"` opens a draft PR), `apps/web/README.md` (Commit, Push and Open PR are messages to the agent) |
| 57.5–60 | 28.75–30.0 s | Mac composer: `frog/sidebar-polish`, +48 −12, "#412 checking", Push | It opens the pull request. | as above |
| 60–64 | 30.0–32.0 s | the model menu, blurred | Pay per token. / At cost, plus 10%. | `site/pricing.html` ("pay per token"; models served through OpenRouter "billed at what each request cost there plus 10%"), `docs/releases/v0.6.0.md` |
| 64–68 | 32.0–34.0 s | type only | $1 free credit. / No plan needed. Your own machines: $0. | `site/pricing.html` ("$1 free credit when you sign up and connect GitHub", plans "Optional", "On your own machines: $0"), `docs/app/models/frog-cloud.md:5` |
| 68–80 | 34.0–40.0 s | end card: the mark, frog.toys, the install line; fade out over the last second | frog.toys / `curl -fsSL https://frog.toys/install.sh \| sh` / Free and open source. Frog Cloud when you want more. | `README.md:9`, `docs/releases/v0.6.2.md` (install) |

Prices on screen ("from $0.13/M", "from $0.17/M") are the pricing page's static table
(`site/pricing.html`), served by the capture gateway. The live page loads current prices from
`api.frog.toys/v1/models`, so recapture if they move. "Plus 10%" is the rule for models served
through OpenRouter; Frog Cloud's own GPUs list their own prices.

## Music

`music.py`, original, written for this reel: 120 BPM, A minor (Am F C G, a bar each), all
synthesized from sine, saw and noise with a fixed seed, so every render is the same wav. Intro
(pad, pluck from beat 4, hats from beat 8, a riser into beat 16), drop 1 at beat 16, a half-time
break at beat 36 under the sandbox beat, drop 2 at beat 44, a final hit at beat 68 with the tonic
ringing out, 2 s fade. Measured on the encoded mp4: −13.4 LUFS integrated, true peak −1.0 dBFS
(the wav is normalised to −2 dBFS for the aac encode's overshoot). Not checked by ear.

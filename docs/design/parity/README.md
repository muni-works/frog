# Parity: one fixture, Mac and web

Proof that the Mac app and the web app look the same: one fixture session rendered by both at the
same size, dark and light, side by side in [`index.html`](index.html) (open it locally).

The session ([`fixture.mjs`](fixture.mjs), written out as `fixture.jsonl`) has every row the
[unified transcript](../transcript/spec.md) specifies. Turn 1, finished: your message, a thought,
four quiet steps (a fold), a failed test run (10 of 11, from the engine's `tests` field), prose, an
edit, a passing run (11 of 11), a two-paragraph reply and the footer. Turn 2: your message and an ask
card, held open. The gateway keeps the fixture's own event times, so step durations come through.

## Run it

```bash
docs/design/parity/capture.sh
```

It runs locally on a Mac (CI can't capture windows). Needs Xcode and xcodegen, `npm ci` in
`apps/web` and Google Chrome. The Mac app draws its own window to a PNG (`-FrogSnapshot <path>`),
so the terminal needs no Screen Recording permission. `LOOKS=dark` shoots
one look; `FROG_PREBUILT_DIR` picks the engine binaries (default: a scratch copy of
`/Applications/Frog.app`'s).

- **Mac:** builds its own copy (`toys.frog.parity`) and replays the fixture with `-FrogReplay` in a
  throwaway HOME; the app renders its window to `mac-*.png` and quits. A replay never restores the
  last run's open sessions or the folder's last session, so the fixture is what shows.
- **Web:** [`gateway.mjs`](gateway.mjs) serves the fixture as one session (reusing the vendored mock
  in `apps/web/test/mock`), vite dev proxies `/v1` to it with a dev key, and
  [`web-shot.mjs`](web-shot.mjs) captures `/s/s_parity` in headless Chrome at the Mac window's size
  in points, 2× (`web-*.png`).

Re-run it after a layout or token change and commit the PNGs and `index.html` with it.

## Fuzz: the cases that stress the transcript

[`fuzz/cases.mjs`](fuzz/cases.mjs) holds twelve session logs that try to break the transcript:
long unbroken strings and URLs, a long code block and a wide table, nested lists and quotes,
CJK, Arabic and emoji, blank messages and thoughts, a flood of tool calls with a 400-line output
and a 60-line diff, very long thoughts, a reply streaming inside an unclosed code fence, errors
and notices, child sessions, a permission card, and images.

```bash
docs/design/parity/fuzz.sh
```

renders each in both apps (dark, light, and a narrow 680 pt window, the Mac's minimum) into
`fuzz/shots/` at 1×, side by side in [`fuzz/index.html`](fuzz/index.html). `CASES="images
thoughts"` and `VARIANTS=dark` narrow a run; `PARITY_SKIP_MAC=1` / `PARITY_SKIP_WEB=1` skip a side.
The Mac sizes its window with `-FrogSnapshotSize WxH`. A case that must hold mid-turn ends on an
open permission request, which is where `frog --replay` holds.

The same cases are web regression tests: `apps/web/test/parity-fuzz.test.ts` folds and renders
each one and pins what the first run found (`npm test` in `apps/web`). Add a case there when a
transcript bug turns up, and re-run `fuzz.sh` after a transcript change.

## Model picker and Settings › Models

[`models.html`](models.html) puts the picker, the Machines list and a machine's page side by side,
Mac and web, from one fixture. Mac: `TEST_RUNNER_FROG_PARITY_OUT=$PWD/docs/design/parity xcodebuild
… test -only-testing:FrogTests/ModelsParityTests`. Web: `npx vite` in `apps/web`, then
`node docs/design/parity/web-shot.mjs "http://localhost:5173/parity/models.html?view=picker&theme=dark" …`
(views: `picker`, `settings`, `machine`).

## Metrics

Screenshots are for people. Parity is measured: each app renders the fixture at the same size and
writes its transcript's rows as JSON, and [`diff-metrics.mjs`](diff-metrics.mjs) compares two dumps.
It fails on any difference in a row's kind or text, on x, top or height off by more than 1 point,
or on any font size difference.

```bash
node docs/design/parity/metrics.mjs http://127.0.0.1:5173/s/s_parity web.json 1280 800 dark
node docs/design/parity/diff-metrics.mjs web.json mac.json
```

[`metrics.mjs`](metrics.mjs) is the web's dumper (headless Chrome, like `web-shot.mjs`;
`METRICS_STORAGE` seeds localStorage, e.g. `{"frog.inspector":"1"}`). The Mac writes the same file
(to build: a `-FrogMetrics <path>` launch argument beside `-FrogSnapshot`).

### Format (`frog-transcript-metrics/1`)

```json
{
  "format": "frog-transcript-metrics/1",
  "app": "web",
  "width": 1280, "height": 800, "look": "dark",
  "column": 720, "gutter": 32, "pane": 1010, "mark": -26, "markOnScreen": true,
  "rows": [
    { "kind": "line", "text": "Failed cargo test -q upload 10 of 11 · 9.0s", "x": 0, "top": 102, "height": 24, "fontSize": 12.5 }
  ]
}
```

All lengths are points (CSS px on the web), rounded to 0.1.

- `width`, `height`: the window (web: the viewport). `column`: the transcript column's text
  width. `gutter`: the room either side of it. `pane`: the transcript pane's width. `mark`: the x of
  the first line's mark box (left edge). `markOnScreen`: whether that box's left edge is inside the
  pane. These describe the layout and are not compared.
- `rows`: top to bottom, one per row the transcript draws. Nothing inside an opened line or an
  opened fold counts (a failed command's open output doesn't add rows; it moves the rows below it).
- `kind`, one of:
  - `prompt`: a message bubble
  - `thought`: a thought line
  - `fold`: a fold line
  - `line`: a step's line
  - `prose`: one paragraph, heading, quote or list item of a reply (a list gives one row per item)
  - `code`: a code block or table in a reply
  - `card`: a box that needs you (ask card, question, diff card), measured on its title
  - `footer`: the turn's footer
  - `live`: the live row at the end of a running turn (spec phase 2: "Thinking", a step, "Waiting
    for you"), measured on its 24-tall plate row
  - `stats`: the stats under the live row, or under an answer that is writing (phase 2)
- `text`: the row's visible words, whitespace collapsed to single spaces and trimmed. It leaves out
  hover actions, receipts (ticks, "just now"), the copy and retry icons and marks. For `line`,
  `thought` and `fold`: the parts verb, gist, object and result joined by one space ("Edited
  src/retry.rs +3 −2", "4 steps 2.2s"). For `footer`: as drawn, with " · " between parts. For
  `card`: its title. For `live`: the label, object and thought joined by one space ("Editing
  src/retry.rs", "Waiting for you"). For `stats`: as drawn, with every duration written `#s` ("2m 5s" too)
  and every other run of digits `#`, since the figures tick (`#s · waited #s`).
- `x`: the left edge of the row's first visible character, minus the column's text edge (the
  column's left plus its gutter). 0 means on the shared left edge. A right-aligned bubble's x is
  wherever its text starts.
- `top`: the row box's top minus the first row's top (the first row is 0). Boxes: a line's 24-tall
  plate row, a paragraph's block, a bubble, a card, the footer's row.
- `height`: that box's height.
- `fontSize`: the font size of the first visible character (so a paragraph that opens with inline
  code reports the mono size).

Proof the diff works, web against web (`../transcript/metrics/`): 1280 and 1600 match
(`diff-1280-1600.txt`, exit 0). 1280 against 375 fails, as it should (`diff-1280-375.txt`, 27
differences, exit 1).

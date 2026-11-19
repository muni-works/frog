# Chrome parity: where the controls stand

The window chrome's controls (the top-right group and each of its buttons, the turn rail, the
title's menu) measured in both apps from the same fixture at 1280 × 800, and compared. The design
they're held to is [`../spec.md`](../spec.md).

```bash
docs/design/chrome/parity/capture.sh                 # dark; builds the parity app first
OUT=now LOOKS="dark light" PARITY_SKIP_BUILD=1 docs/design/chrome/parity/capture.sh
```

- **Mac:** the parity app (`toys.frog.parity`, as [`../../parity/capture.sh`](../../parity/capture.sh)
  builds it) replays [`../../parity/fixture.mjs`](../../parity/fixture.mjs) off-screen and writes
  `mac-<look>-<OUT>.json` with `-FrogChromeMetrics` (`apps/macos/Frog/ChromeMetrics.swift`): each
  control found by its accessibility label in the app's own AX tree, so the title bar's items are
  measured where the system put them. And `mac-<look>-<OUT>.png`.
- **Web:** the parity gateway and vite dev, then [`chrome-metrics.mjs`](chrome-metrics.mjs) in
  headless Chrome finds the same labels (`aria-label`) and writes `web-<look>-<OUT>.json`, and
  `web-<look>-<OUT>.png`.
- [`diff-chrome.mjs`](diff-chrome.mjs) compares them: every control on both apps, its top,
  width, height and distance from the window's right edge (the title: its x) within 1 point.
  Controls the spec keeps on one app (`ONE_APP`: split, Mac only, while the web has no split
  panes) pass when missing from the other. It writes `diff-<look>-<OUT>.json` and exits 1 on a
  difference.

Format `frog-chrome-metrics/1`: `{ app, width, height, look, main (where the conversation area starts), controls: [{ id, x, top, width,
height, right }] }`, ids `group`, `split`, `palette`, `inspector`, `rail`, `title`.

`*-before.*` is main at v0.7.1, before the chrome work: the web had only the title, and its
inspector button had another label. `*-now.*` is the latest run. Re-run after a change to the
chrome and commit the JSON and PNGs with it.

The title is compared on top, height and where it starts from the conversation area's left edge.
Its width isn't, yet: the same 13 pt semibold IBM Plex Sans title measures 141.9 on the web and
128 on the Mac (text and chevron) — a font-rendering gap to close with the sidebar's row, which
has the same words at the same weight.

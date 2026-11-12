# Parity: one fixture, Mac and web

Proof that the Mac app and the web app look the same: one fixture session rendered by both at the
same size, dark and light, side by side in [`index.html`](index.html) (open it locally).

The session ([`fixture.mjs`](fixture.mjs), written out as `fixture.jsonl`) has every row the
[One look](../frog-web/README.md#one-look-mac-and-web-decided-2026-11-11) specifies: your message,
Thinking, Read, Search, Ran (failed), an edit with a diff, a reply with inline code, and an ask
card, held open.

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

## Model picker and Settings › Models

[`models.html`](models.html) puts the picker, the Machines list and a machine's page side by side,
Mac and web, from one fixture. Mac: `TEST_RUNNER_FROG_PARITY_OUT=$PWD/docs/design/parity xcodebuild
… test -only-testing:FrogTests/ModelsParityTests`. Web: `npx vite` in `apps/web`, then
`node docs/design/parity/web-shot.mjs "http://localhost:5173/parity/models.html?view=picker&theme=dark" …`
(views: `picker`, `settings`, `machine`).

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
`apps/web`, Google Chrome, and Screen Recording permission for the terminal. `LOOKS=dark` shoots
one look; `FROG_PREBUILT_DIR` picks the engine binaries (default: a scratch copy of
`/Applications/Frog.app`'s).

- **Mac:** builds its own copy (`toys.frog.parity`) and replays the fixture with `-FrogReplay` in a
  throwaway HOME, then captures the window without its shadow (`mac-*.png`), like
  `apps/macos/scripts/hero-shot.sh`.
- **Web:** [`gateway.mjs`](gateway.mjs) serves the fixture as one session (reusing the vendored mock
  in `apps/web/test/mock`), vite dev proxies `/v1` to it with a dev key, and
  [`web-shot.mjs`](web-shot.mjs) captures `/s/s_parity` in headless Chrome at the Mac window's size
  in points, 2× (`web-*.png`).

Re-run it after a layout or token change and commit the PNGs and `index.html` with it.

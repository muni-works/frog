# Chromium screenshots

Optional cross-platform renderer for Frog's `Screenshot` tool. It exposes the same
`POST /v1/screenshots` request as frog-apple: `url`, `width`, `height`, `settle_ms`.
Captures use a fresh browser/context, fixed CSS viewport and device scale 1. The
renderer waits for page load, fonts and images, then the requested settling interval.
Two captures can run concurrently; additional requests return 429.

Install dependencies and Chromium explicitly:

```sh
python3 -m venv .venv
.venv/bin/pip install -r sidecars/frog-chromium/requirements.txt
.venv/bin/playwright install chromium
.venv/bin/python sidecars/frog-chromium/server.py --port 8914
```

Alternatively pass `--executable-path /path/to/chrome` for an existing browser.
No browser or Python dependencies download during inference. The listener binds
only to `127.0.0.1`; it can render local files and network URLs. Configure Frog:

```toml
screenshot_endpoint = "http://127.0.0.1:8914/v1/screenshots"
```

Chromium's sandbox stays enabled. The service does not reuse an existing browser
profile or session. Playwright's [browser context API](https://playwright.dev/python/docs/api/class-browser)
documents viewport and device-scale behavior.

Run the real Frog capture/compare regression with a deterministic fixture judge:

```sh
python3 scripts/test_visual_tools.py --frog target/debug/frog \
  --screenshot-endpoint http://127.0.0.1:8914/v1/screenshots
```

Add `--judge-endpoint http://127.0.0.1:8911/v1 --judge-model <model-id>` to use a
running local vision model. That checks integration; judge accuracy needs separate
quality evaluation.

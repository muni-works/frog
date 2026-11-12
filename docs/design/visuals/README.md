# Visuals: interactive widgets in the transcript

Frog can now answer "explain X visually" with a live, interactive widget (sliders, toggles, draggable points, stat tiles) drawn inline on Mac and web.

## How it works

- **Engine** (`crates/frog-engine/src/widget.rs`, `tools/visualize.rs`):
  - `VisualGuide` returns the design read-me (`tools/visualize.md`): theme variables, the slider/toggle/tile kit, sandbox rules, reduced motion, phone width and craft notes.
  - `Visualize {title, widget_code, loading_messages}` wraps the model's fragment in one document: Frog's tokens as CSS variables (true black in dark), IBM Plex, a CSP that blocks all network except `cdnjs.cloudflare.com`, `cdn.jsdelivr.net`, `unpkg.com` and Google Fonts, plus a small bridge for height and `sendPrompt`.
  - The finished document travels on `Item::ToolCall.widget`, so session logs, `--replay` and `/s/<id>` redraw exactly what was shown.
  - `Visualize` refuses until the guide has been read. The lint tells the model about full documents, blocked URLs, storage, painted backgrounds and animation without a reduced-motion path.
  - The system prompt says when to use a visual (asked to see something, a concept with a knob to turn, data) and when not to.
- **Web** (`apps/web/src/ui/Widget.tsx`):
  - an `<iframe sandbox="allow-scripts" srcdoc>`, so it runs at an opaque origin with no cookies, storage, or access to the app;
  - height follows content;
  - Source toggle, full-screen expand (Esc closes).
- **Mac/iOS** (`apps/FrogKit/UI/Transcript/WidgetView.swift`):
  - a `WKWebView` with a non-persistent data store;
  - no navigation after load and no popups;
  - same bridge, Source toggle, expand sheet.
- **`sendPrompt(text)`**:
  - the shell forwards it only during a user activation (a click or key press);
  - the host allows one every 4 s and 3 a minute per widget;
  - it is sent as your message, and the card shows "Asked Frog: …".

## Eval (2026-11-12)

Prompts: Casimir effect from first principles; implicit differentiation; "why does energizing a coil produce magnetism… spins?"; Fourier transform intuition. All ran in chat mode.

| Model | Used Visualize | Quality |
|---|---|---|
| `cloud/deepseek-v4.1-flash` (default) | 4/4 prompts, both rounds; read the guide every time | Claude-grade. Casimir: gap slider, mode comb, outside continuum, 1/d⁴ tiles. Implicit: draggable point snapping to the curve, tangent, ∇F, secant slider. Coil: current slider, iron-core toggle, domains panel. Fourier: winding machine with a live spectrum. Round 1 had small misses (tiles disagreeing, a 999 nm default, unfilled tiles); the round-2 guide and shell fixed all three. |
| `local/qwen3-8b` (tang-llm, this Mac) | 1/5 | Usually reaches for Diagram. Its one widget skipped the guide, painted a white panel and was static. The guide gate and background lint now catch both, but an 8B model still doesn't choose Visualize. Not worth tuning the prompt for. |

Fixtures in `fixtures/` are the round-2 DeepSeek sessions, events only (model context and paths stripped). Replay one with `frog --serve --replay docs/design/visuals/fixtures/casimir.jsonl`, or view it on the web with `node docs/design/parity/gateway.mjs --fixture …`.

## Shots

- `before-mac-diagram.webp`: before, the static Diagram card.
- `web-*-dark.png`, `web-fourier-light.png`, `web-fourier-phone.png`: the real web app replaying each fixture.
- `mac-casimir.png`, `mac-implicit.png`: the Mac WKWebView rendering the recorded widgets (from `FrogTests/WidgetViewTests`). These are dark-theme widgets on a transparent background, composited on white by the test.

Known gaps:
- SVG labels get small at phone width, because SVGs scale with the viewBox.
- `-FrogSnapshot` can't paint WKWebView content (it renders out of process), so Mac shots come from the test's `takeSnapshot`.

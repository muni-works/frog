# preview-expand — notes

Branch `frog/preview-expand`, worktree `/Users/cam/Developer/frog/.frog/worktrees/preview-expand`,
off `034d920d`, tracks origin/main. One commit per unit (`git commit -s`), never push. Edit tool
only for source. Tests: `FROG_PREBUILT_DIR=/private/tmp/be-prebuilt2` (skip sidecar compile),
`-derivedDataPath /private/tmp/pe-dd`, `CODE_SIGN_IDENTITY="-"`, suite bundle id
`toys.frog.testhost` if the installed frog is open.

## What "can't drag it right now on osx so it's small" actually was

**Both** halves of the chief's diagnosis confirmed in code:

(a) **The clamp floor ate the space.** `WorkspaceView.minPane = 360`
(WorkspaceView.swift:148) passes into `panes.moveDivider(d, to: t, minimum:)` →
`PaneLayout.moving(divider:at:to:minimum:)` (Panes.swift:97). The minimum is converted to a
share of the *split's* length (`minimum / length`, Panes.swift:415), then clamped as
`lo = min(minimum, pair / 2)`. For a two-pane window on an ~800–1100 pt canvas, each pane's
minimum share is 360/length, and `pair = 1.0`, so `lo ≈ 0.33–0.45` and `hi = 1 − lo` — the two
panes can never be far from even. The divider technically moves ~100 pt and snaps back
visually; with cards docked beside (`cardWidth = 480`, `insets.leading/trailing` up to ~530)
the usable column inside a 360 pt pane is under 300 pt — too narrow to read, so it *feels*
stuck. The floor was set for conversation panes (transcript needs ≥ minSplitColumn 460 to read)
but applies to every pane regardless of what's in it.

(b) **Nothing visible to grab.** `PaneDividerHandle` (PaneView.swift:346): the 12 pt hit area
is correct and `pointerStyle(.columnResize/.rowResize)` is set, but the capsule renders at
`.opacity(hovering || dragging ? 1 : 0)` — invisible at rest. A user cannot aim at an invisible
target; without a visible affordance the divider reads as static whitespace. (Fix: faint
hairline at rest, brighter on hover, tinted while dragging — hit area and pointer style kept.)

## Units

- **U1 — maximize/restore a pane.** Double-click the pane's header capsule (or Escape) toggles
  the focused pane to fill the whole canvas. Implemented as `Panes.maximized: Pane.ID?` +
  `Panes.savedLayout: PaneLayout?` — layout state only, no window change. `PaneLayout.frames`
  and `dividers` gain a `maximizing:` parameter: the maximized leaf gets the full rect, every
  other leaf is empty (`.zero`), and no dividers render (nothing to drag). Restore puts the
  saved layout back exactly; maximize with one pane already maximized swaps to the new one;
  close/stop paths clear it if the maximized pane goes away. Per-`Panes` instance = per-window
  (each `RootView` builds its own `Panes`, FrogApp.swift:136), so also per-conversation in the
  sense asked.
- **U2 — divider usable.** Capsule always visible as a faint hairline (`.primary.opacity(0.22)`
  at rest, 0.6 on hover, tint while dragging); hit area stays 12 pt; pointer style kept. Clamp
  fix: keep `minPane` 360 for conversation-only splits but lower it for a pane whose conversation
  has tool panes open (a preview is usefully 260), and never let the minimum exceed a quarter of
  the pair (`lo = min(minimum, pair/4)`), so in an 800 pt two-pane canvas a tool pane can go to
  ~200 pt (25%) instead of stalling at ~440/360. Rationale: 25% of the pair is always at least
  half of what even-share would give either child, so a drag can always reach "twice the other
  pane" — enough to make the divider meaningful — while a conversation pane never drops below
  readable 360.
- **U3 — preview affordances.** "desktop" device width already maps to `nil` →
  `min(geo.width, geo.width)` = full card width (PreviewPane.swift:153): already fills the
  card; documented, not changed. Added a pop-out button on the preview toolbar
  (`PreviewDocument`/`PreviewWindow`, a new `WindowGroup("Preview", for: PreviewDocument.self)`
  in FrogApp beside the Diagram one, `.defaultLaunchBehavior(.suppressed)` +
  `.restorationBehavior(.disabled)`, same pattern as `DiagramWindow`). The pop-out shares the
  pane's `PreviewHost` web view by reparenting it: the card keeps the host, the window presents
  it, and a "back to pane" button re-presents it in the card, so engine reads/drives/screenshots
  keep working (the engine talks to `hub.handlers[paneID]`, which stays registered).

## Test counts

Full suite (this branch, `toys.frog.testhost`, pe-dd, prebuilt sidecar): **443 executed, 5 skipped,
1 unexpected failure** — `TranscriptSwitchBenchmarkTests/testScrollUpFillsOlderRowsInOrder`
(peak mounted rows 41 > 30). That test never touches anything this branch changes (transcript
only; diff checked) and its own history says flaky (~1 in 3, per dda4320e; CI skips it via
`TestRunner.isCI`, 4b76df45). **Proven pre-existing:** a control run of the same class at the
base commit `034d920d` (throwaway worktree, otherwise identical flags) fails the same test the
same way (worktree removed after). `PaneExpandTests`: 11/11 pass. The other briefed-noisy class,
`InkRevealTests`, passed in the suite (not in the tail-200 log window, and not among the
failures). No gateway 401s or connection resets at any point.

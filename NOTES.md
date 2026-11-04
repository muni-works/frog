# perf-structural — notes

Branch `frog/perf-structural`, worktree `/Users/cam/Developer/frog/.frog/worktrees/perf-structural`,
off `b99a7a81` (post #257 merge, tracks origin/main). One commit per unit (`git commit -s`), never
push (the chief pushes and opens the PR). Edit tool only for source. `| head -60` caps. Never launch
a Frog build (`open`/`open -n` forbidden — Cam's app is running). Swift verify via `xcodebuild test`,
test host bundle id `PRODUCT_BUNDLE_IDENTIFIER=toys.frog.testhost`, engines prebuilt
(`FROG_PREBUILT_DIR=/private/tmp/be-prebuilt2`), build dir `/private/tmp/ps-dd`, unsandboxed (SwiftUI
macro plugin server is blocked in the sandbox; see perf-audit notes), disk watched (>15G free).

Brief: the perf audit (9f291edb, measurement-only) ranked two costs to fix here:

- **Cost #1 — whole-window SwiftUI layout.** One `NSDisplayCycleFlush → NSWindow layoutIfNeeded →
  NSHostingView.layout` pass costs 0.5–1.3 s of main-thread CPU in the live app; passes arrive
  0.5–1.9×/s idle, 0.7–1.0×/s streaming; **no frog frames inside a pass** — the framework re-runs the
  whole window's view graph because sidebar + transcript + workspace live in ONE NSHostingView.
- **Cost #2 — transcript.** 253 `TurnView` body evaluations per streamed row (126,674 bodies for a
  500-row turn). Hot lines: `TurnView.swift:87` (probe), `TranscriptView.swift:178` (`rows` re-derived)
  and `:1027` (`FlowCache.segments` cached only for `turn.finished`, so the live turn rebuilds its
  segments every chunk). Deltas already coalesced to 30 Hz (`Conversation.swift:1039/1047`).

Order per the brief: STEP 1 (streaming turn, cheaper) measured before/after, then STEP 2 (window
graph) with sample/signpost proof, then a before/after table. If a step doesn't move its number, say
so and revert it rather than shipping noise. The TranscriptSwitchBenchmarkTests flake
(peak mounted 41 > 30, ready > budget) is pre-existing at base — verify against b99a7a81 before
blaming this branch.

## Checkpoint (before first edit)

- Branch confirmed, no uncommitted changes.
- Read: TranscriptView.swift (rows/FlowCache), TurnView.swift (probe, SegmentRow equatable),
  Conversation.swift (apply/upsert/flushDeltas), PaneView/WorkspaceView/FrogApp (window composition),
  both benchmark tests.
- Next: baseline benchmark run, then STEP 1.

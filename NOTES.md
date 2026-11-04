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

## Cost #1 baseline, measured on Cam's live app (93427/Frog, pid 45417)

`sample 45417 10` at 11:28 local (app idle over a live session, pointer elsewhere):

- wall 3,392 ms; main awake 2,949 ms = **86.9% of a core** (the audit's 23–57% was luckier
  timing; this window was mid `Library.refresh`).
- The two big `__NSWindowGetDisplayCycleObserverForLayout_block_invoke` passes inside one sample:
  **1,499 ms and 474 ms** — AppKit's layout pass is one sampled block per display cycle, and each
  went through `NSHostingView.layout()` (1,219/393 ms) whose only children are the ViewGraph
  update machinery (render 623+402+147, `beginNextUpdate` 227, `runTransaction` 350, display-list
  rebuild 399+). **Zero frog frames inside** (frog frames under SwiftUI in the whole sample:
  682 ms, all sidebar row/menu work OUTSIDE these passes, e.g. `CompactSessionRow.content` 73,
  `rowMenu` 61, `sidebarOrder` 29+15+13 — and those fired from their own invalidations).
- So the audit's finding reproduces on the merged main: the pass is the framework re-running the
  whole window's view graph for one invalidation. Nothing in frog decides how long a pass takes
  (per-frame); frog decides how MANY passes happen (per invalidation source) — and the sources
  that matter read *streaming state at the window root*.
- Found while sampling: `RemoteBridge.sessionList()` 294 ms in the same 10 s at idle with **no
  phone attached** (audit cost #4; its build runs even when `clients` is empty). Fixed here
  (guard `!clients.isEmpty` in `listChanged`) since it's also an invalidation-adjacent cost.

## Step 2 approach (chosen by reading the composition)

`RootView → WorkspaceView` is one hosting view: body = ZStack(all panes' `PaneView`s,
sidebar/rail in a `GlassEffectContainer`, drag preview, palette) + `.focusedSceneValue` with a
`FrogWindow` struct the body builds **by value**, reading `workspace.conversation` and
`sidebarOrder` (the whole listing) at the window root. So every streamed turn reads the root,
which re-evaluates the root's children — the sidebar subtree included — per delta. Per-pane
splitting won't change that: the panes' contents live under the same invalidation.

Fix (measurement-guided, not a rewrite):
1. `sidebarOrder` stops being derived in the root body. `Workspace` gains a cached, per-session-id
   sidebar order updated only when its inputs change (`sessions`, `pinned`, `archived`, `parents`,
   `opening`/`current`, grouping app storages) — none of which change on a streamed delta.
   `FrogWindow.sidebarOrder` reads the cache, so the root body stops reading `library.sessions`
   per body.
2. The sidebar subtree gets an explicit boundary from the per-pane content: `SessionList` reads
   `workspace.opening`, `workspace.conversation?.sessionID` (ids, not conversation objects).
   `ChiefTile` keeps reading its own conversation (it's the one tile that must stream).
3. Keep `Library` reads OUT of `ActivityViewer`'s body unless something in the list changed
   (`others` already derives per body; leave for later — it's cost #3, not this task's bar).

Bar to prove: a streamed delta must not cause a sidebar layout pass. Proof: a DEBUG counter of
`SessionList` body evaluations while a conversation streams in the same window — before/after.

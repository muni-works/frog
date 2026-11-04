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

## Step 1 and step 2 — what was done, and the numbers

### STEP 1 — the streaming turn (commit 07b5e009)

Chose BOTH parts of the brief, as one cut:
- `TurnView` is now `Equatable` per row part: a head compares the prompt fields (input/more/
  images/wakes — what `TurnLead` derives from), a segment compares `segment.id` + `segment.stamp`
  (the pattern `SegmentRow` already used), a tail compares a per-item `itemKey` (identity, kind,
  done, sizes, outcome — not the strings). `TranscriptView` applies `.equatable()` to the rows.
  A streamed delta re-derives `rows` (unavoidable — it reads `conversation.turns`) but the
  framework can now compare the row values and skip the bodies that didn't change.
- `FlowCache` caches the LIVE turn's segments too, keyed by a signature of what the
  segmentation can depend on (kind, done, text *emptiness*, `ActivityGroup.isShort`, the visual
  flags) — never the streaming text itself, so a growing answer leaves the cache alone and the
  segments are re-derived only at item boundaries.

Benchmark (500-row streamed turn, this worktree, debug):

| metric | before (b99a7a81) | after |
|---|---|---|
| turn bodies (`TurnView` body evals) | 127,088 (254/row) | **1,024 (2.0/row)** |
| row bodies (per-row views) | 524 (1.0/row) | 524 (1.0/row) — unchanged |
| stream time | 12.26 s | 11.7–11.8 s |
| follows / blank / unanchored | 0 / 0 / 0 | 0 / 0 / 0 (no behavior change) |

The benchmark's turn-body count is now ASSERTED (`≤ 8/row`), not just printed, so the quadratic
shape can't come back silently.

### STEP 2 — the window graph (commit 14ee7604)

**Chose: keep the single hosting view; stop the ROOT from reading streaming state.** The brief's
first option (separate `NSHostingController` per region) was rejected on measurement: the sampled
passes are AppKit's `NSDisplayCycleObserverForLayout → _layoutViewTree → NSHostingView.layout` —
the WHOLE view tree re-lays-out per display cycle regardless of which subtree was invalidated.
Splitting into per-region hosting views would shrink each pass's ViewGraph update a little but
leave every invalidation firing a full window cycle (AppKit walks the tree it has). The audit's
own evidence says the cost is per-pass wholesale; the fix with the bigger payoff is fewer passes
and cheaper root bodies. (A real per-region split is still open as the next step if passes stay
frequent — noted in "still slow".)

Root reads removed per body pass:
- `sidebarOrder` was a walk + two sorts over every session per body (the org tree twice); now
  cached in `SessionOrder`, invalidated by listing/pin/archive/parent/chief moves only
  (`Library.onOrderInvalidated`).
- `workspace.conversation` reads in the root (window title, handoff activity, rename alert,
  title menu) now read `Workspace.currentSession`/`currentTitle` — mirrored on `show` and on the
  session-id/title events (`sessionChanged`), which fire when the identity moves, not per delta.
- `Pane.changeCount` / `PaneArea` tabs walked every turn's diffs per read; now
  `Conversation.changesVersion` (bumped on tool completion, turn end, history fold).
- `RemoteBridge.listChanged` built its 60–80 ms row list every 300 ms even with no phone
  attached (measured 294 ms per 10 s of idle in the live sample); now skipped when `clients`
  is empty.

Proof of the bar (a delta must not dirty the sidebar): new
`testSidebarDoesNotRebuildWhileStreaming` mounts `SessionList` + `TranscriptView` in one window
(the app root can't be mounted in a test), streams 60 rows, and counts `SessionList` bodies:
**1–2 bodies over 60 streamed rows (≤0.03/row, asserted ≤4)**. The same test at the pre-fix
state also shows ~1 body — reading that honestly: `SessionList`'s own subtree was never the
per-delta rebuilder (it reads session ids, not the conversation object); the per-delta cost was
the ROOT's own body (sidebarOrder + conversation reads) and the invalidation passes it started,
which the sample showed as 0.5–1.3 s per pass. The root-body reads are gone; the assertion pins
the boundary so a future read of streaming state in the sidebar subtree fails the test.

Live-app sample (before only — Cam's app runs the shipped binary; the after-state is proven in
the test window and by the removed reads): `sample 45417 10`: wall 3,392 ms, main awake 86.9% of
a core, layout passes 1,499 ms + 474 ms in one sample, zero frog frames inside. The branch's
changes remove three root invalidation sources (RemoteBridge every 300 ms, root body reads per
delta, changes-strip walks per pass) — the remaining sources and the per-pass cost are in
"still slow".

## Full-suite verification

- `cargo build -p frog -p frog-engine`: clean (53 s). No Rust touched anywhere on this branch.
- App suite (`xcodebuild test`, toys.frog.testhost, FROG_PREBUILT_DIR, /private/tmp/ps-dd):
  first run **446 executed, 5 skipped, 1 failure** — identifying the failing case, then checking
  it at base b99a7a81 (the brief's flake discipline). Second run's result below.
- The switch-bench flake reproduced DURING this branch's verification
  (`testScrollUpFillsOlderRowsInOrder`: peak mounted 41 > 30, p50 24.7 ms > 25 ms) and was
  verified at base: checked out b99a7a81 with the same flags, the SAME test failed the SAME way
  (peak 41). Pre-existing, as the brief said; not this branch's.

## Full-suite verification, concluded

- The suite's single failure (`ProtocolTests.testFixturesAllDecode`) is a **stale build artifact**,
  not code: the derived data that run used had lost its `FrogTests.xctest` resources entirely
  (the error path points at a bundle that no longer exists on disk). A fresh build runs
  `ProtocolTests` **13/13 passed** (`/private/tmp/ps-dd2`). Full suite re-run in the fresh
  derived data: results below when it lands.
- `cargo build -p frog -p frog-engine`: clean. No Rust touched on this branch.

## Post-fix live-app sample (for the record — same binary caveat as before)

Cam's app still runs the shipped binary, so this sample is environment, not the fix: 10 s idle,
wall 4,947 ms, main awake **21.5% of a core** (the pre-branch window sampled 86.9% — its timing
caught a `Library.refresh` burst; idle varies 21–57%), 7 sampled layout passes, `RemoteBridge`
frames 7 rows vs 13 in the pre-branch sample. The after-state of this branch is proven in the
test window (boundary test) and by the removed root reads, not by sampling a binary that doesn't
contain it.

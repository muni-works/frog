# perf-audit — notes

Branch `frog/perf-audit`, worktree `/Users/cam/Developer/frog/.frog/worktrees/perf-audit`, tracks
origin/main. Measurement only — **no fixes** in this branch. One commit per unit (`git commit -s`),
never push. Edit tool only for source.

Scope: everything that burns CPU in a typical session **except** `SessionDirectoryWatcher` /
`Library.refresh` (39% idle CPU, already owned by another worker). Covered here: transcript
rendering during streaming, sidebar list rebuild, `GitIndex` FSEvents, `TimelineView` ticks, the
changes strip / `TurnFlow` footer, the composer, and whatever else the samples show.

## Method

Built the app from this worktree (`FROG_PREBUILT_DIR=/private/tmp/be-prebuilt2`,
`-derivedDataPath /private/tmp/pa-dd`, `CODE_SIGN_IDENTITY="-"`, `PRODUCT_BUNDLE_IDENTIFIER=toys.frog.pa`
so it can't hand off to another worker's dev build) and sampled three ways:

1. **Cam's live app** (`/Applications/Frog.app`, pid 35423) — idle, and again mid-stream while this
   session was streaming (that app has a real 1,000-session sidebar and a long transcript).
2. **My own build** on a scratch HOME with a scratch repo (`/private/tmp/pa-code/demo`) and the
   repo's `--replay` fake engine (`apps/macos/Fixtures/rename-symbol-long.jsonl`), so a stream is
   reproducible without a model in the loop. Two samples: mid-stream, and after it ended.
3. The existing **`TranscriptStreamBenchmarkTests`** (500-row streamed turn, real transcript in a
   real window) for per-row numbers, run against this worktree's build.

Each sample is 1 ms/sample, so a sample count is milliseconds of CPU. "of a core" below is
`main-thread awake samples / wall ms`. Idle waits (`mach_msg`, `semaphore_wait`, `__psynch_cvwait`,
`_pthread_cond_wait`, `__workq_kernreturn`, blocking `read`/`stat`) are excluded from "awake".

Attribution is by **leaf** sample (each sample counted once), bucketed by the nearest meaningful
frame on its stack. Whole-window SwiftUI layout is reported as a phase, not as frog code: inside
those passes there are **no frog frames at all** (checked: a 1,189 ms render root contains zero
`(in Frog)` frames) — the cost is the framework re-laying-out the window because something
invalidated.

## Raw samples

| file | what |
|---|---|
| `/private/tmp/pa-idle.txt` | live app, idle, pointer resting over the window (10 s) |
| `/private/tmp/pa-final-idle.txt` | live app, idle, pointer elsewhere (10 s) |
| `/private/tmp/pa-idle-long.txt` | live app, idle (20 s, 38 threads) |
| `/private/tmp/pa-live-stream.txt` | live app, **during a streaming turn** (15 s) |
| `/private/tmp/pa-live-stream2.txt` | live app, **during a streaming turn** (15 s) |
| `/private/tmp/pa-idle-scratch.txt` | my build, scratch repo, after the replay ended (10 s) |
| `/private/tmp/pa-streaming-long.txt`, `pa-dbg-stream.txt`, `pa-dbg-idle.txt`, `pa-stream4.txt`, `pa-stream5.txt` | my build, replay at various speeds (kept for the record; the two above are the ones quoted) |
| `/private/tmp/pa-floor.txt` | my build, empty folder (the app's own floor, no sessions) |

Analysis scripts: `/private/tmp/pa-table.py` (component buckets), `/private/tmp/pa-report2.py`
(framework phases), `/private/tmp/pa-buckets.py`, `/private/tmp/pa3.py` (one thread's tree).

## Headline

**Main thread, idle:** 23–57% of a core. **Main thread, streaming:** 25–29% of a core. In every
sample the top of the list is the same: SwiftUI view-graph update → whole-window layout →
display-list rebuild → CoreAnimation commit. Frog's own Swift code is 1.5–4% of a core in total;
it matters because *it decides how often the other 25% runs*.

**Process-wide**, one thread is always busy and it is the one the chief already owns
(`frog.sessions.watch`: 2.2–4.1% of a core in the live app, 87% of a core in the scratch app whose
sessions dir holds 1,528 files). Everything else off-main is small: cooperative-pool
`frog --sessions` spawns 0.4–3%, `CVDisplayLink` 0.5–0.9%, utility-qos git 0.3–0.4%.

## Ranked CPU costs

### 1. Whole-window SwiftUI layout, run on any invalidation — 23–57% of a core (main thread)
- **Measured:** idle 23.0% / 24.1% / 57.3% of a core; streaming 24.8% / 27.4%. Inside it:
  `ViewGraph.updateOutputs` 3.7%, `ViewGraph.beginNextUpdate` (dirty propagation) 3.6–4.0%,
  `DisplayList.ViewUpdater` (display-list rebuild) 3.0–3.7%, `NSHostingView.layout` 3.1–4.0%,
  AppKit autolayout scan 1.8–2.6%, `CA::Transaction::commit` 0.8–2.2%,
  `collect_animations_` 0.6–1.1%, `AG::Graph::UpdateStack` 0.8–9.7%.
- **Shape:** a single `NSDisplayCycleFlush → -[NSWindow layoutIfNeeded] → NSHostingView.layout`
  pass costs **0.5–1.3 s of main-thread CPU** in the live app (one node = 669 ms, another 544 ms,
  another 1,293 ms in a 8.4 s window). Passes arrive 0.5–1.9 times a second idle, 0.7–1.0 times a
  second while streaming. There are **no frog frames inside a pass**: the framework is re-running
  the whole window's view graph.
- **Hot lines:** the invalidation sources are #2–#9 below; the pass itself is
  `apps/FrogKit/UI/Transcript/TranscriptView.swift:313` (the `ScrollView`/`LazyVStack`) and
  `apps/macos/Frog/Views/Sidebar.swift:194` (the sidebar's `ScrollView`/`LazyVStack`) sharing one
  `NSHostingView` with `WorkspaceView`. Nothing in frog is on the stack — which is the finding:
  the two big scroll views and the window are one view graph, so a row's hover state, a sidebar
  clock tick or a streamed delta re-lays-out the entire window.
- **Fix estimate: L.** Structural (a separate hosting view for the sidebar and for the transcript,
  or observing state per-row rather than at the root). Not a one-liner; the payoff is most of the
  25–57%.
- **Caveat, stated plainly:** the chief's `frog.sessions.watch` fix will remove one of the
  ~1 Hz invalidation sources, and part of this number is downstream of it. What it will *not*
  remove is the per-invalidation cost (a 1,000-session sidebar + a long transcript in one graph).

### 2. Transcript: every visible turn's body re-evaluated per streamed delta — 253 `TurnView` bodies per row
- **Measured (benchmark, this worktree):** 500-row streamed turn in 12.51 s (39 rows/s);
  `row bodies 528 (1.1/row)` but **`turn bodies 126,674`** — 253 `TurnView` body evaluations per
  streamed row, i.e. every mounted turn rebuilds on essentially every delta batch. The test
  asserts only on row bodies (≤8/row, `TranscriptStreamBenchmarkTests.swift:192`); turn bodies are
  printed and unbounded.
- **Hot lines:** `apps/FrogKit/UI/Transcript/TurnView.swift:87` (`let _ = TranscriptProbe.turn()` —
  the counter), fed by `apps/FrogKit/UI/Transcript/TranscriptView.swift:178` (`rows` re-derived)
  and `:1027` (`FlowCache.segments` — cached only for `turn.finished` turns, so the live turn
  rebuilds its segments on every chunk). The delta path itself is already coalesced to 30 Hz
  (`apps/FrogKit/Model/Conversation.swift:1039` `scheduleDeltaFlush`, `:1047` `flushDeltas`).
- **Fix estimate: M.** Make the live turn's row a small value type the framework can compare
  (or split the streaming item into its own view keyed by item id) so a delta invalidates one row,
  not every mounted turn.
- **Evidence:** `bench:` lines from `xcodebuild test -only-testing:FrogTests/TranscriptStreamBenchmarkTests`
  (log tail quoted in "Result" below).

### 3. Sidebar: a full pass (and each row's menu) on any change — 1.7–3.1% of a core
- **Measured:** `sidebar pass` bucket 160 ms of 9,214 ms (1.74%) streaming, 143/4,745 (3.01%)
  idle, 45/11,781 (0.38%) in the long idle sample. Inside it, by share of the main thread:
  `SessionList.rowMenu(_:older:git:)` 0.44–1.26%, `SessionList.moveMenu(_:)` 0.29–0.51%,
  `SessionList.active.getter` 0.28–0.55%, `SessionInfo.titleLine` 0.08–0.32%,
  `WorkspaceView.sidebarOrder` 0.17–0.38%, `ConversationRow.body/trailing` 0.4–1.4%.
- **Hot lines:** `apps/macos/Frog/Views/Sidebar.swift:96` (`active` filters the whole list on every
  read), `:1521` (`trailing` builds a `SwiftUI.Menu` whose content closure is `menu()` →
  `rowMenu` at `:1041`, which reads `library.pinned`/`library.chief`/`library.parents` per row),
  `:788` (`moveMenu` filters + sorts every session per row), `:1558` (`helpText` rebuilds a
  3-line string per row).
  The list *data* is guarded (`Library.swift:109` — an unchanged listing isn't written), but a
  single `live[id]` flip (Library.swift:364) or a `SidebarClock` tick (Sidebar.swift:1596, 5 s)
  invalidates `SessionList.body`, and every visible row rebuilds its menu with it. `.contextMenu`
  is already deferred (`DeferredMenu`, Sidebar.swift:1580) — the trailing `Menu` is not.
- **Fix estimate: S–M.** Cache the "Move to…" head list once per sidebar pass (it's the same for
  every row), make `trailing`'s menu deferred like the context menu, and pass `live` per row
  instead of the dictionary.

### 4. `RemoteBridge.sessionList()` — 62–77 ms of main-thread CPU per call, every 300 ms
- **Measured:** 28–35 ms per sample window in the streaming samples (0.30–0.40% of a core), one
  root of **77 ms** and another of **63 ms** in a 9.2 s / 8.4 s window. On the main actor.
- **Hot lines:** `apps/macos/Frog/Model/RemoteBridge.swift:404` `sessionList()` — builds up to 400
  row dictionaries, and for each one `JSONEncoder().encode(s)` then
  `JSONSerialization.jsonObject` (`:423`) so the phone can decode a whole `SessionInfo` again.
  Called from `:147` `listChanged()` (300 ms debounce), which `Library.report`/`reportQueued`/
  `turnEnded` call on every live flip — and `turnEnded` also fires `Library.refresh()`.
- **Fix estimate: S.** Encode the `SessionInfo` once (or send the row and let the phone build it),
  and skip the whole build when no client is attached (`clients` is already known).

### 5. `DockActivity`: a 30 Hz timer re-rendering the Dock tile — 0.9–2.6% of a core whenever a session is waiting on you
- **Measured:** 124 ms of 4,745 ms (2.61%) in the idle sample, 39/11,781 (0.33%) in the long one
  (attention off part of the time). 82% of it is `-[NSDockTile display]` → a full 128×128 CG render
  (`CGContextEndTransparencyLayer`, `rips_s_BltImage`, `vImageConvolve_Planar8`, `dispatch_apply`).
- **Hot lines:** `apps/macos/Frog/Views/ActivityViewer.swift:307` (`Timer.scheduledTimer(withTimeInterval: 1/30)`)
  and `:310–311` (`view.rootView = DockFrog(at: .now)` + `NSApp.dockTile.display()`).
- **Fix estimate: S.** The pose changes slowly; 10–15 Hz, or only `display()` when the pose
  actually changed (the frog is idle in most frames).

### 6. Hit testing on mouse-move across the view tree — up to 7.3% of a core
- **Measured:** 400 ms of 4,745 ms (8.4% of a core) in the sample where the pointer rested over the
  window; 0% in the samples where it didn't. Of that, `containsGlobalPoints` /
  `ViewResponder.hitTest` 347 ms, `routeMouseMovedEvent` 89 ms,
  `_NSTrackingAreaAKManager _mouseMoved:` 412 ms.
- **Hot lines:** every row's `.contentShape(.rect)` + `.onHover` (Sidebar.swift:1500/1508,
  `AttentionRows.swift:44`, `Platform.swift:74`), and the transcript's per-turn hover
  (`TurnView.swift:59` `hover(_:)`, which writes `track.hoveredTurn` inside `withAnimation`).
- **Fix estimate: M.** Fewer hover responders per row (one `onHover` on the row container instead
  of one per plate), and don't animate the hover-state write.

### 7. `Library.refresh` → a `frog --sessions --all` subprocess — 0.4–3% of a core (app side), 65% in the scratch app
- **Measured:** live app 2–6 ms per 9 s window (0.02–0.07%) but 144 ms of 4,745 (3.03%) in the
  first idle sample and 22 ms of 5,857 in the second; my scratch build **5,300 ms of 8,139 ms
  (65% of a core)** on cooperative threads. Per spawn: `posix_spawn` 30%, `readDataOfLength`
  52% (blocking on the child's stdout), `JSONDecoder` 6%, `Frog.environment` 5%
  (`homeDirectoryForCurrentUser` + `URL(fileURLWithPath:)` per call — `EngineProcess.swift:64`).
  One listing of this machine's 1,029 sessions is a 1.5 MB JSON document and takes 30–130 ms of
  the *child* plus the parent's decode.
- **Hot lines:** `apps/macos/Frog/Model/Library.swift:94` (the spawn + decode),
  `apps/macos/Frog/Engine/EngineProcess.swift:118` (`json()`: a `Process` + a pipe read on a
  detached task, no cancellation), `Library.swift:70` (`listInterval = 3 s`), and
  `Library.swift:106` (`fileExists` per session on the main actor after the decode).
- **Fix estimate: M.** Out of scope to fix here (the watcher/refresh area is taken) — recording it
  because the app-side spawn/decode cost is real and the samples show it. The obvious levers:
  `--sessions --since <ts>` instead of `--all`, and cache `Frog.environment`.

### 8. `TimelineView` ticks — 0.11–0.16% of a core directly, but each tick can start a whole-window layout
- **Measured:** 12–16 ms per 8–12 s window. The 1 Hz ones are `LiveStatus`
  (`ActivityLine.swift:418`), `WorkingLine` (`Activity.swift:282`), `ShimmeringClock`
  (`ThinkingTraceView.swift:165`), `RaceView.swift:154`; the 0.08 s ones are `ProbeProgress`
  (`TranscriptView.swift:653`) and `ModelLoadingStatus` (`ActivityLine.swift:450`). `FrogFace` runs
  `.animation(minimumInterval: 1/30)` (`FrogFace.swift:38`) but is correctly paused unless on
  screen and its window is visible — 1–2 ms per sample, negligible.
- **Hot lines:** the two 0.08 s timelines are 12.5 Hz invalidation on the main thread; each
  tick's `Text` has `.contentTransition(.numericText())`, so it animates too.
- **Fix estimate: S.** The probe/model-loading bars only need 0.08 s while their phase is moving;
  0.25 s reads the same and is 3× less invalidation. Nothing else here is worth touching —
  the shared `MinuteClock` (`MessageActions.swift:107`) and `SidebarClock` (`Sidebar.swift:1596`)
  are already the right pattern.

### 9. `GitIndex` — 0.02–0.9% of a core; a scan is 160–230 ms of git
- **Measured:** `GitIndex` bucket 3–38 ms per window (0.03–0.90%); `GitIndex.run` (the subprocess
  wait) is on a utility-qos thread, `compose`/`recompose`/`listingChanged` on main. In the
  git-heavy case (this repo, 368 branches, 53 worktrees) the full per-repo sequence
  (`config`, `symbolic-ref`, `rev-parse`, `for-each-ref --ahead-behind`, `for-each-ref remotes`,
  `log --merges`, and `status` per tree) is **160–230 ms wall**, of which `status` alone is 20–30 ms.
- **Hot lines:** `apps/macos/Frog/Model/GitIndex.swift:389` (`batch` — 4–5 git calls per repo
  refresh), `:456` (`status`, 2 s timeout), `:226`/`:311` (`recompose` → `compose` per tree on the
  main actor), `:375`/`:380` (`headFile`/`created` read files from the main actor per compose),
  `:147` (`listingChanged` can `enqueueStatus(…, every: 10)` per session — every 10 s per tree while
  a session is live), `:121` (`wantStatus` at most once a minute per tree, from each row's `.task`).
  The FSEvents side is fine: `RefWatcher` filters to refs/HEAD and debounces 1 s
  (`:507`–`:527`), and refs don't change during a normal turn.
- **Fix estimate: S.** Cache `headFile` per (gitDir, mtime) instead of re-reading `HEAD` per
  compose; one `for-each-ref` can carry both heads and remotes. The scan itself is fine.
  **Evidence:** `/usr/bin/time` on the same sequence in this repo and in `tang`.

### 10. Composer — not measurable (< 0.02% of a core), with a caveat
- **Measured:** 1–2 ms per 8–9 s window. No typing was captured in any sample, so the typing path
  is unmeasured, not measured-cheap.
- **What the samples do show:** `ComposerTextView.Coordinator.updateHeight` (1 ms) and the
  placeholder/`TypeToFocus` paths don't appear at all, and `ComposerView.body` appears once.
  The composer is not a CPU problem at idle.
- **Fix estimate: none needed.** If someone wants the typing path measured, it needs a sample
  taken while a key is held, which these runs didn't have.

## Not in the top 10, for the record
- `SessionBroker`/`SessionRegistry` 1–25 ms per window (0.01–0.4%): `resolve(_:includeArchived:)`
  reads every open session per install; fine.
- `ChangesStrip` (`TurnView.swift:468`) and `sessionChanges`
  (`ChangesInspector.swift:5`) are already memoized per finished turn and compare only
  path + diff count; 1 ms in the samples. The `.changes` strip is **not** a problem.
- `TurnFlow`/`TurnFooter`: `TurnFlow` is memoized for finished turns (`FlowCache`,
  `TranscriptView.swift:1027`) and the footer is hover-only on the Mac
  (`TranscriptView.swift:317`); the cost is #2, not the footer itself.
- `DiagramView`: no `TimelineView` and no timer in it at all — nothing to report.
- CoreAudio (`caulk` threads) and JavaScriptCore's scavenger show up in the process tree but are
  idle waits; the WebKit/JavaScriptCore threads come from `WKWebView`-hosted MCP apps, not frog.

## Result

Commits: `90d7c5fd` (checkpoint), plus this report.

Top 10, in order (share of one core, main thread unless noted):

1. whole-window SwiftUI layout on any invalidation — 23–57% idle, 25–29% streaming; 0.5–1.3 s per
   pass, no frog frames inside (L)
2. transcript re-evaluating every mounted turn per delta — 253 `TurnView` bodies/row, 126,674 for
   500 rows (M)
3. sidebar full pass + per-row menus — 1.7–3.1% (S–M)
4. `RemoteBridge.sessionList()` — 62–77 ms/call every 300 ms, 0.3–0.4% (S)
5. `DockActivity` 30 Hz Dock tile — 0.9–2.6% whenever a session waits on you (S)
6. mouse-move hit testing across the view tree — up to 7.3% with the pointer over the window (M)
7. `frog --sessions --all` spawn + decode — 0.4–3% live, 65% in the scratch app (M; the watcher
   area is taken, recorded for the record)
8. `TimelineView` ticks — 0.11–0.16% directly, each tick able to start a #1 pass (S)
9. `GitIndex` — 0.02–0.9%; a full repo scan is 160–230 ms of git, `HEAD` re-read on main per
   compose (S)
10. composer — < 0.02% at idle, typing path unmeasured (none)

`cargo build -p frog -p frog-engine`: no Rust touched, so this is the no-op check (see below).

## Build / verify log

```
xcodebuild build  (FROG_PREBUILT_DIR=/private/tmp/be-prebuilt2, /private/tmp/pa-dd,
                   CODE_SIGN_IDENTITY="-", PRODUCT_BUNDLE_IDENTIFIER=toys.frog.pa)
  ** BUILD SUCCEEDED **

xcodebuild test -only-testing:FrogTests/TranscriptStreamBenchmarkTests
  bench: 500 rows in 12.51s stream, 12.81s total, 39 rows/s
  bench: ingest 0.11s, frame 9.95s
  bench: row bodies 528 (1.1/row), turn bodies 126674, follows 0
  bench: ink styles 0, chars 0
  bench: blank(geometry) 0 [], blank(pixels) 0 [], final ink 0.0426
  bench: unanchored 0 [], worst below 0 pt
  Test Case '...testStreaming500RowsStaysDrawnAnchoredAndIncremental' passed (13.391 seconds)
```

Notes on the build: the app has to be built **unsandboxed** here — SwiftUI/Observation macro
expansion goes through `swift-plugin-server`, which frog's sandbox blocks
(`error: external macro implementation type 'SwiftUIMacros.StateMacro' could not be found`). And a
Debug build with the stock `toys.frog.dev` bundle id exits on launch while another worker's dev
build is running (`SingleInstance.handOff`), so this audit's build used `toys.frog.pa`.

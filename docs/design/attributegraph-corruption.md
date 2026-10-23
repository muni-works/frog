# AttributeGraph corruption (Frog.app SIGSEGV after hours of use)

Status: audited and hardened, **not reproduced**. Branch `frog/attributegraph-crash-audit`.

## The crash

`~/Library/Logs/DiagnosticReports/Frog-2026-10-23-131348.ips`: Frog 0.1.0 (eco.frog, the
installed release), macOS 27.0.1, launched 10:37:42, crashed 13:13:43 (2 h 36 min).
`EXC_BAD_ACCESS (SIGSEGV)`, `KERN_INVALID_ADDRESS at 0xd10006319acf2199`. That address isn't
in any region and its top bits are set: AttributeGraph read a garbage pointer out of its own node
table. Something freed or overwrote graph memory before this frame.

Thread 0 (main, crashed), during the window's layout pass:

```
0  AttributeGraph  AG::Graph::remove_input_dependencies(AG::AttributeID, AG::AttributeID) + 68
1  AttributeGraph  AG::Graph::remove_input(AG::data::ptr<AG::Node>, unsigned long) + 72
2  AttributeGraph  AG::Graph::UpdateStack::update() + 1036
3  AttributeGraph  AG::Graph::update_attribute(AG::data::ptr<AG::Node>, unsigned int) + 356
4  AttributeGraph  AG::Graph::value_ref(...) + 332
5  AttributeGraph  AGGraphGetWeakValue + 400
6  SwiftUICore     closure #1 in ViewGraphRootValueUpdater.render(interval:updateDisplayList:targetTimestamp:)
8  SwiftUI         closure #1 in NSHostingView.layout()
11 AppKit          +[NSAnimationContext runAnimationGroup:]
12 SwiftUI         NSHostingView.layout()
18-33 AppKit       _NSViewLayout … -[NSWindow layoutIfNeeded] … NSDisplayCycleFlush
37-42 QuartzCore   CA::Transaction::commit … flush_as_runloop_observer
53 AppKit          -[NSApplication run]
58 Frog            static FrogApp.$main()
```

Thread 5 (the only other thread doing anything), waiting on main for Handoff:

```
0  libsystem_kernel  __ulock_wait
3  libdispatch       dispatch_block_wait
4  AppKit            -[NSUIActivityManager userActivityWillSave:]
5  Foundation        -[NSUserActivity(UAUserActivityDelegate) willSynchronizeActivity]
9  UserActivity      -[UAUserActivity(Internal) copyWithNewUUID:]
```

Threads 1–3 are AppKit's event thread and two audio threads (FrogSounds' engine); threads 4 and
6–20 are idle workers with no frames. **No Frog code on any thread but main's `$main`.** So the
corruption happened earlier and the layout pass tripped on it.

Thread 5 is the system saving the `.userActivity(Handoff.conversation)` activity
(WorkspaceView.swift:461): it blocks until main runs the update closure, which only reads
`workspace.conversation`. It's a bystander, not a writer.

A second report on this Mac is related: `Frog-2026-10-22-171446.ips` (eco.frog.dev, a test run),
`SIGABRT` from `doesNotRecognizeSelector:` inside `Dictionary._Variant.lookup` in
`SessionDirectoryWatcher.scan()`, called from `SessionDirectoryWatcher.init` ← `Library.init` on
main. A Swift dictionary sending an ObjC message to garbage is heap corruption, in a type whose
state is supposed to be confined to its own queue. See finding 1.

## Hypothesis 1: writes off the main thread

**Against, for the observed models.** Every `@Observable` class in `apps/FrogKit` and
`apps/macos/Frog` is `@MainActor` (Conversation, Library, Panes/Pane/PaneDragger, Workspace,
WindowState, ModelStats, PaneHub, Gists, Lightbox, Race, ProviderStore, ModelDownloads, Updates,
VerbosityOverrides, InkPen, Pond), and the app builds in Swift 6 language mode, so an
off-main write to one is a compile error. The escape hatches were checked one by one:

- `EngineProcess` reads stdout with a `readabilityHandler` into an `AsyncStream` and hops with
  `await MainActor.run` before `onEvent` (EngineProcess.swift:191–203). Clean.
- `Task.detached` uses (SessionBroker, Sidebar, SessionMeta, ModelStats, Git, Pond, Race,
  FileIndex, ProjectGlance, Onboarding, RemoteBridge, RemotePush, Diagram) all return a value to
  the main actor or touch no model. Clean.
- `nonisolated` WKScriptMessageHandler / UNUserNotificationCenter callbacks hop with
  `Task { @MainActor in … }` or `MainActor.run`. Clean.
- `Dictation`'s audio tap (`Microphone`, `@unchecked Sendable`) only calls a `@Sendable` closure
  that hops to the main actor. Clean.
- `DockActivity`'s timer and `ScrollBackdropClear`'s frame observer use `MainActor.assumeIsolated`
  (a trap, not silent corruption, if ever off main). Clean.
- **`SessionDirectoryWatcher` (`@unchecked Sendable`, "state confined to `queue`"): not clean.**
  Finding 1.

### Finding 1 — fixed: the watcher scanned on two threads at once

`init` resumed the directory source and the 1 s rescan timer on `queue`, then called `scan()`
directly on the caller's thread, i.e. main, through `Library.init`. `scan()` and `watch()` mutate
`files` and `snapshot` (plain dictionaries) with no lock, so the directory source (fired by any
other session writing its log, which on this Mac with ~800 sessions and dozens of live agents is
constant) raced main's scan. That is a textbook heap corruption, and the 2026-10-22 crash is that
exact stack. Corrupted heap can land on anything, AttributeGraph's node tables included, which
would explain a crash in AG long afterwards with no Frog frame near it. It's still a one-time
window at launch, so it doesn't explain a crash 2.5 h in on its own; it's the only real data
race the audit found.

Fix (a2de959): the first scan goes on the queue too, and `scan`, `watch` and `readAppended`
`dispatchPrecondition(.onQueue(queue))`. `SessionDirectoryRescanTests.testWatcherScansOnlyOnItsQueue`
starts the watcher and lets it rescan. With the old init-time `scan()` it traps in
`_dispatch_assert_queue_fail ← SessionDirectoryWatcher.scan() ← init ← shared` (the same frames as
the 10-22 crash). With the fix it passes.

Also added (5a9c479): DEBUG `dispatchPrecondition(.onQueue(.main))` in `Conversation.apply` (every
engine event), `Library.report` (every live-status change) and `Library.refresh`, for whatever
slips past the compiler later.

**Sanitizers.** Thread Sanitizer (`-enableThreadSanitizer YES`) over SessionBrokerTests and
SessionDirectoryRescanTests reported **no races**, before or after the fix. TSan didn't catch the
init race either, so treat it as weak evidence. Main Thread Checker (on in the scheme's test
action) reported **nothing** across the full suite and the stress runs. The real Debug app
replaying `Fixtures/rename-symbol-long.jsonl` with `libMainThreadChecker.dylib` injected also
reported nothing. The Address Sanitizer stress runs are under Repro.

## Hypothesis 2: state written during layout and scroll-geometry callbacks

Handlers audited (`onScrollGeometryChange`, `onGeometryChange`, `onScrollTargetVisibilityChange`,
`onScrollPhaseChange`, `GeometryReader`, `onPreferenceChange` (none), `onChange(of:)` ×47):

| Where | Writes | Verdict |
|---|---|---|
| TranscriptView.swift:56 `onScrollGeometryChange` | `below`, `height`, `following`, `parked`, and **`proxy.scrollTo` synchronously**, twice (the follow scroll and the "park at the prompt" scroll inside `withAnimation`) | Worst of the lot. frog#77 defers the follow scroll; **the park scroll stays synchronous in #77** and should get the same treatment there |
| TranscriptView.swift:216 → PaneView `onVisibleTurns` | `WindowState.visibleTurns`, every layout, read by the timeline rail | **Fixed (a522c75)**: written on the next turn, only when changed |
| TranscriptView.swift:149, :203 `onGeometryChange` | `lastTurnTop`, `topInset` (@State; mask and follow decision) | Fine: documented pattern, no layout input |
| WorkspaceView.swift:379–380 | `canvasSize`, `canvasOrigin` → `relayout()` | Fine: the canvas is pinned to the window's size (comment at :375), no loop |
| HuggingScroll.swift:13 | `height` → the scroll view's own frame | A loop only if content is flexible-height; ChangesInspector, ModelPicker and the sidebar's pins feed it fixed-height content. Left alone |
| DiagramView.swift:399 | `width` | Fine |
| PaneView/WorkspaceView `onChange` | `DockActivity`, `Library.focused`/`markRead`, `relayout` | Fine: onChange runs after the update |
| **MessageText `updateNSView`** (not a callback, but it runs inside the graph update) | see finding 2 | **Fixed (0f4d299)** |

### Finding 2 — fixed: MessageText changed SwiftUI's layout from inside SwiftUI's update

`MessageText` is an `NSViewRepresentable`. `updateNSView` runs inside the window graph's update,
and from there, on every streamed token, it:

1. called `invalidateIntrinsicContentSize()` (in `show`), and through `reveal.streaming = …` →
   `InkReveal.finish()` → `grewIfNeeded()` also `invalidateIntrinsicContentSize()` plus
   `superview.needsLayout = true`. That invalidates an input of the graph that's mid-update.
2. built a whole new `NSHostingController(rootView: CodeOverlay)` per code block after the first
   changed block, measured it with `sizeThatFits`, and dropped it: a SwiftUI graph created,
   updated and destroyed inside another graph's update, per token, for hours.
3. removed and freed code-block `NSHostingView`s (`removeLast().removeFromSuperview()`).

Each of those is the kind of re-entrant graph mutation that leaves `UpdateStack::update` holding
inputs that no longer exist, which is the crashing frame. Fix: size invalidations made during
the update are coalesced onto the next run-loop turn (SwiftUI measures the representable again
after the update anyway), freed code views are hidden and released after the update, and one
sizing controller per text view measures every block. The display-link path (`InkReveal.tick`,
outside any update) still invalidates immediately.

The stress harness shows SwiftUI's own layout-loop diagnostics:
`<OnScrollGeometryChange Modifier> tried to update multiple times per frame`,
`ScrollTargetVisibilityChange tried to update multiple times per frame`, and
`Geometry action is cycling between duplicate values`. SwiftUI logs them once per modifier
instance, so they show *whether* a loop exists, not how often. What changed them:

| Run (60–90 s) | OnScrollGeometryChange ×/frame | ScrollTargetVisibility ×/frame | Geometry cycling |
|---|---|---|---|
| origin/main, scrolling and resizing | 2 | 2 | 7 |
| + frog#77 applied locally (not committed) | 2 | 2 | 2 |
| + #77, passive (streaming only) | 2 | 2 | 0 |
| + #77 + park scroll deferred, passive | 2 | 2 | 1 |
| + #77, InkReveal forced off, passive | 2 | **0** | 0 |
| this branch, passive | 2 | 2 | 2 |

So #77 does cut the geometry cycling. The visibility loop comes from the ink reveal growing the
view a line at a time on the display link, and the per-frame scroll-geometry update comes with
any follow-on-growth design. Neither is a corruption by itself. Finding 2's fix removes the
mid-update mutations but not those diagnostics.

## Hypothesis 3: unstable ForEach identity

Audited every `ForEach`, `.id(` and `id:` (subagent sweep plus spot checks):

- `TurnState.id = UUID()` is assigned once when the turn is appended and never rebuilt (turns are
  only appended or edited in place in `Conversation.apply`). Stable.
- `ItemState.id` comes from the engine, and `upsert` dedups it. `TurnFlow.Segment.id` and
  `ThinkingStep.id` derive from item ids. Stable and unique.
- Sidebar: `SessionNesting.rows` places each session once (`placed` set). `frog --sessions --all`
  on this Mac returns 808 sessions with **0 duplicate ids**. `ForEach(projects, id: \.folder)`
  comes from grouping, so it's unique.
- `id: \.offset` over append-only arrays (Markdown segments, ThinkingStepView paragraphs, diffs,
  images, diagram edges) and `ThoughtSubtitle`'s `.id(index)` (deliberate, for its fade) churn
  identity during streaming but are legal. No duplicate ids, and no `UUID()` in a body.

**No identity instability found that would explain the crash.** Nothing changed.

## Hypothesis 4: animations and timers

- `.animation(_, value:)` values are all `Equatable` state (`unseen`, `changesVisible`,
  `hasRail`, `findShown`, `hovered`, `dragger.active`). Fine.
- `withAnimation` wrapping a mutation inside a scroll callback: the park scroll in
  `onScrollGeometryChange` (TranscriptView.swift:75). Belongs with frog#77, see the table above.
- Timers: `DockActivity` (dock tile only, no model), `MorningNotice` (30 min), `TimelineView`s
  (view-local), `InkReveal`'s `CADisplayLink` (AppKit layout, see finding 2), the watcher's
  dispatch timer (finding 1). Nothing else writes model state on a tick.

## Repro

- **Harness**: `apps/macos/FrogTests/LayoutStressTests.swift` (6f04c47). Two transcripts with
  rails on one conversation, streaming answers with two code blocks plus tool output, faster than
  real time (~200 events/s unsanitized), with programmatic scrolling, window resizes ("splits")
  and rail jumps. `TEST_RUNNER_FROG_STRESS_SECONDS=N`, `TEST_RUNNER_FROG_STRESS_PASSIVE=1`.
- **Runs**: about 12 min of stress in total. Address Sanitizer on origin/main code for 180 s and
  on this branch for 240 s; plain runs of 60–90 s at each step in the table above. **No crash,
  no ASan report.** The real Debug app replaying a fixture under Main Thread Checker also stayed
  quiet. Desktop automation (Accessibility) wasn't available, so the real app couldn't be
  scrolled; the harness scrolls instead.
- **Not reproduced.** The installed app crashed after 2.5 h of real use with ~800 sessions in the
  sidebar and many live agents. The harness compresses streaming, not hours of sidebar churn.

## Most likely cause, and what's left

Most likely: re-entrant graph mutation from `MessageText.updateNSView` (finding 2), with the
synchronous `scrollTo` calls in `onScrollGeometryChange` as the other mid-update mutator. That's
inferred from the crashing frame and the code, not proven. The watcher race (finding 1) is the
only proven memory-corruption bug, but it only fires at launch.

Next, if it recurs:

1. Land frog#77 and defer its remaining synchronous park `scrollTo` the same way.
2. Run the dogfood Debug build with `MallocScribble=1 MallocGuardEdges=1` (or ASan) for a working
   day. A heap corruption then crashes at the writer instead of hours later in AG.
3. Look at `Library.refresh` running `frog --sessions --all` up to once a second (every watcher
   change) and replacing ~800 `SessionInfo`s each time. That's the main thing hours of heavy use
   adds that the harness doesn't.

# Mac app: live perf and fuzz pass, 2026-11-05

Follows `fuzz-findings-2026-11-05.md` on `claude/fuzz-ux`, which only read the code. This pass ran things.

## What ran and what didn't
- Build: Debug, `main` at 67b64bd8, xcodegen then xcodebuild, engine binaries via `FROG_PREBUILT_DIR` (copied from the existing Debug bundle).
- Single instance: Debug is `toys.frog.dev`, but `instance.lock` is machine-wide (any build). No Frog was running, so launching was safe. The launch ran with `FROG_GATEWAY` and `FROG_PUSH_RELAY` pointed at a dead local port, so nothing reached Frog Cloud. It was killed after a minute, and its stale lock gets taken over on the next launch.
- **No live UI driving.** The computer-use grant for `toys.frog.dev` was denied. When launched from the agent shell, the app ran its event loop but never put a window on screen (no CGWindow after 30 s, 21 MB footprint), probably because of the shell sandbox. Not measured: **cold start to first window, VoiceOver, light/dark, and real Animation Hitches/Time Profiler traces**.
- Instead, an XCTest probe (not committed) hosted the real `TranscriptView` and `ComposerTextView` in an `NSWindow` inside the test host. It fed the views synthetic engine events (the same envelope path as `LayoutStressTests`) and timed layout plus display per action.
- Caveat: Debug build (`-Onone`) on the test host. Release will be faster, but the scaling holds either way (linear in draft size, per-delta cost growing with turn count).

## Findings, ranked by user impact

### 1. Each keystroke costs time in proportion to the draft size: a 1 MB paste makes typing lag 156 ms per key
- **Repro:** paste a large log or file (1 MB) into the composer, then type.
- **Numbers** (`ComposerTextView` alone, so the real `ComposerView` is worse):

  | draft | paste | per keystroke p50 / max |
  |---|---|---|
  | 0.1 MB | 99 ms | 17.3 / 18.6 ms |
  | 1 MB | 703 ms | 156 / 157 ms |
  | 5 MB | 3.36 s | 767 / 798 ms |

- **Why:** `textDidChange` copies the whole string into the binding. `updateNSView` compares `tv.string != text` over the full string. The height fit lays out the whole text. In `ComposerView` the same key also runs `canSend` (it trims the full text), the slash-suggestion check, `.onChange(of: text)` twice (`saveDraftSoon` and `panes.noteDraft`), and `.task(id: text)`, which hashes the full string.
- **Fix:** `apps/macos/Frog/Views/ComposerTextView.swift`: keep the `NSTextView` as the source of truth and push text to the binding debounced, or only on send or draft save. Use a generation counter in `updateNSView` instead of a string compare, and turn on non-contiguous layout. `apps/macos/Frog/Views/ComposerView.swift`: give `canSend` an early-exit check for non-whitespace, and key `.task(id:)` on an edit counter.

### 2. A large draft is resent to the engine after every typing pause
- **Why:** `ComposerView.warm()` sends `.warm(draft: text)` with the full draft each time `.task(id: text)` settles (400 ms), and on every app activation. A 5 MB draft means 5 MB plus a prefill on each pause. This was found in the code; the bytes on the wire weren't measured.
- **Fix:** `ComposerView.swift`: cap the warm draft (the last 8 KB, or skip it above N tokens) and skip it when the text hasn't changed.

### 3. Jumping in a 300-turn transcript drops frames: 44 ms p50, 59 of 60 jumps over budget
- **Repro:** a 300-turn conversation (tool call, two code blocks and a list per turn). Jump through it with the rail, ⌘↑/⌘↓, or by dragging the scroller.
- **Numbers:** jump p50 44 ms, p95 57 ms, max 63 ms (59 of 60 over 16.7 ms). Smooth 40 pt steps: p50 1.6 ms, 9 of 200 over budget. Ingesting 300 turns took 311 ms; first layout took 170 ms.
- **Why:** every jump lands on unmeasured turns, and each one is an `NSTextView` with a hosting view per code block.
- **Fix:** `apps/FrogKit/UI/Transcript/TranscriptView.swift` and `MessageText.swift`: cache turn heights by id and width. Draw code blocks as attributed text, not a hosting view per block. Build attributed strings for completed turns off the main thread.

### 4. Streaming uses more than half a core, and more as the transcript grows
- **Numbers:** empty conversation: streaming 56% CPU, idle 10%. After 300 turns: streaming 74%, idle 0%. Pinned to the tail after a scroll and resize session, it hit 100% of a core (15.1 s CPU in 15.1 s wall).
- **Why (likely):** each delta re-parses the markdown of the whole streaming message and rebuilds code blocks. The rise with turn count suggests the body is re-evaluated over all turns on each delta.
- **Fix:** coalesce deltas to one update per frame in `Conversation.ingest`, and re-parse only the tail block (`MessageText.swift`). Check with `_printChanges()` in `TranscriptView`/`TurnView`.
- **Odd:** an empty transcript idles at 10% CPU (300 turns idle at 0%). Something animates in the empty state, probably `FrogFace`.

### 5. Live window resize stutters with a long transcript: 31 ms p95, one 101 ms frame
- **Numbers:** p50 14 ms, p95 31 ms, max 101 ms; 11 of 30 resizes over 16.7 ms.
- **Fix:** a height cache keyed by width bucket. During `inLiveResize`, lay out only visible turns (`TranscriptView.swift`).

### 6. Memory: about 380 KB per turn, and a 5 MB draft costs 20× its size
- **Numbers:** test host at start 410 MB. Empty transcript window: +39 MB. After 300 turns: 563 MB (+114 MB). After 5 more streamed turns and scrolling: 574 MB. Composer +97 MB for a 5 MB draft.
- **Fix:** find what completed turns keep alive under `apps/FrogKit/UI/Transcript/`. Needs an Allocations trace on a real session to confirm.

### 7. The orphaned `frog-apple` helper outlives Frog; the lock fd has no CLOEXEC
- **Repro:** at the start of this pass, `frog-apple --port 8912` (ppid 1, from an old Debug bundle) was running with no Frog app running.
- **Also:** `LockHolder` opens `instance.lock` without `O_CLOEXEC` (`apps/macos/Frog/FrogApp.swift`, about line 270). A child that inherits the fd would keep the flock after the app dies. It didn't happen here.
- **Fix:** `O_CLOEXEC` on the lock. Have sidecars exit when their parent does (`sidecars/frog-apple`, `apps/macos/Frog/Engine/EngineProcess.swift`).

### 8. A Debug build blocks the installed Frog
- While any Debug build holds `instance.lock`, the installed `toys.frog` takes the `exitQuietly` path in `InstanceDecision.decide` and doesn't open, with no message.
- **Fix:** `FrogApp.swift`: show an alert or activate the holder. Or let Debug builds skip the machine-wide lock.

### 9. VoiceOver (code read only)
- The send and stop buttons and dictation are labeled. The "+" menu (`ComposerView.swift:428`) has only `.help`, so VoiceOver reads the symbol name ("Add").
- There are 186 `Image(systemName:)` against 17 `accessibilityLabel` calls, and about 50 icon-only button labels.
- **Fix:** add `.accessibilityLabel` to icon-only buttons, then run Accessibility Inspector's audit live.

## Not measured; needs the app grant or a person
- Cold start, VoiceOver, light/dark, and `xctrace` Animation Hitches with `--attach <pid>` while scrolling a long session.

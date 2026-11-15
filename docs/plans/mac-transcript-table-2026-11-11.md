# Mac transcript: streaming row, NSTableView container (2026-11-11)

Follows `mac-live-findings-2026-11-05.md` (findings 4, 5 and 6, and the 10% idle CPU) and step 4 of
`mac-transcript-jumps-2026-11-05.md`.

## What changed

1. **The streaming answer updates its own row, not the transcript.** Its text lives in a
   per-item `LiveText` (`apps/FrogKit/Model/Turns.swift`), observed only by the view that draws
   it (`TypingBubble`, through `ItemState.streamedText`). A delta no longer writes into
   `Conversation.turns`, so it no longer re-runs the transcript body, the rows and every row's
   equality check. A change the structure can see (the first words) still goes through `turns`.
2. **Bug fixed on main.** Since 07b5e009, `FlowCache` held the live turn's segments, with the
   answer as it was at its first delta. The answer froze at its first word until the message
   completed. `StreamingTextTests` covers it.
3. **Code blocks are measured by line count.** They never wrap, so a block streaming in costs one
   SwiftUI sizing pass per new line, not one per token. `MessageTextView.show` counts code blocks
   from the blocks instead of walking the storage. `setSelectedRanges` skips the code-tint walk
   when nothing is or was selected.
4. **`TableTranscript`** (`apps/FrogKit/UI/Transcript/TableTranscript.swift`) is an
   `NSTableView` of the same `TurnView` rows, behind `TranscriptContainer.table`:
   `defaults write toys.frog.dev transcriptTable -bool YES`, or `FROG_TRANSCRIPT_TABLE=1`.
   - A row that isn't on screen is a cached height. Its first guess is learned from measured
     rows of the same kind.
   - A row's content reports its own height through `onGeometryChange`, and only that row is
     noted.
   - When a row above the view changes height, the scroll position is adjusted so the view
     stays still.
   - Rows going in above (older history folding in) are anchored in the same pass.
   - `prepareContent` is limited to the visible rect.
5. **Stack fix.** Older history folding in above no longer pins `shownFrom` to a turn far up in
   it (`TurnEnds`). Before, the stack rebuilt hundreds of rows and settled a second time.
6. **Empty page.** It already idled at about 0% after the `FrogFace` change ("still until
   hovered"). `IdleCPUTests` now keeps it under 2% for both containers.

## Numbers

All on the same machine, an M-series Mac shared with other sessions' builds (load average
7–34). "Before" is `main` at 11ca1819.

| | before (main, stack) | after, stack | after, table |
|---|---|---|---|
| Live stream at the tail of 300 turns, 30 Hz batches, **Release** | n/a¹ | 47–49% of a core | **27%** (22% without the ink) |
| Findings method: 5 turns streamed at 60 Hz at the tail (Debug) | 55% ² | 54% | 54% |
| Resize p50 / p95 / max (Release) | 9.2 / 19.6 / 48.9 ms³ | same | **4.9 / 5.9 / 7.4 ms**, 0 of 30 over budget |
| Resize (Debug) | 12.5 / 23.0 / 75.4 ms | 12.6 / 19.6 / 61.9 ms | **7.1 / 9.4 / 11.6 ms** |
| First layout after 300 turns (Debug) | 74 ms | 109 ms | **3 ms** |
| Jump p50 / p95 (Debug) | 16.9 / 24.6 ms | 17.6 / 23.3 ms | 21.2 / 28.3 ms |
| Frame after a jump p50 (Debug) | 16.6 ms | 19.6 ms | **7.0 ms** |
| Switch to 400 / 5,000 rows, ready (Debug) | 76 / 373 ms (5,000 fails) | ~360 / ~350 ms (race) | **62–87 / 63–87 ms** |
| Scroll-up peak rows built | 41 (fails) | 41 | 22–23 |
| Empty page idle | 0% | 0% | 0–0.4% |
| Memory after 300 turns (Debug) | 440 MB | 440 MB | 676 MB⁴ |

1. Not measurable: on main the answer didn't redraw while it streamed (item 2 above). Main's
   streaming CPU was measured while redrawing nothing.
2. The findings method sends one 4-character delta per 16 ms frame through `ingest`, with no
   engine link. That skips the 30 Hz batching the app does (`Conversation.scheduleDeltaFlush`),
   so it measures 60 updates a second, twice what the app ever does. `testStreamLive` is the
   realistic probe.
3. The Release stack figures are from the "after" build (the stack code is unchanged there).
4. The probe runs the table after the stack in one process, so this number includes the stack's
   leftovers. It isn't a clean per-turn comparison. Finding 6 (memory per turn) needs an
   Allocations trace on a real session and wasn't done here.

**Short of the target.** The streaming target was under ~20% of a core. The table is at 27% in
Release with the ink, and 22% without it. What's left is one growing text row's TextKit layout,
display and CA commit, plus the ink's 60 Hz display link (about 5 points). Running the ink at
30 Hz would roughly halve its share, but that is a design call (the pen on a 120 Hz display), so
it isn't made here.

## What the table doesn't do yet (why it's behind a flag)

- **Not driven live.** Everything above was checked in the XCTest host (`TableTranscriptParityTests`,
  the switch benchmarks, the perf probe), not in the running app by a person. Before it becomes
  the default: VoiceOver, light and dark, scrolling with a trackpad and with a scroller drag,
  and the rail and find against a real session.
- **Accessibility.** The rows are table cells, so VoiceOver announces a table. The stack reads as
  a scroll area. The table probably needs `setAccessibilityRole(.group)` or similar.
- **Keyboard scrolling.** The table refuses first responder, so Page Up/Down and Space don't
  scroll it unless a text view inside has focus. The stack had the same gap, but it's unverified
  here.
- **Long-answer stop and the pill.** `parkAtLongAnswer` and the `NewBelowPill` hookup are
  implemented but have no parity test.
- **Scroll-up frame budget.** In Debug, p50 is 22.6–25.5 ms against the 25 ms budget, about the
  same as the stack (25.0 ms on main). The frame's cost is building each row's `NSTextView` and
  styling its markdown. Reusing text views across rows would need `InkReveal` to reset when a
  view gets new content. Today a reused view would replay the ink on a finished message.
- **iOS** keeps the lazy stack. `TableTranscript` is macOS only.
- `RaceView` uses `TranscriptView` and follows the flag. It wasn't checked.

## Probes

- `PerfProbeTests` (`TEST_RUNNER_FROG_PERF_PROBE=1`):
  - `testLongTranscript` and `testStreamCost` run each container.
  - `testStreamLive` is the 30 Hz live stream: stack, table, and table without ink.
  - `testStreamProfile` brackets a stream for `sample <pid>`, with before/after `LiveText`
    switched in-process (`Conversation.streamsLive`).
- `TranscriptSwitchBenchmarkTests` run on the table. Set `SWITCH_BENCH_STACK=1` to run them on
  the stack.

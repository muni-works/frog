# Mac transcript: dropped frames on jumps (plan, not done)

Finding 3 in `mac-live-findings-2026-11-05.md`: in a 300-turn transcript, jumps take 42 ms p50
and 59 of 60 go over the 16.7 ms frame budget (Debug, PerfProbeTests.testLongTranscript).

## Why it isn't a contained fix
- The transcript is a SwiftUI `LazyVStack` of `TurnView` rows (`TranscriptView.transcript`).
  A lazy stack can't take a height it didn't measure. Every row a jump lands on is built from
  scratch: a `MessageTextView` (TextKit 1), the markdown turned into attributed text
  (`MessageStyle.piece`), then one `NSHostingView<CodeOverlay>` per code block plus a
  SwiftUI sizing pass for each. A height cache keyed by turn id and width can't skip any of
  that, because the stack still makes the view to place it.
- Tried: a shared code-block height cache in `MessageTextView.measure`. Jumps stayed the same
  (42.2 ms p50, 59/60 over budget), so measuring code isn't the cost. Building the views is.
  Reverted.
- Drawing code blocks as attributed text means a new code-block renderer. Today's blocks
  have syntax colour, a header, horizontal scrolling and selection tint, all from SwiftUI
  `CodeBlock`. That's a redesign, not a perf patch.

## Plan
1. **Measure first.** Use Time Profiler on the probe's jump loop to split the 42 ms between
   SwiftUI row building, `MessageStyle.piece`, TextKit layout and hosting-view creation. Use
   `_printChanges()` on `TurnView` to find body re-evaluations that aren't needed.
2. **Cache attributed text per finished block** (block hash plus appearance) next to
   `FlowCache`. A row that comes back skips markdown styling. The code attachment cell is
   per view, so cache the text without the cells and add the cells on insert.
3. **Create code views lazily.** Make the hosting view for a code block only when its rect
   meets `visibleRect`. Until then, the attachment cell draws a cheap placeholder (the plain
   monospaced text, already measured). Most rows a jump passes through are never seen.
4. **Optional: an `NSTableView`/`NSCollectionView` transcript.** Rows get cached heights
   (`heightOfRow` from a cache keyed by id and width bucket) and reuse. This also fixes live
   resize (finding 5). It's the real fix, but it's a rewrite of `TranscriptView` and its
   scroll anchoring, rail and follow logic.

Expect steps 2 and 3 to get jumps under budget in Release. Check against the probe before
going further.

## Done (contained, 2026-11-05)
Steps 3 plus two findings from sampling the jump loop, all in `MessageTextView`:
- Code-block hosting views are made only for blocks in `visibleRect`, on the run-loop turn after
  the row comes in. Until then the attachment cell draws a placeholder (card, language, plain
  monospaced code). Making views half a screen ahead put a jump's neighbours into the next
  frame (21 ms p50), so it doesn't do that.
- One shared code-block sizer plus a height cache, instead of one `NSHostingController` per view.
- `MessageTextView` stops listening for every view's frame change. NSTextView registers for all
  of them, and that cost scales with the number of rows.
Probe (Debug): jump p50 44.8 → ~16 ms; the frame after a jump 16.3 → 13.2 ms; small scrolls
1.6 → 0.8 ms. Step 2 (caching styled text) was skipped: `MessageStyle.piece` was about 2% of a jump.
Step 4 (`NSTableView`) is still the fix for p95 and live resize.

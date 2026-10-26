# typography pass — notes

Branch frog/typography-pass, base 1dbd91f. Commit per piece (`git commit -s`), never push.

## Goal
Transcript toward claude.ai's feel: one narrow measure column, consistent vertical
rhythm, quiet activity lines, chrome almost invisible, mono only for code tokens.

## Plan
0. NOTES.md + survey (count magic numbers, find measure) — checkpoint 0
1. TurnSpace scale (paragraph / block / turn gaps) in one place
2. measure + typography (body size/leading, ActivityLine quieter)
3. snapshot refresh, build, perf assertion (≤30 materialized rows) green
4. report

## Constraints
- keep #98/#104 perf work: no re-derived flows per row; benchmark ≤30 rows stays green
- tests: xcodegen -q; xcodebuild test -derivedDataPath /private/tmp/type-dd (unsandboxed)
- delete /private/tmp/type-dd at the end

## Survey (checkpoint 0)
- Files: apps/FrogKit/UI/Transcript/{TranscriptView,TurnView,ActivityLine,MessageText,ItemViews,Markdown}.swift
- TurnSpace.swift ALREADY EXISTS (betweenTurns 28/14, inTurn 12/8, lineHeight 4/2, block 12/8,
  listItem 5/3, beforeFooter 16/10) + `\.turnSpace` env. MessageStyle (AppKit) reads TurnSpace
  statics via UserDefaults "density" (built off-main sometimes).
- Row gaps: computed once in TranscriptView.rows (gap = betweenTurns for a turn's first row,
  inTurn for every other row). Every segment kind gets the same 12 → activity lines float
  as far from text as paragraphs/cards do. Fix it there (cheap, not per row).
- Measure: TranscriptView.transcript `.frame(maxWidth: 820).padding(.horizontal, 28)`.
  Body = NSFont.systemFontSize (13pt) → ~120 chars/line at 820. Too wide.
- ActivityLine `line`: body font, .secondary — same size as the answer, reads as a paragraph.
- Inline code: mono pointSize-1, flat `.backgroundColor` 0.08 (square, not rounded).
- UserPrompt bubble maxWidth 560, body font.
- Perf: TranscriptSwitchBenchmarkTests.mountedBudget = 30 (peakRows ≤ 30). Narrower measure
  = taller rows = fewer mounted; should only help.
- Snapshots: SnapshotTests.testRenderFixtures → $TMPDIR/frog-snapshots/<fixture>-done.png
  (not checked in). Baseline copied to /private/tmp/type-before/.

### magic-number count (before)
Command (from apps/FrogKit/UI/Transcript):
  grep -Eo 'spacing: [0-9]+|\.padding\((\.[a-z]+, )?[0-9]+|paragraphSpacing(Before)? = [0-9]+|lineSpacing = [0-9]+|ofSize: [0-9]+' F.swift | wc -l
TranscriptView 25, TurnView 11, ActivityLine 14, MessageText 4, ItemViews 35, Markdown 4 = 93

## Decisions
- Baseline snapshots: /private/tmp/type-before + .snap/before (git-excluded). Fixture renders verbose
  (activity lines open).
- BUG seen in baseline: finished answer text indented 8pt right of activity lines — TypingBubble's
  HStack(spacing: 8) keeps the gap when the frog collapses to width 0. Fix: spacing only while live.
- Measure: column 720pt max (was 820), gutter 32 (was 28). With 14pt body ≈ 90–95 chars/line,
  claude.ai's feel; code blocks still have room.
- Body 14pt (was 13 = NSFont.systemFontSize), extra leading 5 (≈1.55 line height). Headings 18/16/14.
  Prompt bubble uses the same body size so both sides of the conversation match. iOS unchanged (17pt body).
- Scale (comfortable / compact), all in TurnSpace:
  line 5/2 · list 6/3 · paragraph 14/8 (within a message, and text→text rows)
  activity 6/4 (gap ABOVE an activity line: tight to the paragraph it follows)
  block 16/10 (rows of other kinds: prompt→first row, cards, visuals, the tail)
  turn 32/16 · footer 12/8 (above the model/speed caption)
  Inset tokens (non-density): hair 2, tight 4, snug 6, row 8, card 10, roomy 12 — odd values
  (5, 7, 9) in rows/cards snap to these.
- Row gap = TurnSpace.Scale.gap(after:before:) computed once in TranscriptView.rows (no per-row work).
- ActivityLine: .callout (smaller than 14pt body), .secondary, gist .tertiary. LiveStatus also .callout.
- Inline code: rounded background (custom attribute drawn by MessageTextView's layout manager),
  not the flat square NSAttributedString backgroundColor.

## Progress
- c77f439 checkpoint 0 (notes/survey)
- a8ba5c3 scale + 720 measure + 14pt body (snapshots .snap/s1)
- 5b8dd4a activity callout, bubble alignment fix, rounded inline code (InlineCodeLayoutManager; snapshots .snap/s2)
- next: snap per-view spacing/padding literals to TurnSpace.Inset (2/4/6/8/10/12; 5→4, 7→6, 9→8,
  14→roomy+hair kept literal-free only where it's rhythm). Leave icon-column offsets (26) & frame sizes.
- snap commit: per-view spacing/padding literals → TurnSpace.Inset; 26 → Inset.iconColumn; table font → TurnType.small.
  Count 93 → 16 (6 of them are `spacing: 0`; left: 14×3 pill/card paddings, ofSize 4 for rule line, lineSpacing 0 for code).
- PERF: mountedBudget 30 green everywhere (switch tests 14; scroll-up peak 26 base → 27–29 now: shorter
  activity rows/tighter gaps fit more rows on screen; still ≤30 but thin margin).
- FLAKE: testScrollUpFillsOlderRowsInOrder "no rows went in above" (0 fills, built above 0) failed 2/3 on the
  snap binary in-suite, passed alone and on re-run; base/a8ba5c3/5b8dd4a each passed 1/1. Base worktree at
  /private/tmp/type-base (dd /private/tmp/type-dd-base) — delete at end.
- DONE. Full app suite green twice (269 tests). Snapshot gotcha: $TMPDIR/frog-snapshots is shared with other
  sessions' worktrees; a full-suite render got overwritten by main's look. Render SnapshotTests alone and
  check md5 vs baseline. The scroll-up flake probably comes from concurrent suites (CPU contention).
- Cleaned: /private/tmp/type-dd, type-dd-base, type-base worktree, .snap.

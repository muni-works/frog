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

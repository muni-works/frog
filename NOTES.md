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
(pending)

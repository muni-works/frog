# worktree UX — notes

Branch frog/worktree-ux, base 115b40d, path /Users/cam/Developer/frog/.frog/worktrees/worktree-ux.
DESIGN-ONLY (docs + mockup). Commit per piece (`git commit -s`), never push. Edit tool for source.

## Plan
0. NOTES.md (this) — checkpoint 0
1. survey: worktree creation (SessionBroker/StartSession), flock (session.rs), git_dirs (bash.rs), #107
2. docs/design/worktree-ux/README.md — spec, five areas, failure modes, #107 guard
3. docs/design/worktree-ux/mockup.html — workers sidebar scope + teardown prompt
4. report (≤30 lines, shas, open questions)

## Survey (checkpoint 1, verified in source at 115b40d)
Creation (apps/macos/Frog/Model/SessionBroker.swift):
- StartSession input → StartRequest{title,prompt,cwd,model,mode,worktree(default FALSE),allowMainCheckout} :93, :362.
  So "auto worktree" is NOT automatic: without worktree:true, checkWorkerFolder :1166 REFUSES the main checkout
  (repo root holding .frog/worktrees; names up to 3 existing trees to reuse) unless allow_main_checkout, refuses a
  worktree whose engine lock is held, and REUSES any free worktree as-is (no check it's the caller's).
- makeWorktree :1187: base = worktreeBase :1096 (origin/HEAD → origin/main|master → current branch if no remote);
  name = slug(title) (≤40 chars); COLLISION = silent renumber: while dir or branch frog/<pick> exists → <slug>-2, -3…
  `git worktree add -b frog/<pick> .frog/worktrees/<pick> <base>`; adds /.frog/worktrees/ to info/exclude.
  Result {id,name,cwd,branch,base}. Parent recorded via Library.setParent (owner = spawning session).
- A restart that re-calls StartSession with the same title gets <slug>-2: a NEW empty tree, the old one's work
  stranded. Silent. That's the collision bug class, not "wrong tree" but "lost tree".
Flock (two separate locks):
- session.rs Log::locked :181 — flock on the session JSONL, one writer per session; in_use/wait_free probe it.
- worktree.rs — the per-worktree ENGINE lock: `.git/worktrees/<name>/frog-engine.lock`, flock LOCK_EX|NB, content
  "<session> <pid>". acquire() :84 at engine start (engine.rs:521, not subagents) on opts.cwd = PROCESS cwd; same
  session waits ≤5 s (relaunch), other session → error naming holder + pid. Released on drop / process death
  (engine.rs:941 before "engine gone"). App mirrors it read-only: worktreeOwner :1151 (try-lock probe).
  Main checkout (`.git` dir) never locks.
- No stale cleanup exists. A dead holder = lock free (flock semantics) but the tree, branch, lock file stay forever.
Resume path (#107 relevance):
- conversation(for:) :990 resumes with Conversation(folder: info.folder) — info.cwd from `--sessions --json` =
  HEADER cwd (main.rs:964). SessionStatus prefers the log's last ShellCwd/UseFolder (:1416). So a session that `cd`'d
  into a worktree resumes in its header cwd (the main checkout) — linked() is None there → NO lock, no refusal.
  Likely mechanism of #107 incident 2. #107 (OPEN): engine compares serving cwd vs session's recorded tree, refuses.
- Library listing drops sessions whose cwd no longer exists (Library.swift:66): removing a worktree makes its
  sessions vanish from the sidebar (log kept). Teardown must archive first / keep a record.
- engine.rs:3788: cwd deleted under a live session → falls back to session root with a warning.
Visibility today:
- ListSessions fields branch/ahead/dirty + SessionStatus via Git.quick (status --porcelain=v2 --branch): ahead is
  vs UPSTREAM (nil for unpushed frog/* branches). Sidebar SessionMeta "3↑" = rev-list base..HEAD (vs main).
  Two different "ahead"s. SessionFolds folds same-worktree sessions into one row. RowSuffix shows the branch name.
- Sidebar scope: AttentionTree.Scope live|today|all, `@AppStorage("sidebarScope")` (Sidebar.swift:43, picker :394).
Teardown today: none. ArchiveSession = hide only. checkpoint.rs has `worktree remove --force` + prune for race attempts.
Sandbox (bash.rs):
- git_dirs(ctx.root) :608 = `git rev-parse --git-dir --git-common-dir`, canonicalized, deduped. Passed from :277 with
  the SESSION root (not shell cwd: a cd elsewhere doesn't widen it). seatbelt :759: allow default, deny file-write*,
  re-allow root, tmp, caches, git dirs, allow_write; deny secrets (read+write). bwrap same list on Linux.
- Guarantees: worktree files writable; main checkout's FILES not writable; other worktrees' files not writable.
- Does NOT guarantee: common dir = whole main .git → shared refs (branch -f main, update-ref), refs/stash (shared
  across worktrees! the #107 stash incident), main's .git/index + HEAD, OTHER worktrees' .git/worktrees/<x>/ (their
  index, HEAD, frog-engine.lock), `git worktree remove/prune` admin entries. Reads: allow default (all but secrets).
- Engine also: Write/Edit outside the session root (e.g. main checkout) asks, denied headless (engine.rs:4965).

## Progress
- e8d1e26 checkpoint 0 · c5009a3 survey · ccaa3f8 README spec · mockup commit (workers scope + teardown sheet
  + named refusal card; screenshot-checked at 1360w). DESIGN DONE — awaiting Cam's review before any code.

---

# typography pass — notes (previous task, kept)

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

## Round 2 — more vertical space, bullet lists (Cam)
- BUG: bullets got paragraphSpacingBefore = paragraph gap AND paragraphSpacing = list gap; TextKit adds
  them, so items sat 20pt apart (5 leading +14 +6), MORE than paragraphs (14). Inverted hierarchy.
- Fix: every gap comes from paragraphSpacingBefore only, chosen from (previous block, this block):
  heading → section; after a heading → afterHeading; bullet after bullet → list; else paragraph.
  `TurnSpace.Scale.gap(_ block:, after:)` (cross-platform, used by AppKit MessageStyle and iOS BlocksView).
- Values (comfortable/compact): line 6/2, paragraph 16/8, list 6/3, section 28/16, afterHeading 6/3.
  Visible gap = leading + gap (TextKit adds lineSpacing under every line): paragraph ≈22, item ≈12,
  wrap 6, above a heading ≈34, under it ≈12.
- Bullets: fixed marker column (TurnType.markerColumn = 22) so text of "1." and "10." items lines up;
  marker right-aligned to the column (right tab stop) 8pt before the text; nested lists indent by one
  column so a child's marker sits under the parent's text. Unordered markers by depth: • ◦ ▪.
- Cam's density is COMPACT (defaults eco.frog / eco.frog.dev density=compact); SnapshotTests read it too.
  Compact used to squeeze prose (line 2, paragraph 8, list 3). New stance: density tightens the chrome, and the
  prose only a notch: compact line 5, list 5, paragraph 14, section 24, heading 5.
- Bullets in label color (a small glyph needs it), numbers secondary. Marker right-aligned by its measured width
  (firstLineHeadIndent), no leading tab, so copying a list still gives "• item".
- STOP: frog manager says testScrollUpFillsOlderRowsInOrder is flaky-bench (4371)'s job. Don't instrument
  TranscriptView or that test. Finding handed over: `jump` in the harness isn't observed (Binding over a plain property).
- Rule from manager: Swift source edits via the Edit tool only (no python string replace).
- Round 3 (Cam): align out-of-transcript elements (tool rows, subagent/task cards, restart banner, ...) to the column.

## Round 3: everything that isn't prose, aligned to the column
Survey (before):
- Lines inset 6pt from the column edge: ToolCallView, ReasoningView, OverflowRescueView (.padding(.horizontal, 6)
  so their hover/expanded plate has room). Text sits 6pt right of the paragraphs.
- Box radii all over: code 10, plan 10, opened activity 10, subagent 12, present 12, diagram 14,
  permission/question/elicitation 14 (pad 14), session message 12 (maxWidth 560).
- Composer: .padding(.horizontal, 20).frame(maxWidth: 860), so its inner width is 820 (the OLD column); the
  transcript is now 720, so the composer is wider than the text above it.
- ResumedBanner (graceful restart), BiggerModelLine, PingLine: full pane width in the bottom inset, padding 14,
  not tied to the column.
Stance:
1. One column for the whole page: transcript, the banners above the composer, the composer. Defined once by
   `View.turnColumn()` (TurnSpace.measure + gutter). The composer's box edges = the column's edges.
2. Two kinds of things in the column:
   - LINES (activity, tool rows, thoughts, notices, event lines, live status, footer, banners): content flush on
     the column's left edge. A hover/expanded plate BLEEDS outward into the gutter (pad then negative pad) and
     doesn't push the text in. (claude.ai's hover plates do the same.)
   - BOXES (code, diagram, subagent, plan, present, opened activity, permission/question/elicitation, MCP apps):
     edges on the column's edges, one radius (TurnSpace.Card.radius 12) and one inner padding (Card.padding 12),
     so content in any box starts at column + 12. Boxes nested in a row or card: Card.nestedRadius 8.
   - Exceptions: your prompt (right-aligned bubble, promptWidth) and the live typing bubble.
- Round 3 done in the tree: View.turnColumn() (composer + ResumedBanner), linePlate (tool rows and thoughts flush, plate
  bleeds), Card.radius/padding/nestedRadius on every box, one icon column (18 + 8) for tool rows, thoughts, event lines.
- Opened thoughts capped at 12 lines + "Show all" (CappedThought in ActivityLine.swift; the name ThoughtText is taken
  by Thinking/ThinkingStepView.swift). This also FIXED the blank fix-python-test-done render: a 78s thought opened
  whole made the view land past the end of the content.
- Snapshot isolation: SnapshotTests/MessageTextTests honor FROG_SNAPSHOT_DIR; run with
  TEST_RUNNER_FROG_SNAPSHOT_DIR=/private/tmp/snap-x. (TEST_RUNNER_TMPDIR doesn't reach app-hosted tests.)
- The earlier "bisect" (a8ba5c3 blank / 7169d8b fine) was contaminated by the shared folder. Disregard it.

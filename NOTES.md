# subagent visibility — notes

Branch frog/subagent-visibility, base a786571 (main). Commit per piece (`git commit -s`), never push.
Swift/Rust source edits via the Edit tool only. (Previous branch's notes — typography pass — live in git
history at a786571:NOTES.md.)

## Goal (Cam: "better subagent visibility")
1. session-level presence (activity line / sidebar row) for running subagents
2. timeline rail glyphs per subagent start, click-to-jump (chapter-marker machinery)
3. SubagentRunSheet parity with the main transcript
4. failure visibility: failed subagent findable in one click

## Constraints
- perf: streaming benchmark ≤30 materialized rows; rail glyphs no per-row hot-path cost
- app tests: xcodegen -q; xcodebuild test -derivedDataPath /private/tmp/subv-dd (unsandboxed)
- engine (only if touched): CARGO_TARGET_DIR=/private/tmp/subv-target
- delete both dirs at the end

## Survey (checkpoint 0 → 1)
- Foreground Task: `ItemState.subagent: SubagentRun` folded from live `Event::Subagent{item, inner}`.
  `Event::Subagent` is NOT durable (protocol.rs is_durable list): a replayed/reopened session has only the
  Task's report, no steps. The run sheet is empty after a relaunch.
- Foreground Tasks run one at a time (`auto::parallel_read` excludes Task). Concurrency only comes from
  `Task{background:true}` (background.rs start_task → `forward(reg, "task-N", true)`).
- BUG: background subagent events arrive as `Subagent{item: "task-N"}`; Conversation.upsert creates a
  phantom `.message` item with that id in the current turn (never `done`). TurnFlow hides it (empty text),
  but `ActivityLabel.live` / `TranscriptView.liveAnswer` read `turn.items.last` and can see it
  ("Writing the answer", follow parking treating it as a live answer).
- GAP: `Conversation.liveActivity` returns nil for a running Task → the chief tile says "Here: <folder>"
  while its subagent works.
- Finished Task folds into an activity line ("ran a subagent"); its card is only visible when the line is
  opened. Failure shows as "1 failed" (orange) in the line.
- Rail (TimelineRail) is per turn; jumps are turn-level (`WindowState.jumpTo: TurnState.ID?`), rows are
  `TranscriptRow.ID(turn, part: segment.id)`; no item-level jump exists.
- Sidebar: `Library.live[id]` (running/waiting/unread), `parents` for StartSession children (already nested,
  collapsed parents show "4 running · 1 waiting"). macOS rows have no activity detail line; iOS rows do.

## UX analysis (Cam: "get rid of subagents, just a child agent in the tree?")
References: Claude Code (5 parallel concepts: subagents, agent view, teams, workflows, projects — a warning
about concept sprawl; agent view's state groups "Needs input" above "Working", one-line summaries, Space to
peek), Slack/Linear threads (child conversation anchored at the message that started it, opens beside
the channel), GitHub Actions (failed job → log scrolled and expanded at the failing step), Temporal
Timeline (child spans on a time line, colored by outcome), Things 3 (progress pie per project), Flighty /
Live Activities (glanceable state, interrupts only when something changed for you), Quick Look (peek).

Stance: ONE noun, "agent". Every agent is a session with a log. Waiting is a parameter, not a type.
- Task (wait for it) and Task background / StartSession (don't wait) all create a child session.
  For the model, the tool stays the same (no change to what it's asked to do, no eval risk).
- Ephemeral vs standing is a visibility default, not a different thing: a waited-on child is folded
  under its parent and stays hidden when it finishes OK. A StartSession worker is a full row, as today.
  "Continue this agent" turns an ephemeral child into a standing one.
- Glance → peek → open:
  1. anchor: a thread line at the call ("↳ agent · audit sidebar · Reading main.rs · 42s"), not a card
  2. peek: hover (or Space) shows live status, last steps, report head
  3. open: the child's real transcript in the right-hand card as a thread pane (same TranscriptView, so
     parity comes free); ⌘-click opens it in its own pane
- Where things are: the rail gets a span per child (Temporal); the pill says "… · 2 agents"; the sidebar
  parent gets an aggregate (pie/chip). Children unfold only when they need you (waiting/failed).
- Failure propagates up the same path: anchor red → rail span red → parent row badge → pill
  "agent failed: <reason head>". One click from any of them opens the thread at the failing step.
- Engine shape: keep the subagent in-process (cheap, no extra engine), but give it its own session log
  (header: parent, anchor item, ephemeral). Live events stay `Subagent{item}`, and the log covers
  replay/open. `--sessions` skips ephemeral children unless asked, so listing cost doesn't grow.

## Decisions

## Progress
- 4274391 checkpoint 0

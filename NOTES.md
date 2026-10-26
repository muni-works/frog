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
- BUG (from the subagent-live snapshot): the header reads "29883095m 6s". `SubagentRun.startedAt` ends up
  near the epoch when a fixture/replay starts the run. Derive it from the Task item's startedAt instead.

## Mockup (docs/design/agents/mockup.html; renders are git-excluded)
Six surfaces, numbered on the mock: 1 anchor line (replaces SubagentCard in the flow; all 7 states in the
strip below), 2 peek (hover/space), 3 rail spans per agent colored by outcome, 4 pill "3 agents · 1 failed",
5 sidebar pie+count on the parent, agents fold under it and unfold only while running or failed, failed
puts the parent in Needs you, 6 thread pane = the agent's real transcript as a tab of the right card,
opened at the failing step, with Retry / Continue as session / Show in turn.

## Brainstorm round 2 — "a bit overwhelming, make it elegant" (Cam)
Diagnosis: the first mock said "3 agents · 1 failed" in 8 places. Rule now: each fact has ONE home;
everywhere else stays quiet.
Cam's answers (clicked):
- Glancing, he asks: needs me? / doing now? / how far along?  (NOT "what did it find": the parent quotes it)
- Home = the SIDEBAR. Agents are one-line rows under their session.
- Progress = the agent's own TodoWrite plan (done/total, a hairline + "3/5"), else steps+time, no bar.
- "Needs me" = only blocked on you (approval/question) bubbles up; failure stays red on the agent row.
- Click an agent = opens like any session (⌘-click splits). No peek, thread pane or run sheet.
- Finished agents fold into the existing "› N done · M failed" line when the parent's turn ENDS.
- Transcript: an agent is just a step ("ran 3 agents ›"; step rows "Agent: X · failed"; live status
  "Waiting on 1 agent · 2 done…"). SubagentCard goes away.
- Rail and pill: no new UI. The pill's live text says "Waiting on N agents".
Render: docs/design/agents/calm.html (section 1).

## Decision (morning, relayed by frog manager)
Cam picked (a) LIVE-ONLY: agent rows from the open conversation's live state + the agent-step log;
agents as real sessions is a scoped follow-on, stays design-only.

## Build order
1. engine: `Subagent{itemStarted|itemCompleted}` durable (serde shape unchanged) — done, test in protocol.rs
2. bug 1: background Task events must not create an open message item in the parent's turn
3. bug 2: liveActivity surfaces the subagent's activity
4. sidebar agent rows under their session (progress from the agent's plan, ✋ bubbles, fold on turn end)
5. transcript as steps ("ran N agents", "Agent: X · failed", "Waiting on 1 agent · 2 done…");
   SubagentCard only until the replacement renders
6. pill live text "Waiting on N agents"

## Session 2 (fresh start, Opus) — review of the rushed commits + the build
The previous session (glm flash) left 6 quick commits after bbe17b6 (e637fe0…0fd22bb) that NOTES didn't
record. Kept and built on, with fixes (no history rewritten):
- e637fe0 made the ENGINE drop every background agent's `Subagent` event (`item.starts_with("task-")`).
  That hid bg agents' steps from the app, which the sidebar rows need. Reverted in 2fd18bd; the fix
  lives in the app's fold path instead (that was the ask). The faac212 test was racy (asserted progress
  before the bg task ran) and asserted the drop; replaced.
- `TurnState.agents` counted the Task call that *starts* a bg agent as a finished agent; `.waiting`
  was never set; the sidebar showed only running rows (no failed/done, no fold); "Waiting on 2 agents"
  could never happen (foreground Tasks run one at a time); permission requests from bg agents also made
  a phantom item; the Task's needsPermission flag outlived the prompt (the real "Here: <folder>" cause
  after an approval). All fixed below.

Commits (this session):
- 2fd18bd engine: bg agents' steps reach the client under their job id (`task-N`); tests: bg steps
  arrive wrapped + durable; a reopened session replays a Task's steps (no deltas). Piece 1 done.
- 96953a2 app (bug a): any `subagent` event (or permission request) with no parent item folds into
  `Conversation.agentRuns[jobId]` (steps only: no deltas/status, so rows don't rebuild per token).
  Replayed runs start on the Task's clock (`SubagentRun(startedAt: item.startedAt)`; the 29883095m bug).
  `BackgroundJob` gains turn/startedAt/head. Model: `Conversation.agents` (last turn's Tasks + bg jobs;
  a bg job counts only while `backgroundRunning > 0`, so a log-stale "running" job has no row — that
  property is now observed), `AgentList` (rows/fold rules), `waitingOnAgents`, `agentStatus`.
- 742331a app (bug b): liveActivity checks Task before needsPermission; an answered prompt clears its
  Task item's flag. Tile: "Subagent: <activity>" / "Subagent: Starting".
- 62900c6 sidebar: `SessionAgents` (own view, so only it observes the streaming turns) under each open
  session row: rows while the turn runs (waiting ✋ › running › failed red › done ✓), plan "3/5" +
  hairline else "N steps · 42s"; on turn end finished agents fold into "› N done · M failed" (opens to
  them); fold kept through a bg agent's wake turn (latest agent turn ≥ last−1). Row click opens the
  session. "Needs you" bubbles through the parent's own live state (the request is the parent's).
- 203eaca transcript + pill: steps read "Agent: X · failed" / "· 3/5"; opened → report + "Show its N
  steps" (run sheet). Live line "Waiting on 1 agent · 2 done · 1 failed…". Pill "Waiting on N agents"
  (bg agents at work count). Snapshot `testRenderAgentsCalm` (agents-calm-{live,steps,sidebar,folded}).

Design-only / not built: agents as real child sessions (row click opens the parent instead), ⌘-click
split, rail spans, iOS rows. The run sheet stays as the way into a finished agent's steps until then.
Known limits: an app quit with bg agents running leaves them "running" in the log; they show no row
(hidden, not marked failed). Durable subagent steps grow the log by the agent's tool results.

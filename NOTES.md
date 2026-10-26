# switch-tab kill — notes

Branch frog/switch-tab-kill, base 77b5f8c (main). Commit per piece (`git commit -s`), never push.
Source edits via the Edit tool only. (Previous branch's notes — subagent visibility — live in git
history at 77b5f8c:NOTES.md.)

## Bug (Cam)
"starting a new thread manually, then switching away from the tab during the initial response, kills
the engine it seems." The new thread's turn reads "Interrupted" before anything streamed. Family of #107:
engine lifecycle tied to what's on screen instead of whether the session is working.

## Constraints
- app tests: xcodegen -q; xcodebuild test -derivedDataPath /private/tmp/stk-dd (unsandboxed)
- engine: CARGO_TARGET_DIR=/private/tmp/stk-target
- delete both dirs at the end

## Evidence (checkpoint 0)
~/Library/Logs/Frog/engine.log, 2026-10-26 (stop reasons across the whole log: 334 "pane switched folder",
272 background idle, 143 workspace closed, 8 "replaced on screen", 7 window closed):
- 13:31:34 start pid 95711 (new thread, /Users/cam/Developer/home, no -r)
- 13:31:43 call 1 thinking (its first model call; 21.7k tokens in)
- 13:31:46 stop pid 95711 session 20261026-093134-fee1: pane switched folder
- fee1.jsonl turn 1: turn_started, then `[Request interrupted by user]`, turn_ended cancelled, 0 tokens.
- same minute: 20261026-093127-7e81 (a chat, started 13:31:27) stopped at 13:31:34 "pane switched
  folder": no jsonl at all.
Path: Panes.setWorkspace → Workspace.stop → `SessionBroker.keep(c)` refuses (it keeps only "agent
sessions": started by one, or started one) → c.stop. Same gate on a same-folder switch (Workspace.show →
"replaced on screen"). A user's own thread is never kept, so switching away kills its turn.

## Progress
- f41d393 repro: SwitchAwayTests (real bundled engine, stand-in model via FROG_BASE_URL holding the first
  answer, scratch HOME via `Frog.overrides`). Red on base at 0.5/2/5 s + same-folder 2 s: engine DEAD at
  switch+1.5 s, turn_ended cancelled, nothing streamed — Cam's specimen exactly.
- ad05e31 fix: `SessionBroker.keep` keeps any session with work (not just agents'); an idle startup still
  goes; one kept before it named its session waits in `unnamed`, claimed at its first `observe`.
  Suspects 1 (watchdog/reconcile) and 2 (engine-start race) ruled out by the timeline: the engine was
  stopped by the app, by name, at the switch.
- Suites: app 325 tests, 4 failures, all TranscriptSwitchBenchmarkTests (wall-clock perf; no Workspace/
  broker in it). In isolation scroll-up passes, testSwitchTo5000RowSession ready ~0.5 s over budget.
- Engine cargo (untouched): 467 passed, 0 failed (unsandboxed; sandboxed runs fail the nested-sandbox tests).
- Window/pane close go through the same `keep`: a turn in flight now survives closing its window too.

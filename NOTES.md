# context-popover-usage — notes

Branch frog/context-popover-usage, base 669ada5 (main). Commit per piece (`git commit -s`), never
push. Targets: CARGO_TARGET_DIR=/private/tmp/cpu-target; delete at the end.

## Brief
Context popover reads "0% · 0 of 1000.0k tokens" on a glm-5.3-flash (vercel/zai) session with
600k+ in context; the footer cost is right. Expected real usage + percent.

## Findings (checkpoint 0)
- Token parsing is fine: engine.log `call 135 done … 612263 in, 254 out` for vercel/zai/glm-5.3-flash,
  and the session log's turn_ended carries context_tokens 612801.
- Root cause: a resumed engine starts with `usage: Usage::default()` (engine.rs Agent::new), so
  `context_tokens()` is None until the next model call. The app relaunched/reattached → the popover
  shows nil → "0 of 1000.0k". Session 20261022-122805-15f1 has 50 turns logged with
  context_tokens null, all 0-call cancels/errors right after a resume (turns 123–128 etc.).
  The footer cost comes from summing logged turn usage, so it survives resume.
- Same hole makes Compacted/ContextPruned after a resume report tokens_before 0.

## Plan
1. Seed `usage` on resume from the log: newest TurnEnded with context_tokens, or Compacted's
   tokens_after, whichever is later. Test: resumed engine's first Status has context_tokens > 0.
2. Hardening (brief): openai read_usage merges so a later `"usage": {}` chunk can't zero counts.

## Progress
- d022916 engine: resume seeds `usage.input` from the log's newest TurnEnded.context_tokens /
  Compacted.tokens_after. Test a_resumed_session_reports_its_context_before_the_next_call
  (fails without the fix: None vs Some(110)).
- f91adb9 openai: `take_usage` keeps the newest usage that has nonzero prompt/completion counts;
  `null`, `{}` and all-zero objects are skipped. Test empty_usage_chunks_never_zero_the_real_counts
  (612,263 in / 609,024 cached / 254 out, glm call 135's counts). Not the root cause: the log
  shows glm usage parsed fine; this is defense only.
- Popover untouched (nil → "0" display is downstream of the engine's None).

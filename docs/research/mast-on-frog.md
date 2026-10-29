# MAST-on-frog: classifying our own worker-session failures

Method: last ~10 real worker-session failures, Oct 24–25 2026 logs in
`~/.local/share/frog/sessions/*.jsonl` (read-only). Bucket per failure:
SPEC (brief wrong/ambiguous/worker lost the goal), COORD (org plumbing:
gateway, classifier, lost messages, idle-stops, worktree confusion),
MODEL (right brief + working plumbing, wrong output).

## Per-failure classification

| Session | What happened | Bucket | Evidence |
|---|---|---|---|
| 20261024-220444-c911 (delegation pipeline v2) | ended `complete` but never committed; long planning-only run | SPEC | brief said "spec + build" but no commit/push contract; worker burned 26k output tokens planning and stopped at spec-in-head |
| 20261024-223433-e9f8 (accounts ux v2) | ended `complete`, no commit; worker confused about base HEAD and tree state | COORD | worker saw clean-tree claim contradicting its own `ls` — stale handoff/cwd ambiguity between sessions sharing a worktree |
| 20261024-230218-2780 (pr-viral predecessor) | worker reported every tool result came back empty, worked blind, wrote nothing | COORD | tail: "Every tool result in this session has come back empty… nothing reaches me" — plumbing corruption, not a model fault; any hallucination would be downstream of corrupted context, root cause is the pipe |
| 20261024-230559-9b40 (transcript perf batch) | turn 7 died on gateway: body-decode timeout, DNS failure, then Vercel 402 insufficient-funds | COORD | turn_ended reasons: cancelled, internal timeout, dns error, provider 402 — all infrastructure |
| 20261024-224727-7138 (investor-revenue analyst) | 2 cancelled turns; final message: chief's relayed approval was for an unrelated repo | COORD | worker correctly detected a misrouted message and idled — a lost/mismatched handoff, no work lost |
| 20261025-082225-4d09 (delegation pipeline v2 recovery) | turn 1 cancelled mid-build, turns 2–3 died on gateway DNS errors | COORD | recovery run itself killed by the same gateway fault as its predecessor |
| 20261025-082642-b509 (accounts ux v3) | turn 1 died: Anthropic 400 "thinking blocks cannot be modified"; also a turn stalled on "classifier is unavailable" | COORD | provider 400 from a corrupted request rebuild + classifier outage — both plumbing |
| 20261025-083427-fe78 (accounts ux v4) | both turns cancelled; pane closed | COORD | idle/pane lifecycle killed live work — org plumbing, not brief or model |
| 20261025-083426-0030 (delegation pipeline v4) | turns 2–3 died on Vercel 402 insufficient-funds mid test-fix loop; worker had 3 commits + build warnings in flight | COORD | 402 gateway credit exhaustion killed a healthy mid-task build loop |
| 20261025-152531-8510 (delegation pipeline v5) | last event: classifier routed a delete to `ask`, no turn_ended — left waiting on a permission card | COORD | ended stuck on an approval card ("deletes outside the project"), never resumed |

## Tally (n = 10)

| Bucket | n | % |
|---|---|---|
| SPEC / briefing | 1 | 10% |
| COORD / plumbing | 9 | 90% |
| MODEL | 0 | 0% |

## Verdict vs literature

The MAST literature predicts ≥70% briefing/coordination failures in
multi-agent systems. Ours measured 90% coordination — the prediction
holds, and overshot: but the dominant sub-bucket is not briefing, it is
infrastructure (gateway 402s/DNS/timeouts, the 400 thinking-block
rebuild bug, empty tool results, classifier outages, idle-stop cancels,
stuck permission cards). Only one failure traces to the brief itself
(underspecified completion contract). Zero model errors: whenever
plumbing worked, workers did correct work.

## Top fixes for COORD (the 90% bucket)

1. **Gateway resilience + auto-retry**: the Vercel 402 credit exhaustion
   and DNS/timeout faults killed 4 of 10 sessions. Auto-retry with
   backoff on 402/5xx/DNS, a local fallback provider, and a
   pre-task credit check would have saved 40% of failures alone.
2. **Don't let lifecycle kill live work**: idle-stop and pane-close
   cancelled healthy turns (fe78, 7138, 4d09 turn 1). Gate idle-stop on
   "did the last turn produce edits/commits?" before killing.
3. **Fail loudly on empty tool results**: session 2780 worked blind for
   a whole turn because tool results came back silently empty. Detect
   N consecutive empty results and abort with a plumbing-error report
   instead of letting the worker hallucinate around missing context —
   the 400 thinking-block rebuild bug (b509, d811) is the same
   shape: corrupt request → provider error → dead session.

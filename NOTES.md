# mid-turn-events — notes

Branch frog/mid-turn-events, base 669ada5 (main). Spec-only: docs/design/mid-turn-events.md, no
engine/app changes. Commit `-s`, never push.

## Brief
Cam: "rather than queueing events, can we just shove them into an ongoing turn?" Today wakes,
session messages and worker reports wait for the turn boundary and go as one batch. Answer: the
mechanism options, what stays at the boundary, cost/risk (cache, transcript, tokens), and the
smallest shippable version vs parallel-execution.md §4. Extend §4, don't duplicate it.

## Progress
- checkpoint 0.

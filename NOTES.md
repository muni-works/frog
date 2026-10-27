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
- docs/design/mid-turn-events.md written (+ one-line pointer from parallel-execution.md §4).
  Finding: append-only injection doesn't break the cache prefix (anthropic.rs breakpoints);
  the cost is reaction steps per delivery point (~50k-eq each on 500k) and reasoning-stripping
  models re-rendering the turn on mid-loop user text. Recommendation: Queue pull (v1) + urgent
  push at the post-batch safe point (v2), normal stays batched.

# stream-reset-retry — notes

Branch frog/stream-reset-retry (worktree stream-reset-retry), base = origin/main. One commit per
step (`git commit -s`), push over https to frog/stream-reset-retry, PR to main. Edit tool only for
source.

## The bug
`crates/frog-engine/src/engine/mod.rs:1189 fn retryable()` — its reqwest predicate is
`r.is_timeout() || (r.is_request() && !r.is_connect())`. A connection reset MID-BODY is a reqwest
error with `is_body() == true` (response headers arrived; the body stream broke), so the predicate
misses it → classified fatal → the turn dies with no retry. This killed two long-context workers
today (105k ctx, 143k input): the entire prefill is discarded and the task restarts from zero.

## Why the retry is safe for a body error
The partial the broken attempt already streamed is discarded before the retry
(`Event::ItemsDiscarded` in call.rs covers message+reasoning items on EVERY error arm, including
the retry arm), and the step re-runs from scratch. Same class as the already-retried
`IncompleteStream`/gateway-error-mid-stream cases. Nothing is duplicated; idempotent for the step.

## Budget (chief's correction, verified by reading main)
Current policy after #235: `MAX_RETRIES = 3` (4 attempts) with `retry_wait` 1/2/4 s
(`model_policy.rs:17,80`), enforced once in `call.rs` (`attempt < model_policy::MAX_RETRIES`). The
brief's "cloud gets 6 attempts / 1-2-4-8-16-20s" was the pre-#235 budget, gone. NO budget change —
just make the reset retryable within the existing policy. Verified: `retry_wait` caps at 4 s
(`1 << min(attempt-1, 2)`); one notice per call (`attempt == 1`), fail-fast (401/402/404) never
reaches the retry arm; cloud→local fallback is separate and unchanged.

## Live evidence (this worker)
This session's own turn died on a connection reset mid-work — the exact bug being fixed killed the
fixing session's turn. Best possible evidence the fix matters; recorded here per chief.

## Plan
1. This checkpoint, commit.
2. `retryable()`: add `r.is_body()` to the final predicate, keep everything else. Commit.
3. Tests, extending the existing scripted harness (no scripted.rs changes; another worker owns a
   `hold` gate on a different branch):
   - `Fail::Stream` with a partial then success → one clean reply, ItemsDiscarded for the partial,
     no error turn-end (this is the StreamError path, already covered by
     tests.rs:932/1086; assert the new behavior explicitly against a reset-shaped message).
   - The real gap: a `reqwest::Error` with `is_body() == true` must pass `retryable()` — unit test
     on `retryable` itself, plus a budget-exhaustion test → existing failure path
     (`EngineError::Provider { status: 502 }` via StreamError classify), not a new one.
   - `Fail::before("connection reset by peer")` already exercised at tests.rs:4029.
4. docs/design/stream-resume.md: one paragraph (design note, not built) — resume a lost stream
   from the last complete item instead of restarting a 143k-token step. Commit.
5. Verify: `cargo build -p frog -p frog-engine && cargo test -p frog-engine` (full crate),
   CARGO_TARGET_DIR=<worktree>/.tt-target. Engine's sandbox-exec tests fail inside frog's sandbox
   → run unsandboxed if so and say so.
6. Push https + PR to main.

## Result
- (pending)

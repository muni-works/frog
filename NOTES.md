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
- Commits: 201b6b20 (notes checkpoint), 846e2f0c (the fix), 2e35cb3e (tests), f9d314a2 (design note). Pushed; PR open.
- The fix (846e2f0c), with one empirical correction to the brief: reqwest 0.13.5 surfaces a real
  mid-body reset as **`is_decode()`** (`Kind::Decode` wrapping hyper's body error, e.g. "Connection
  reset by peer (os error 54)"), NOT `is_body()` — `bytes_stream()` wraps every frame error with
  `error::decode`, and `Kind::Body` appears only when a client timeout/read-timeout is configured
  (our provider client sets none). Verified with a scratch probe against live sockets before
  writing the final predicate, then deleted. Final predicate adds BOTH `r.is_body()` and
  `r.is_decode()`. `classify()` now maps the same classes to `EngineError::Connection` (was
  `Internal` for a body error) so the turn ends with the provider's message, not "internal error".
- Tests (2e35cb3e), extending the existing harness only, no scripted.rs changes:
  1. `a_connection_reset_mid_body_is_retried` — scripted partial + reset message → ItemsDiscarded
     for the partial, clean reply, TurnEnded Complete.
  2. `a_connection_reset_exhausting_the_budget_ends_with_the_existing_failure_path` — 4 failures →
     4 discards, ONE retry notice, existing Provider 502 error path (no new one).
  3. `a_real_reset_mid_body_is_retried_to_a_clean_reply` — a REAL localhost OpenAI-wire server that
     answers 200, streams a fragment, kills the socket mid-body: the engine retries (2 chat hits),
     the second attempt's reply completes the turn (model_calls 1). Proves the wire shape end to
     end. Server routes by path so startup probes don't trip the reset script; test clients use
     `.no_proxy()` (the host's proxy env would intercept localhost).
  4. `a_broken_body_stream_is_retryable_and_a_connect_failure_is_not` — the live reqwest error
     captured from the same server: `is_decode()` && !is_body && !is_connect && !is_timeout →
     retryable true; a real connect-refused error → retryable false, classifies Connection.
- Retry budget verified by reading (chief's correction confirmed): MAX_RETRIES=3 (4 attempts),
  retry_wait 1/2/4 s capped, enforced once in call.rs, one notice per call; the "6 attempts"
  figure was pre-#235. Unchanged.
- Verification: `cargo build -p frog -p frog-engine` OK (in-worktree .tt-target, sandboxed).
  Full `cargo test -p frog-engine`: INSIDE frog's sandbox it stalls forever at
  `pane_lifecycle_is_logged_but_screens_are_not` (pty spawn denied — the same pre-documented
  environmental hang as commit 348614f7; everything before it passed incl. all 4 new tests).
  UNSANDBOXED: **574 tests, 566 passed, 0 failed, 8 ignored** in 89 s. The suite is judged
  unsandboxed/CI, as the repo notes say.
- Live evidence held from the checkpoint: this session's own earlier turn died on a connection
  reset mid-work — the bug killed the session sent to fix it.

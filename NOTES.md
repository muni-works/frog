# model-policy — notes

Branch frog/model-policy, base d13ac864 (main, carries #230). One commit per piece (`git commit -s`),
never push to main; push the branch and open a PR at the end. Edit tool only for Rust/Markdown.
Target dir /private/tmp/mp-target (delete when the suite passes, ~11G).

## Pieces
0. This checkpoint.
1. docs/design/model-policy.md — the two-tier spec, committed alone.
2. auto.rs + engine/permit.rs — classifier chain = [apple/on-device, cloud/bull]; the
   session-model leg and cross-tier hops gone; workers never degrade to rules-only on BYOK.
3. engine/call.rs (+ provider/mod.rs hints) — one retry policy: 429/5xx backoff 1/2/4, max 3,
   ONE notice; 401/402/404 fail fast with the provider's fix as a notice + honest turn_ended.
4. model_policy.rs + engine/mod.rs + engine/permit.rs — spawn-time validation against the
   gateway's /v1/models (60s cache); cloud/* and this Mac always valid.
5. README — the two tiers in one paragraph.
6. Tests (engine): 402 fail-fast, 429 timing, classifier never BYOK, spawn accept/reject,
   plus the existing auto.rs chain tests rewritten to the new policy.
7. FrogKit: served-tint left borders removed (ServedTint modifier + call site + any other
   Color.served left edge); the markdown blockquote bar stays.
8. SessionBroker.escalate: a child's pending card reaches its parent as STATUS (inform, one
   line) instead of a delivered turn; the card lives in needs-you / ListApprovals / SessionStatus.
   Test: the parent's transcript gains no turn, its pending count still updates.

## Result
Engine: 560 passed, 0 failed, 8 ignored (`cargo test -p frog-engine`, unsandboxed — the sandbox
blocks the shell tests and swiftpm's manifest). SessionBrokerTests: 52 passed. App builds.
App tests must run with `PRODUCT_BUNDLE_IDENTIFIER=toys.frog.testhost`, or the installed
toys.frog.dev app makes the test host hand over and exit ("Early unexpected exit").

## Diffed against #231 (8981fbd1 = main d13ac864 for auto.rs, empty diff)
Nothing duplicated: this branch is only the delta — the session-model leg's removal, the retry
policy, spawn validation, the README paragraph, the tint removal, the escalation change.

## Where things are
- crates/frog-engine/src/auto.rs: Classifier::new (chain), Classifier::fallback (second pass).
- crates/frog-engine/src/engine/permit.rs: auto_judge, classifier_verdict, second_pass,
  session_tool (StartSession reaches the client here).
- crates/frog-engine/src/engine/call.rs: the retry loop (retry_budget, cloud_fallback,
  QUIET_RETRIES, the notice).
- crates/frog-engine/src/engine/mod.rs: retryable(), classify(), spawn() (policy::check).
- crates/frog-engine/src/catalog.rs: cloud_models_fresh (10 min TTL) — the gateway list shape.
- crates/frog-engine/src/providers.rs: PRESETS (key_url for the fix lines), canonical(), CLOUD.

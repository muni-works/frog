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

## Where things are
- crates/frog-engine/src/auto.rs: Classifier::new (chain), Classifier::fallback (second pass).
- crates/frog-engine/src/engine/permit.rs: auto_judge, classifier_verdict, second_pass,
  session_tool (StartSession reaches the client here).
- crates/frog-engine/src/engine/call.rs: the retry loop (retry_budget, cloud_fallback,
  QUIET_RETRIES, the notice).
- crates/frog-engine/src/engine/mod.rs: retryable(), classify(), spawn() (policy::check).
- crates/frog-engine/src/catalog.rs: cloud_models_fresh (10 min TTL) — the gateway list shape.
- crates/frog-engine/src/providers.rs: PRESETS (key_url for the fix lines), canonical(), CLOUD.

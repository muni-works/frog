# Model policy: two tiers

Status: design, direction from Cam 2026-10-31 · 2026-10-31

frog runs on two kinds of model, and the difference decides who may use which, what happens when
one fails, and whether anything falls back to something else. The rule is one line: **the platform
owns the worker's model; the user owns the interactive session's.** Everything below follows from
it.

## The two tiers

| Tier | Who | Models | Who runs it |
|---|---|---|---|
| **1 — frog cloud** | the platform: workers, classifiers, the Mac | `cloud/tree`, `cloud/bull`, `cloud/qwen3-coder-next` (dart, when the gateway serves it) | frog |
| **2 — BYOK** | the user's own interactive sessions | `vercel/…`, `anthropic/…`, `openai/…`, `openrouter/…`, `cloudflare/…`, `ollama/…`, `lmstudio/…`, servers you added | the user's own account or machine |

On-device models (`apple/on-device`, `local/…`) sit outside both tiers: no key, nothing leaves the
machine. They are the classifier's first judge and the Mac's offline path, and never a worker's
model (a worker that needs a model gets tier 1).

**Tier 1 is the default for work nobody is watching.** A worker session, a subagent and a
classifier start on frog cloud. Tier 2 is a choice a person makes in a session they are sitting in
front of.

**A fresh install starts on this machine, never on a billed model.** The CLI's default is
`local/qwen3-4b` on frog's own engine (`LOCAL_DEFAULT` in `config.rs`); the Mac app starts on Apple
Intelligence where the Mac has it, else the same. The first-run banner and `frog account` say which
model is in use and whether it's free or billed. Frog Cloud is one `frog login` away.

## No cross-tier fallback chains

A model call has exactly one model. There is no chain that hops from the user's provider to
frog's, or from frog's to the user's:

- **A worker on BYOK fails fast.** One line names the provider and the fix, the turn ends with the
  honest provider error, and nothing else is tried.
- **An interactive BYOK session may degrade, because a human is there.** When its model can't
  answer at all, the session may continue on frog's built-in rules (auto mode) or on a local
  model, with a notice saying so. A worker may not: it fails, and the session that started it
  decides what to do.
- **frog cloud may fall back to a local model** when it is unreachable or out of capacity (502,
  503) — that is tier 1 to the Mac, not a hop into someone's BYOK account, and it is already
  documented (`FROG_FALLBACK_MODEL`). It never falls back on a credit error (402): the fix is
  money, not a different model.

## Fail-fast semantics, by error class

| Class | What it means | What frog does |
|---|---|---|
| **401** | the key is wrong, missing, or revoked | fail the call at once; notice: "<provider> rejected the key: set <ENV> or connect <provider> in Settings (<key page>)" |
| **402** | the account is out of credits | fail at once; notice: "<provider> credits are out: add credits at <key page>" |
| **404** | the gateway doesn't serve that model | fail at once; notice: "model not listed: pick one from the gateway's /v1/models" |
| **429** | rate limited or busy | retry with backoff (below); one notice in total |
| **5xx / 502 / 503 / 504 / 529** | the upstream is busy or broke | same as 429 |
| **connection, TLS, timeout, mid-stream break** | transient | same as 429 |

Fail-fast means the *first* answer decides: no retry, no fallback model, no second provider. The
provider's own message stays in the `turn_ended` error (`EngineError::Provider { status, message }`)
so a client can show the truth; the notice is the one-line fix, not a summary of the body.

## One retry policy

Every retried model call — main loop, classifier, subagent — uses the same numbers:

- **429 and 5xx: back off 1 s, 2 s, 4 s. Three retries (four attempts) at most.** No jitter, no
  doubling past 4 s, no per-model budget.
- **One notice per call, not one per attempt.** A retry storm is a single line in the transcript
  ("bull is busy right now — retrying (up to 3)"), not a card or a line per try.
- A broken attempt that already streamed a partial reply discards its items and re-runs the step,
  as before.
- **401/402/404 never retry.** Retrying a wrong key or an empty wallet only spends time.

The old budgets (6 for frog cloud, 3 otherwise, a notice on every attempt past the second) are
gone: they produced the 429 storms below.

## Spawn-time validation

A session or worker only starts on a model its gateway currently lists:

- **`cloud/*` is always valid.** The platform serves it; its own `/v1/models` decides which, and
  the web app and Mac picker already read that list.
- **A BYOK model is checked against its gateway's `GET /v1/models` at spawn**, from a list cached
  for **60 seconds**. A model the gateway doesn't list is refused with the fix ("model not listed:
  pick one from the gateway's /v1/models"), not started and left to die on its first call.
- **The check runs at spawn, not per call.** One request per provider per minute, and a running
  session is never re-validated mid-turn — a model that disappears later fails as a 404 with the
  same fix.
- An unreachable gateway is not a rejection: with no list to check against, the spawn is allowed
  and the first call reports the real problem (401/402 with its fix, or a connection error).

## The classifier

Auto mode's judge is a platform service, not the user's:

- **The chain is `apple/on-device`, then `cloud/bull`.** That's it: local and free first, frog
  cloud's small model second. Both are tier 1 or on-device.
- **The session's own model is never the classifier.** Not when the session is BYOK (its key
  failing would take auto mode down with it), and not when it is `cloud/*` either — one fixed
  judge behaves the same in every session. The `auto_classifier_fallback` config key still names
  an explicit second judge for someone who wants one.
- **Never cross-tier.** A BYOK session's classifier does not use that provider; a worker's
  classifier is the same chain as everyone else's.
- **No classifier at all is not a failure of the session.** The built-in rules decide (a down
  classifier never cards a call by itself). For a **worker**, though, there is no human to
  degrade to: if the chain is down and the worker's own model is BYOK, the call fails with the
  provider's fix instead of quietly running on rules.

## The incidents this fixes (week of Oct 26, 2026)

- **79 × 401/402 when vercel credits ran out.** Workers died mid-run, one card-shaped notice per
  attempt, and the turn's error said only "HTTP 402". Now: the first 402 fails the call with
  "vercel credits are out: add credits at vercel.com/d…", and no retry spends the rest of the
  budget on a wallet that is empty.
- **Classifier 401 fallback loops.** A BYOK session's classifier fell back to the session's own
  model, which was the one returning 401, so every call re-asked a dead key. Now the classifier is
  `apple/on-device` → `cloud/bull` and never the session's model.
- **429 retry storms on bull, four in a row.** The cloud budget was six attempts with a notice on
  each one past the second. Now three attempts, waits of 1/2/4 s, and one notice.

## What this changes in the code

- `crates/frog-engine/src/auto.rs`: `Classifier::new` builds `[apple/on-device, cloud/bull]`;
  `Classifier::fallback` no longer takes the session's model.
- `crates/frog-engine/src/engine/call.rs`: one retry table, one notice, fail-fast notices for
  401/402/404; frog cloud no longer falls back to local on 402.
- `crates/frog-engine/src/model_policy.rs`: tiers, provider fix lines, spawn validation.
- `crates/frog-engine/src/engine/permit.rs`: auto mode never degrades a worker on BYOK to rules
  only, and `StartSession` validates its model before the client starts anything.

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

A model call stays in its tier. There is no chain that hops from the user's provider to
frog's, or from frog's to the user's:

- **A worker on BYOK fails fast.** One line names the provider and the fix, the turn ends with the
  honest provider error, and nothing else is tried.
- **An interactive BYOK session may degrade, because a human is there.** When its model can't
  answer at all, the session may continue on frog's built-in rules (auto mode) or on a local
  model, with a notice saying so. A worker may not: it fails, and the session that started it
  decides what to do.
- **A busy Frog Cloud model may hand a call to another Frog Cloud model** (same tier, same
  account, added 2026-11-14). Only after the session's model used its whole retry budget on a
  429/5xx, only to a model the platform lists that takes tools and whose window holds the
  thread, and only when `cloud_fallback` is on (the default) and the folder allows cloud
  models. One line says so ("Frog Cloud: deepseek-v4.1-flash is still busy, so glm-5.3-flash
  is answering for now. The session's model hasn't changed."); calls go to the stand-in for
  two minutes, then the session's model is tried again. The stand-in gets one retry; if it
  fails too the turn ends on the session model's own error. A dropped connection never falls
  back (no other model fixes the network), and BYOK never does.
- **frog cloud never falls back to a local model.** When it is unreachable or out of capacity
  (502, 503) and no other Frog Cloud model can take the call, the turn stops with the error
  and the thread is left untouched. Switching a
  cloud-sized history onto a small local window forced pruning and a compaction that couldn't
  fit, which wrecked every open thread during a short outage (removed 2026-11-12).

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

A turn that ends on passing trouble (429, 5xx, a mid-stream gateway error) is different: its
`message` is frog's own plain line — what happened, that the work so far is kept, what to do —
and the provider's body stays in the engine log. Frog Cloud's `502 "<model> answered 402,
retry"` is its upstream's bill: it reads "Frog Cloud had a problem upstream … It isn't your
account or your billing", never as the user's credit.

## One retry policy

Every retried model call — main loop, classifier, subagent — uses the same numbers:

- **429 and 5xx: back off 1, 2, 4, 8, 16 s, each spread ±25 %. Five retries (six attempts) at
  most.** A `retry-after` is the floor when it is longer, capped at 60 s. No per-model budget.
  (Three retries over 7 s ended 32 of 320 turns on 2026-11-13 while Frog Cloud was briefly
  busy; the notice count, not the retry count, was what made the old storms loud.)
- **One notice per call, not one per attempt.** A retry storm is a single line in the transcript
  ("Frog Cloud is busy — retrying"), not a card or a line per try. The working line reads
  "busy, retrying…" and `Status.waiting` carries the attempt while it waits.
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

# Frog Cloud as the model gateway

Status: draft · 2026-10-29 · decisions marked **Open** are Cam's

## Goal

The apps don't have providers. In the Mac, iPhone and web apps, a user picks a model from two
places: **This Mac** (local) and **Frog Cloud**. Everything remote goes through the Frog Cloud
gateway (zest `edge/`), which decides where each request actually runs: tang's own GPUs,
Cloudflare AI Gateway, Vercel AI Gateway, or a provider's API directly. Upstreams are an
implementation detail of the gateway, never something the app shows or holds keys for.

This gets frog off Vercel without the app noticing, and lets us swap or add upstreams per model
without shipping an app.

Non-goals: removing providers from the open-source engine (see Open decision 1), in-app billing
(zest owns checkout), team accounts.

## Today

- The engine has a preset list of providers (`crates/frog-engine/src/providers.rs`): This Mac,
  frog cloud, OpenRouter, Vercel, Cloudflare, Anthropic, OpenAI, Ollama, LM Studio, plus custom
  servers. The Mac app exposes them in Settings and the model picker (`ProviderStore`,
  `ModelPicker`), with keys in the Keychain.
- frog cloud (`api.frog.toys/v1`) is OpenAI chat completions only, routed by the edge to tang's
  router.
- Claude runs as `vercel/anthropic/claude-opus-5.5` on the user's own Vercel key, with
  special cases keyed on the URL: `gateway_claude` (Messages API on Vercel), `is_cloud`,
  `native_known`, Vercel's error wording in `provider/mod.rs`, and Vercel's usage-in-delta in
  `provider/anthropic.rs`.
- Model metadata for remote models comes from each gateway's list or models.dev
  (`catalog.rs`); prices in `TurnCosts` link to whichever gateway listed them.

## Design

### 1. Wire format: native passthrough

The gateway serves both shapes and passes each through without translation:

- `POST /v1/chat/completions`: OpenAI-shaped models (tang, GLM, DeepSeek, GPT).
- `POST /v1/messages`: Anthropic-shaped models (Claude). Keeps `cache_control`, thinking,
  effort and real cache usage, all lost in chat-completions translation.

The engine picks its client from the model's `api` field in `/v1/models` (section 2), not from
the URL. Both clients already exist (`provider/openai.rs`, `provider/anthropic.rs`); the change
is choosing between them by metadata. Auth is the same `frog_` bearer on both.

No translation layer in the gateway: translating is where caching and reasoning controls get
lost, and it would be ours to maintain.

### 2. The catalog comes from the gateway

`GET /v1/models` returns, per model:

| field | example |
|---|---|
| `id` | `claude-opus-5.5` (spec `frog/claude-opus-5.5`) |
| `name` | `Claude Opus 5.5` |
| `api` | `anthropic` \| `openai` |
| `context`, `max_output` | `200000`, `32000` |
| `inputs` | `["text", "image"]` |
| `tools` | `true` |
| `reasoning` | `{levels: ["low","high","max"], default: "high", can_disable: false}` |
| `prices` | frog's per-M rates: in, out, cache read, cache write |
| `plans` | which plans may use it |

Model ids are flat (`frog/claude-opus-5.5`, not `frog/anthropic/claude-opus-5.5`): the
upstream is hidden, so the name shouldn't encode it.

For Frog Cloud models this replaces models.dev lookups, the built-in cloud list and
gateway-specific catalog parsing. `TurnCosts` shows frog's prices and links to frog's own model
page. Cached like today (`catalog.rs` TTL); the built-in list stays as the logged-out preview.

### 3. Routing in the gateway

The edge holds a model table: each frog model maps to an ordered list of upstreams, each with
its base URL, the upstream's model id, API shape and credential.

```
claude-opus-5.5:
  - cloudflare-aig  anthropic/claude-opus-5.5   /ai/v1/messages
  - vercel          anthropic/claude-opus-5.5   /v1/messages
  - anthropic       claude-opus-5.5             /v1/messages
qwen3-coder-next:
  - tang            (router fleet, as today)
```

Rules:

- **Sticky per session.** Prompt caches live with one upstream, so moving a session busts its
  cache: on Opus with 100k of context, the next turn costs ~10x. The engine sends
  `x-frog-session: <id>`; the edge pins that session to the upstream that served it and moves
  only on failure (5xx, connect error, upstream 429 after retry).
- **Same model, different host only.** An upstream entry is the same weights and defaults. GLM
  on Workers AI and GLM on z.ai can differ in quantization and reasoning defaults, so they're
  separate frog models, or one is chosen deliberately, never silently substituted.
- **Health.** Upstreams that fail repeatedly are skipped for a cooldown, like the router fleet's
  misses today (`fleet.ts`).
- **Transparency.** Every response carries `x-frog-upstream: cloudflare-aig`. The engine logs it
  in the session and the transcript can show it on hover; it's for debugging, not a choice.
- **Streaming** passes through unbuffered. The edge is a Worker, so Cloudflare AI Gateway is
  in-network and the extra hop is small; measure time to first token against Vercel before
  switching defaults.

### 4. Usage and billing

- Every request goes through the account's credit DO and the D1 ledger, as tang traffic does now.
- The gateway turns each upstream's usage report into one shape (input, cache read, cache
  write, output, reasoning) before pricing it. Upstream quirks (Vercel's counts only in the final
  delta, CF's cached-input field) are handled once, in the edge, instead of in the engine.
- Credit is checked before a request is sent and settled after; a stream that runs past the
  balance finishes, then the account goes negative and the next request gets 402.
- All users share frog's upstream accounts, so upstream rate limits are pooled. Several
  upstreams per model helps; per-plan concurrency (`tiers.ts`) protects the pool.
- Cloudflare unified billing puts most third-party spend on one bill; Vercel stays as fallback.

### 5. Errors

One error shape from the gateway, whatever the upstream:

| status | `error.type` | engine behavior |
|---|---|---|
| 402 | `out_of_credit` | stop, show top-up link |
| 403 | `plan_required` | stop, show which plan unlocks the model |
| 429 | `rate_limited` | retry with `retry-after` |
| 413 / 400 | `context_too_long` | compact and retry (today's path) |
| 502 / 503 | `upstream_unavailable` | retry; gateway already tried failover |

The engine matches frog's errors only. Vercel's wording in `provider/mod.rs` and the tests that
pin it go away once cloud traffic is off Vercel keys.

### 6. Engine changes (frog repo)

- `frog/` models choose the Anthropic or OpenAI client from catalog `api`.
- Send `x-frog-session`; record `x-frog-upstream` in the session log.
- `is_cloud`, `native_known` and energy estimates read model metadata instead of URLs:
  everything on Frog Cloud is cloud; Claude is native-known by catalog, not by name match.
- The gateway can report energy (measured on tang, estimated elsewhere) in usage; `energy.rs`
  uses it when present.
- Old specs keep resolving (section 9).

### 7. App changes

- Model picker: **This Mac** and **Frog Cloud**, nothing else (subject to Open decision 1).
- Settings loses the providers list and key entry; Frog Cloud is sign-in only (account design,
  2026-10-21).
- Logged out: local models, plus Frog Cloud's built-in list shown as "sign in to use".
- Price and model info come from the Frog Cloud catalog.
- Remove: `ProviderStore`, per-provider rows in `ModelPicker`/`SettingsView`, the gateway cases in
  `TurnCosts`. The iPhone `ModelSheet` and `SettingsSheet` follow.

### 8. Cloud sandbox

Sandbox sessions (2026-10-28 plan) already reach models through the edge, so they never hold
upstream keys. With this, web, Mac, iPhone and sandbox all share one model path and one ledger.

### 9. Migration

- Specs in saved sessions and config (`vercel/anthropic/claude-opus-5.5`, `cloudflare/...`)
  keep resolving as they do today when the user has that key.
- When signed in and the old provider isn't connected, alias known specs to their Frog Cloud
  equivalent (`vercel/anthropic/claude-opus-5.5` → `frog/claude-opus-5.5`) and say so once in the
  transcript.
- Tests that use `vercel/...` specs as fixtures move to `frog/...` as the special cases go.

### 10. Privacy

User code now passes through frog's infrastructure and then an upstream.

- Turn off Cloudflare AI Gateway payload logging (`cf-aig-collect-log-payload: false`) and
  equivalent settings elsewhere; the ledger keeps counts, never content.
- Use zero-data-retention terms with upstreams that offer them.
- The privacy policy lists the upstreams and what each keeps.

## Phases

1. **Gateway (zest).** `/v1/messages` passthrough, model table with upstream lists
   (Cloudflare AI Gateway first, Vercel fallback), usage normalization, pricing, error shape.
2. **Catalog.** `/v1/models` metadata; engine picks its client by `api`; `x-frog-session` and
   `x-frog-upstream`.
3. **Apps.** Picker down to This Mac + Frog Cloud, providers UI removed, spec aliases.
4. **Routing.** Sticky sessions, upstream health and failover, TTFT comparison across
   upstreams.

## Open decisions

1. **Bring your own key and custom servers.** Keep providers (OpenRouter, Ollama, LM Studio,
   custom servers) in the open-source engine and CLI, and hide them in the apps or put them under
   an Advanced section? Or drop them from the apps entirely? Dropping them from the engine would
   break "free, open source, works logged out". **Open.** Recommendation: keep in engine and
   CLI, hide in the apps behind Advanced.
2. **Codex (ChatGPT sign-in).** It's the user's own subscription, so it can't go through the
   gateway. Keep it as CLI-only, keep it in the apps as a "your accounts" exception, or drop it?
   **Open.**
3. **Launch models.** Which frog models ship first beyond tang's (Claude Opus 5.5? Sonnet? GLM
   5.3? DeepSeek V4.1 Flash?). **Open.**
4. **Margin.** Pass-through, a flat percentage, or per model? **Open.**
5. **Plan gating.** The $5 sign-up credit lasts about one long Opus session. Gate frontier models
   by plan, cap per-session spend, or let credit run out? **Open.**
6. **Showing the upstream.** `x-frog-upstream` in the transcript on hover, or logs only?
   **Open.**
7. **Model naming.** Flat ids (`frog/claude-opus-5.5`) as proposed, or keep the vendor
   (`frog/anthropic/claude-opus-5.5`)? **Open.** Recommendation: flat.
8. **Engine Cloudflare provider.** `1ad4a4c7` made the engine's `cloudflare` preset an AI
   Gateway client (Claude over `/ai/v1/messages`) for your own key. Keep it as a CLI provider, or
   revert now that the real integration lives in zest? **Open.**

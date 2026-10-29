# Frog Cloud as the model gateway

Status: draft v2 · 2026-10-29 · decisions recorded below; **Open** ones still need Cam

## Goal

By default, a user picks a model from two places: **This Mac** (local) and **Frog Cloud**.
Frog Cloud models go through the Frog Cloud gateway (zest `edge/`), which decides where each
request actually runs: tang's own GPUs, Cloudflare AI Gateway, Vercel AI Gateway, or a
provider's API directly. Upstreams are the gateway's business: the app never holds keys for
them.

Users stay free to bring their own providers, the way opencode lets you: a short list of
presets plus any OpenAI-compatible server, kept simple and never pushed aside. Frog Cloud is
the default, not the only way.

This gets frog off Vercel without the app noticing, and lets us swap or add upstreams per model
without shipping an app.

Non-goals: removing your-own-provider support, in-app billing (zest owns checkout), team
accounts.

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

- **Our GPUs first, third parties for overflow** (Cam, 2026-10-29). Every model's first
  upstream is tang. Third-party upstreams add launch capacity and absorb peaks; they're never
  the plan. A new session goes to tang when a router has room (the edge's existing "full" answer,
  `relay.ts`), and spills to the next upstream only when every router is full or gone.
- **Sticky per session.** Prompt caches live with one upstream, so moving a session busts its
  cache: on Opus with 100k of context, the next turn costs ~10x. The engine sends
  `x-frog-session: <id>`; the edge pins that session to the upstream that served it and moves
  only on failure (5xx, connect error, upstream 429 after retry).
- **Same model, different host only.** An upstream entry is the same weights and defaults. GLM
  on Workers AI and GLM on z.ai can differ in quantization and reasoning defaults, so they're
  separate frog models, or one is chosen deliberately, never silently substituted.
- **Health.** Upstreams that fail repeatedly are skipped for a cooldown, like the router fleet's
  misses today (`fleet.ts`).
- **Transparency.** Every response carries `x-frog-upstream: cloudflare-aig`, plus the timing
  and usage the gateway saw. The engine records it per model call, and the app shows it
  (section 7).
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

- Model picker: **This Mac**, **Frog Cloud**, then **Your providers** (only when you've added
  one). Frog Cloud is sign-in only (account design, 2026-10-21).
- Your providers: one small Settings section, "Add a provider": a short preset list (OpenRouter,
  Anthropic, OpenAI, Ollama, LM Studio, Cloudflare, Vercel) or any OpenAI-compatible URL, then a
  key. No nags, no warnings that it's second-class.
- Logged out: local models and your providers work; Frog Cloud's built-in list shows as
  "sign in to use".
- Frog Cloud prices and model info come from its catalog; your providers keep today's catalog
  sources.
- **Where it ran, shown well.** Each turn's details (the `TurnCosts` popover) show, per model
  call: who served it (frog's GPUs, or "Anthropic via Cloudflare"), time to first token,
  tokens per second, cache hit rate, cost, and energy. Quiet by default, one hover or tap away,
  designed with the same care as the transcript, not a debug dump.
- Remove the Codex (ChatGPT sign-in) route: `provider/codex.rs`, the `codex/` specs and their
  picker rows. The iPhone `ModelSheet` and `SettingsSheet` follow the same layout.

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

## Decisions

1. **Your own providers stay, in the apps too** (Cam, 2026-10-29). Freedom like opencode's,
   kept simple: a short preset list plus any OpenAI-compatible server, one Settings section
   (section 7).
2. **Remove Codex and any subscription sign-in route** (Cam, 2026-10-29). Providers are API
   keys or servers; frog doesn't ride on other products' consumer subscriptions.
6. **Show where each call ran, beautifully** (Cam, 2026-10-29). Upstream, speed, cache, cost and
   energy per model call, in the turn details (section 7).
7. **Flat model ids** (Cam, 2026-10-29): `frog/claude-opus-5.5`.
8. **Design for other users, not Cam's keys** (Cam, 2026-10-29). Most users have no Cloudflare
   or Vercel account: they sign in to Frog Cloud, or add a key they already have. The engine's
   Cloudflare and Vercel presets stay as two of the "your providers" options (Cloudflare's
   handles `anthropic/*` over its Messages API since `1ad4a4c7`), not as how frog itself reaches
   models.

3. **Launch with three models** (Cam, 2026-10-29): `frog/dart` (Qwen3-Coder-Next), `frog/tree`
   (GLM-5.3-Flash, 321B / ~18B active), `frog/bull` (DeepSeek-V4.1-Flash, ~760B stored / ~13B
   active). No Claude or GPT on Frog Cloud at launch;
   people who want them add their own key.

## Serving the launch models

Own GPUs are margin only when they're busy. Price each model at least at its third-party list
price, so overflow breaks even and every token tang serves is margin.

Where tang is (2026-10-29):

| model | tang engine | hardware | single stream | batching | state |
|---|---|---|---|---|---|
| dart | Flash (Coder-Next) | 1× H100 class, fits at Q4 | production | yes (router fleet) | serving |
| tree | `flash/glm5`, merged to main | 1× B300, UD-Q4_K_XL (186 GB) | ~100 plain, 129.6 with MTP | no | GPU work paused (`NOTES.md`, 2026-10-29) |
| bull | `flash/deepseek`, branch `frog/deepseek-v41` | 4× H200, expert parallel | 24–43 decode; prefill ~50–60 | no | serves correctly, M3–M6 speed work open (`docs/deepseek-v41-plan.md`); a 17k-token frog prompt prefills in ~5 min |

Break-even aggregate output throughput, counting output revenue only:

| model | output $/M (third-party list) | hardware cost | tokens/s to break even | gap |
|---|---|---|---|---|
| tree | ~$4.40 (confirm the Flash price) | 1× B300, $8.99/hr | ~570 | ~4.5× single stream: needs batching |
| bull | $1.20 | 4× H200, ~$14/hr (estimate) | ~3,300 | ~80× single stream, plus prefill |

So:

- **dart**: tang only at launch; add a third-party overflow upstream once one serves the same
  weights.
- **tree**: third-party at launch (Vercel lists `zai/glm-5.3-flash`; check Cloudflare), tang
  takes over once GLM batching lands and clears ~570 tok/s on a B300. Overflow must match
  tang's behavior closely enough to share a name: tang runs 4-bit UD-Q4_K_XL, the upstream
  likely FP8. Run frog-bench on both before calling them one model.
- **bull**: third-party only (Workers AI, $0.30 / $1.20). Prefill is the blocker before
  decode: agent prompts are 17k+ tokens and turns re-prefill without prefix reuse. Revisit
  after M5–M6 and batching; the expert-parallel work also speeds up tree.

## Open decisions

4. **Margin.** Where frog makes money on third-party tokens. **Open.**
5. **The free offer.** What new users get instead of, or besides, a one-time $5 credit.
   **Open.**

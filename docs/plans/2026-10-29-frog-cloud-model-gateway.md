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
  Frog Cloud, OpenRouter, Vercel, Cloudflare, Anthropic, OpenAI, Ollama, LM Studio, plus custom
  servers. The Mac app exposes them in Settings and the model picker (`ProviderStore`,
  `ModelPicker`), with keys in the Keychain.
- Frog Cloud (`api.frog.toys/v1`) is OpenAI chat completions only, routed by the edge to tang's
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

3. **Launch with one model of our own: `frog/dart`** (Qwen3-Coder-Next) (Cam, 2026-10-29). It
   runs on This Mac and on Frog Cloud, and spills to a third-party provider when tang is full.
   tree (GLM-5.3-Flash) and bull (DeepSeek-V4.1-Flash) come later, once tang serves them
   (section "Later: tree and bull").
9. **Other models through the gateway** (Cam, 2026-10-29). With one model of our own, Frog
   Cloud also offers a short list of third-party models, served entirely by upstreams and
   billed through the same credits. They use their real names (`frog/claude-sonnet-5.5`,
   `frog/glm-5.3-flash`), so `tree` and `bull` stay the names of tang-served models.

## Launch: dart

### Weights

> **Note (2026-11-05):** the speeds in this plan are the Oct 21–29 measurements, kept as
> written. Current engine numbers (234 tok/s single stream, up to 402 with MTP, B=64 1,817 tok/s,
> serve C=64 1,078 tok/s, prefill 6.6k–7.6k) are in [docs/launch/bench.md](../launch/bench.md).

| where | weights | notes |
|---|---|---|
| Frog Cloud (tang, H200) | unsloth `Qwen3-Coder-Next-UD-Q4_K_XL.gguf` (mixed 4-bit) | `zest/docs/runbooks/frog-cloud/node-up.sh`; 234 tok/s single stream |
| tang alternative | Q8_0 | 222 tok/s (5% slower); vs Q4: KL median 0.0005, top-1 agreement ~97% (`zest/docs/bench/frog-api-vs-novita.md`) |
| This Mac | MLX 4-bit, ~45 GB | needs a 64 GB+ Mac; not in `LOCAL_MODELS` yet |
| third-party backups | FP8 | Together, Novita, Parasail, Bedrock |

Q4 and Q8 differ by less than the noise between providers, so a higher-precision upstream
counts as "same model, different host".

**frog-bench, 2026-10-29** (9 tasks × 3, tool mode auto, tang on 1× H200 with zest-node
`sha256:1b3c1bdf…`, OpenRouter pinned to Parasail):

| | pass | avg s | calls/run | tokens/solve | cache hit | cache busts | prefill s/call |
|---|---|---|---|---|---|---|---|
| tang, Q4 | 16/27 | 12.5 | 3.6 | 67.6k | 73% | 0 | 2.36 |
| OpenRouter (Parasail, bf16) | 17/27 | 11.8 | 5.6 | 102.1k | 62% | 27 | 0.90 |

Per task the two match, except `present-next-steps` (1/3 vs 0/3) and one tang `find-answer`
run that hit the edge's own 429 ("too many concurrent requests"). Both fail every
`present-latency` and `present-restraint` run: a model limit, not a host one. Same model in
practice, so Parasail is a valid overflow upstream for dart.

Found along the way:
- OpenRouter has one host for Qwen3-Coder-Next today (Parasail, bf16, $0.12 / $0.80 per M). No
  FP8 host, so no redundancy behind the backup yet; add Together direct as a second.
- Parasail busts prompt caches (27 cold calls) and the edge's sticky sessions can't fix that.
- `zest-node:latest` (`sha256:903996…`, the image the GLM node used) crashes dart on the first
  multi-thousand-token prompt: `fe_q8` `CUDA_ERROR_ILLEGAL_ADDRESS` at `coder.rs:2405`. Pin the
  dart image by digest in `node-up.sh` until it's fixed.
- tang prefill per call is ~2.6× slower than Parasail's; decode and turn counts make up for it.

### Backup provider

**OpenRouter, pinned to Parasail** (bf16; the only Qwen3-Coder-Next host on OpenRouter today). The same key serves the
other models (decision 9). The cost is OpenRouter's credit fee. Parasail is a single host, so
add Together direct (FP8, ~$0.50 / $1.20 per M, unverified) as a second overflow upstream.

Alternative: Together direct (one provider, no reseller fee). Cloudflare Workers AI and Vercel
don't appear to list Qwen3-Coder-Next.

### Pricing

Price dart at or above the backup's cost (FP8 at ~$1.20/M output), so overflow never loses
money and tang's tokens are margin.

## Other models (decision 9)

- A short, curated list at launch: e.g. Claude Sonnet 5.5, Claude Opus 5.5, GLM-5.3-Flash,
  DeepSeek-V4.1-Flash. Billed at the upstream's price plus the credit fee.
- All go through OpenRouter at launch, so the gateway has one third-party upstream.
- Claude on chat completions loses caching unless the upstream passes `cache_control` through;
  check OpenRouter's. If it doesn't, Claude waits for `/v1/messages` (section 1).
- The turn details say who served each call ("Anthropic via OpenRouter"), the same as overflow.

## Later: tree and bull

Where tang is (2026-10-29):

| model | tang engine | hardware | single stream | batching | state |
|---|---|---|---|---|---|
| dart | Flash (Coder-Next) | 1× H100 class, fits at Q4 | production | yes (router fleet) | serving |
| tree | `flash/glm5`, merged to main | 1× B300, UD-Q4_K_XL (186 GB) | ~100 plain, 129.6 with MTP | no | GPU work paused (`NOTES.md`, 2026-10-29) |
| bull | `flash/deepseek`, open PR muni-works/tang#140 | 8× H100, expert parallel | 193 greedy, 150–190 sampled (DSpark); prefill ~500 | no | serves through `deepseek-serve`; some late merges unmeasured on the real model; 169 commits behind main |

Break-even aggregate output throughput, counting output revenue only:

| model | output $/M (third-party list) | hardware cost | tokens/s to break even | gap |
|---|---|---|---|---|
| tree | ~$4.40 (confirm the Flash price) | 1× B300, $8.99/hr | ~570 | ~4.5× single stream: needs batching |
| bull | $1.20 | 8× H100, ~$20/hr (estimate) | ~4,600 | ~24× single stream: needs batching |

When tang serves them, they launch under their frog names:

- **tree**: tang takes over from the third-party GLM-5.3-Flash once GLM batching clears
  ~570 tok/s on a B300 and frog-bench matches the upstream.
- **bull**: tang's single stream is already fast (193 tok/s as of Oct 29; not re-measured, see the 2026-11-05 note under Weights, a 17k-token prompt prefills in
  ~35 s); it pays once batching gets ~24× single stream on 8× H100, or on reserved GPUs well
  under the rental estimate. Prefix reuse across turns matters as much as batching.

## Open decisions

4. **Margin.** Where frog makes money on third-party tokens. **Open.**
5. **The free offer.** What new users get instead of, or besides, a one-time $5 credit.
   **Open.**

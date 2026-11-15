# Cloudflare Workers AI vs Vercel AI Gateway

Eval for frog provider support: can Cloudflare serve GLM-5.3 and DeepSeek V4.1 Flash
at pass-through prices, and does frog need it alongside the Vercel AI Gateway preset?

## Models and prices (per M tokens)

Both models are on Workers AI, OpenAI-compatible, 1M context, function calling:

| Model | Where | In | Out | Cached in | Notes |
|---|---|---|---|---|---|
| `@cf/zai-org/glm-5.3` | Workers AI | $1.40 | $4.40 | $0.26 | reasoning low/high/max (default max), cannot be disabled |
| `@cf/deepseek-ai/deepseek-v4.1-flash-1017` | Workers AI | $0.30 | $1.20 | $0.006 | reasoning none/low/high (default high)/max; vision |
| `zai/glm-5.3` | Vercel AI Gateway | $1.40 | $4.40 | — | pass-through, zero markup |

GLM-5.3 pricing is identical on both. Workers AI charges cached input separately
(implicit prompt caching; GLM-5.3 cached input is ~5.4x cheaper, DeepSeek ~50x).

## Comparison

| | Cloudflare Workers AI | Vercel AI Gateway |
|---|---|---|
| Pricing | per-model unit pricing, billed to CF account; cached input discounted | zero markup, pass-through from each provider |
| Endpoint | `https://api.cloudflare.com/client/v4/accounts/{ACCOUNT_ID}/ai/v1` (OpenAI-compatible) | `https://ai-gateway.vercel.sh/v1` |
| Keys | one CF API token + account id in URL | one Vercel key, no provider accounts |
| BYOK | n/a (CF serves the models) | not needed for hosted models; no provider keys to manage |
| Caching | implicit prompt caching, billed at cached rate | provider-side caching passes through; no extra charge |
| Fallbacks | none server-side on Workers AI itself (CF AI Gateway, a separate proxy product, has them) | none server-side; handle client-side |
| Model names | `@cf/<org>/<model>` in the `model` field | `<provider>/<model>` |

Frog-relevant wrinkles:

- The CF base URL embeds the account id, so it can't be a static `Preset::base_url`
  as written; it needs to be built at request time from `CLOUDFLARE_ACCOUNT_ID`
  (same pattern as `cloud_base_url_from` in providers.rs:195).
- GLM-5.3 reasoning is always on (min effort `low`), so frog's `Thinking` config
  can only lower it, never turn it off. DeepSeek V4.1 Flash takes `none`.
- Neither has server-side fallbacks, so a fallback story means frog-level retry
  across providers either way — no advantage to either.

## Provider sketch (crates/frog-engine/src/providers.rs)

```rust
// Cloudflare Workers AI: OpenAI-compatible, but the account id lives in the URL.
// Model names keep their @cf/ prefix: cloudflare/@cf/zai-org/glm-5.3.
const CF_BASE: &str = "https://api.cloudflare.com/client/v4/accounts";
pub fn cf_base_url_from(env: &dyn Fn(&str) -> Option<String>) -> Option<String> {
    let id = env("CLOUDFLARE_ACCOUNT_ID")?;
    Some(format!("{CF_BASE}/{id}/ai/v1"))
}

Preset {
    id: "cloudflare",
    name: "Cloudflare Workers AI",
    kind: ProviderKind::Openai,
    base_url: "", // resolved per-request via cf_base_url_from; hidden until set
    key_env: &["CLOUDFLARE_API_TOKEN", "CLOUDFLARE_API_KEY"],
    key_url: "https://dash.cloudflare.com/profile/api-tokens",
    local: false,
}
```

`normalize` needs no change (`cloudflare/@cf/...` round-trips; the `/` split takes
the first separator, so `preset()` still matches on `cloudflare`). List models via
`GET .../ai/models` filtered to `@cf/` text models, or hardcode the two above as
suggested models.

## Benchmark plan

Question: is CF's serve path faster than Vercel's for the same model, and does
either hold up at frog's typical 4-way concurrency?

- Targets: `cloudflare/@cf/zai-org/glm-5.3` vs `vercel/zai/glm-5.3`, plus
  `cloudflare/@cf/deepseek-ai/deepseek-v4.1-flash-1017` for the cheap tier.
- Metrics: TTFT (first content token), tok/s (streamed output tokens), and
  cost per 1k-token turn. Record cache-hit input pricing separately by running
  a repeated-prefix prompt twice and diffing the two receipts.
- Load: 1 concurrent stream, then 4 (frog's subagent pattern); 10 requests
  per cell, report median and p90. Same prompt set, same `max_completion_tokens`,
  GLM-5.3 pinned to `reasoning_effort: low` on both so thinking cost matches.
- Tooling: a small script against both endpoints with the OpenAI client,
  SSE timing from first byte; no frog engine changes needed for the eval.
- Pass bar for adding the preset: median tok/s within 10% of Vercel or better,
  TTFT under 1s at 4-concurrent, and pricing already equal — so the decision
  rests on speed and the single-token (no per-provider key) setup.

## Benchmark result (2026-10-22): not run to completion

`scripts/bench-gateways.sh` ran, but both Workers AI cells returned
`403 Forbidden` for every request: the CF account behind the available
`CLOUDFLARE_API_TOKEN` is on the **Workers Free plan**, and both
`@cf/zai-org/glm-5.3` and `@cf/deepseek-ai/deepseek-v4.1-flash-1017` are
pay-plan-only ("Model is not available on the Workers Free plan. Upgrade to
access this model"). A free-plan model (`@cf/meta/llama-3.3-70b-instruct-fp8-fast`)
authenticates and streams fine on the same endpoint and token, so the setup
(path, `Bearer` auth, SSE) is verified; only the plan gates the two target
models. Vercel was skipped: no `AI_GATEWAY_API_KEY` in the environment.

No TTFT/tok/s numbers were collected. Rerun on an account with the Workers
Paid plan (and a Vercel key exported) to get them.

## Verdict

Prices are identical; the choice is operational. Vercel is already a preset with
a static base URL. CF is worth adding only if the benchmark shows a speed edge or
we want the deep cached-input discount on long agentic prompts (DeepSeek V4.1
Flash cached input at $0.006/M is effectively free prefill).

# tang cloud gateway: plan (2026-10-09)

Goal: a frog-run cloud gateway serving open models up to frontier class: 1T-parameter MoE (Kimi K2 / DeepSeek V4 / GLM 5 class), the open-weight tier closest to Fable. It runs on tang, with sessions that keep their KV hot. This is the "Frog Pro on a tang-backed gateway" bet in [ROADMAP.md](../ROADMAP.md). It builds on the [node design](2026-10-04-frog-node-design.md) and the economics in [inference-network.md](../research/inference-network.md).

## The constraint that shapes everything

A frontier MoE does not fit on one GPU, and it doesn't pay for itself at batch 1.

- **Weights:** about 1T parameters at int4 is about 500–600 GB. A 671B model at FP8 is about 700 GB. Either way that's an 8×H200 node (1.1 TB HBM) or 8×B200. Expert offload to CPU or NVMe, the way tang runs Flash-Next on mew, is fine for one user at about 10 tok/s. For a gateway it's dead weight.
- **Cost:** an 8×H200 node rents for about $20–30/hr. At batch 1 and about 40 tok/s, that's **about $150–200 per M output tokens**. Hosted DeepSeek V4 Flash output is $0.24/M. DeepSeek's own serving reaches about 1.85k tok/s per GPU because expert parallelism spreads each expert across hundreds of concurrent sequences.
- **So:** tang at frontier scale needs **multi-GPU plus continuous batching**. Today it has neither: one model per process, one worker thread, one stream at a time. That's the main body of work. The gateway in front is small by comparison.

Our edge over a hosted API isn't raw $/token. It's **session-pinned KV**: about 79% of agent input is cacheable, so prefill drops about 4.8x. Add MTP or prompt-lookup drafting, local→cloud handoff without re-sending, and a frog-tuned model. We only win if batching gets per-token cost into the same order of magnitude as hosted. Otherwise we're selling latency at a loss.

## Decisions

- **Tiered rollout. The gateway ships before tang can serve frontier models.** The gateway routes by model. Mid-size models (Flash-Next, 80B-A3B) run on tang from day one. Frontier models go to an upstream provider (OpenRouter) behind the same API until tang can serve them. Users see one endpoint, and backends swap underneath without frog changes.
- **Sessions are pinned to a replica.** Routing is by `prompt_cache_key`, so a session's KV lives on one replica. Failover is re-prefill elsewhere, the same rule as the node scheduler.
- **tang stays single-tenant behind the edge.** Each replica has one internal key and never sees user identity. Per-tenant isolation lives in the edge: a tenant id is prefixed into the cache key, so KV blocks are never shared across tenants. The only exception is the system-prompt prefix, which is public anyway.
- **Parallelism inside one node only.** Tensor and expert parallelism across the 8 GPUs of one NVLink box. No cross-node EP. That needs InfiniBand and DeepSeek-scale traffic, and we have neither.
- **Model set kept small.** One frontier MoE (pick by tool-call accuracy on frog bench, not leaderboards; see the K2 Vendor Verifier findings) plus Flash-Next. Each extra architecture costs kernels.

## Architecture

```
frog ──HTTPS──▶ edge (axum) ──internal──▶ tang-llm replicas (1 per GPU box)
                 │  auth, tenant, meter          │  TP/EP across 8 GPUs
                 │  route by cache key           │  continuous batching
                 │  upstream fallback ──▶ OpenRouter (frontier, until G3)
                 └─ polls /node for load + KV
```

## Phases

### G0: frog can use a remote tang (small, now)
- The `tang` provider takes `base_url` + `api_key`. Today `sidecar::base_url()` is hardcoded to 127.0.0.1.
- The location label follows [models.md](../models.md): "Cloud · frog". Per-project cloud policy applies.
- Proof: frog against Flash-Next on mew over Tailscale with a key. Bench parity with local.

### G1: edge proxy (small)
- New crate `frog-gateway`: axum, OpenAI-compatible passthrough, SSE streaming.
- User API keys → tenant. Per-tenant rate limits.
- Metering from `stream_options.include_usage`: input, cached input and output tokens per request, written to an append-only log (SQLite to start). Billing per finished task comes later. Log the task id now so it's possible.
- Routing: model → replica set, then `prompt_cache_key` → sticky replica (table plus `/node` KV hashes). Re-prefill failover. Upstream fallback for models with no tang replica.
- Deploy: one small VM, TLS. Replicas are reached over a private network (Tailscale is fine to start).

### G2: continuous batching in tang-llm (large, the economics)
- Replace the single worker loop with a scheduler that runs a step over all active sequences: mixed prefill chunks plus decode tokens per step.
- Paged KV already exists (256-position blocks, content hash). Extend it into the batch's block table. Preemption by evicting cold slots to the kvstore, not dropping them.
- Keep `x-frog-priority`: interactive decode first, background prefill fills the gaps.
- Proof: tok/s per GPU vs concurrency on Flash-Next on a single H100. Target: aggregate throughput at least 10× batch 1 at 32 concurrent sessions, with p50 per-stream decode no more than 1.5× worse.

### G3: one frontier model on one 8-GPU node (large, the capability)
- **Weights:** a loader for the chosen model (DeepSeek-V4-style MLA + MoE, or Kimi K2 int4). FP8/int4 GEMMs on Hopper. KV in bf16 or FP8, not f32 as today. f32 KV at 1T scale wastes most of HBM.
- **Parallelism:** experts sharded across 8 GPUs (EP=8), attention and dense layers TP=8 or replicated. All-to-all over NVLink via NCCL. Start with TP everywhere if EP slips. It's simpler and fine at modest batch.
- **Drafting:** use the model's MTP head. That's the same exactness and parity discipline as the Flash-Next work.
- **Proof:** parity vs a reference implementation on logits; frog bench task success matches the same model on OpenRouter; tok/s/GPU at 64 concurrent sessions.
- **Ship gate:** cost per M output tokens at expected load is within 3× of hosted, and task latency (with pinned KV) beats hosted. Until both hold, that model keeps routing upstream.

### G4: handoff and Pro features
- Local→cloud handoff: the edge accepts a session id plus KV block hashes, so only missing blocks get prefilled. Shipping KV from a Mac to the cloud isn't worth it: the formats differ, and so would the model.
- A frog-tuned model on the same serving path.
- Per-task pricing on top of the G1 meter.

## Hardware

- G0–G2: mew (3090) for dev. One rented H100 for batching work, at about $2–3/hr.
- G3: rent an 8×H200 node only for parity and bench windows, not 24/7. Commit to reserved capacity only after the G3 ship gate passes with real traffic numbers.
- Provider: Runpod, Lambda or similar. Pick on hourly 8×H200 availability. Not decided yet.

## Open questions

- Which frontier model? Decide by frog bench tool-call accuracy and license.
- Who are the first users? Just me and friends means G1 metering can stay a log. Paying users need billing and abuse controls before launch.
- Do we keep upstream fallback permanently for models we'll never self-host?
- Data policy: prompts are retained for no time by default. Do we ever keep KV on disk across sessions for paying users, and how long?

## Out of scope

- Cross-node expert or pipeline parallelism over WAN (see the research: 2–6 tok/s).
- A public contribute-your-GPU network.
- Multi-region.

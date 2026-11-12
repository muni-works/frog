# vLLM baseline for coder-next (what tang has to beat)

2026-11-12. We ran vLLM and tang's hand engine on the same card, under the same agent-like load.

## Status

**vLLM is not going to prod.** Cam decided this on 2026-11-12: it is the baseline tang has to beat, and nothing more. This doc records that baseline under an agent-like serving load.

The micro-bench numbers (prefill and decode tok/s at 4k/32k, batch 1/4/16, H200) go to tang's `bench/results/board.jsonl`.

On a $2.49/hr RTX PRO 6000, tang has to close these gaps:

| | vLLM | tang |
|---|---|---|
| Output tok/s at C=32 | 757 | 490 (1.5× short) |
| TTFT p95 at C=32 | 0.5 s | 1.4 s |
| $ per M output, 40% busy | $2.28 | $3.53 |
| $ per M output, 70% busy | $1.31 | $2.02 |
| Break-even busy fraction (vs ~$2.69/M output revenue) | 34% | 52% |

tang already wins on:

- **Prefix hit rate** under memory pressure: 86% vs 43% at C=32.
- **Single-stream decode:** 193 vs 185 tok/s.

## Setup

**Hardware.** One RTX PRO 6000 Blackwell Server Edition (96 GB, sm_120), RunPod secure cloud, EUR-IS-2, $2.49/hr. That's the same SKU and price as the prod node, which we didn't touch.

- Both engines ran on this one pod, one after the other.
- The pod was terminated afterwards.
- Total spend was about $4.50: ~$3.50 for this pod, plus ~$1 for an H200 that crash-looped at container create.

**vLLM.**

- vLLM 0.33.0 with torch 2.14 / cu130, serving the official `Qwen/Qwen3-Coder-Next-FP8` (75 GB).
- Flags: `--enable-prefix-caching --enable-chunked-prefill --max-model-len 32768 --max-num-seqs 64 --gpu-memory-utilization 0.92`.
- vLLM picks Mamba cache mode `align` for Qwen3-Next by default; the attention block is 576 tokens.
- KV pool: 402,649 tokens (10.4 GiB).
- We had to set `VLLM_USE_DEEP_GEMM=0`. Otherwise the DeepGEMM JIT asserts nvcc ≥ 12.9, and the image ships 12.8.
- Not tuned: no FP8 KV cache and no MTP.

**tang.**

- tang main `2babf65f`, running `tang-llm serve` (flash engine, hand kernels) on `unsloth/Qwen3-Coder-Next-GGUF` UD-Q4_K_XL (47 GB, the same file prod serves).
- `TANG_CODER_KV=int8`, `--ctx 32768`.
- We ran `--batch 16` and `--batch 32`. Prod runs `--batch 48`.
- 92 sequence slots fit.
- No MTP. Under continuous batching tang runs "per-row sampling, no drafts" anyway.

**Load.** [`vllm-interim/agentload.py`](vllm-interim/agentload.py), derived from tang's `scripts/prefix-replay.py`.

- 2×C sessions share a 3,000-word system/tools block.
- Each session opens with an 800-word task, then runs 6 turns of 256 output tokens + a 700-word tool result.
- There's a 0.2–1.5 s "tool" pause between turns.
- The measured shape was **26.8 prompt tokens per output token**. The cacheable share is ~89% in principle; observed hit rate was 76–94%.
- Requests were greedy with `ignore_eos`/`min_tokens`. vLLM honours these; tang ignores them and sometimes stops early. tang therefore ran at 32 prompt tokens per output token. That shape is slightly harder, so it biases against tang by a few percent.

**Metrics.**

- Aggregate tok/s = output tokens / wall clock, tool pauses included.
- Per-stream tok/s = median over requests of (out − 1) / (wall − TTFT).
- Hit rate = `cached_tokens` / `prompt_tokens`, from each server's usage block. vLLM's first pass gives the same numbers from its `prefix_cache_hits/queries` counters.
- vLLM's first pass overlapped tang's CPU build, so we re-ran vLLM at C=1/4/16 on a quiet box. The rows below are the clean ones; they were 3–5% better.
- Raw rows: [`vllm-interim/results.jsonl`](vllm-interim/results.jsonl).
  - The first-pass `vllm` rows report `cached_tokens` 0 because prompt-token details were off. Their `agg_total_tok_s` therefore overcounts prefill.
  - Hit rates for those rows come from the server's counters; the `vllm2` rows are direct.

## Results

| engine | C | agg out tok/s | per-stream tok/s | TTFT p50 | TTFT p95 | prefix hit | VRAM used |
|---|---|---|---|---|---|---|---|
| vLLM FP8 | 1 | 163 | **185** | 0.18 s | 0.19 s | 76% | 89.6 GB (fixed pool) |
| vLLM FP8 | 4 | 355 | 99 | 0.13 s | 0.20 s | 81% | 89.6 GB |
| vLLM FP8 | 16 | **675** | 46 | 0.12 s | 0.21 s | 81% | 89.6 GB |
| vLLM FP8 | 32 | **757** | 24 | 0.28 s | 0.51 s | 43% | 90.8 GB |
| vLLM FP8 | 64 | **889** | 15 | 0.36 s | 4.05 s | 42% | 90.8 GB |
| tang b16 | 1 | 161 | **193** | 0.19 s | 0.24 s | 86% | 49.9 GB |
| tang b16 | 4 | 369 | 105 | 0.19 s | 0.46 s | 94% | — |
| tang b16 | 16 | 421 | 28 | 0.21 s | 0.56 s | 88% | — |
| tang b16 | 32 | 399 | 26 | 8.65 s | 10.3 s | 84% | — |
| tang b16 | 64 | 270 | 19 | 36.4 s | 52.8 s | 61% | 81.1 GB |
| tang b32 | 16 | 400 | 27 | 0.39 s | 0.89 s | 87% | 49.9 GB |
| tang b32 | 32 | **490** | 17 | 0.25 s | 1.43 s | 86% | 65.0 GB |
| tang b32 | 64 | 377 | 12 | 17.9 s | 25.8 s | 74% | 80.2 GB |

VRAM headroom: vLLM grabs 92% up front, leaving ~7 GB free. tang grows from 50 GB to 81 GB at C=64, leaving ~17 GB.

What the numbers say:

- **Single stream is a tie, slightly in tang's favour.** That matches the 197 tok/s we see in prod.
- **The gap opens at C≥16.** vLLM keeps scaling to 889 tok/s at C=64, and its TTFT p95 stays under 0.6 s through C=32. tang tops out around 420–490 tok/s, and its throughput drops past its batch size. Queued requests wait whole turns, so TTFT runs to 10–50 s.
- **tang is far better at keeping prefixes.** It parks GDN states and spills them to host RAM, so it holds 84–86% hits at C=32 and still 61–74% at C=64.
  - vLLM's only cache is its 402k-token GPU pool. At C=32 (64 sessions × ~10k tokens) that pool thrashes, and hits fall to ~42%.
  - vLLM still wins on throughput there. Its FP8 prefill is fast enough that re-prefilling is cheap: it computed ~12–15k tok/s (prefilled + generated) against tang's 2.7–3.6k.
  - This is the one place tang's architecture is clearly ahead. vLLM's CPU KV offload (LMCache / `--kv-transfer-config`) is the follow-up that would close it.
- **Prefill is the whole story.** vLLM computed 2× tang's tokens (prefilled + generated) per second at C=16, and 4–5× at C=32/64, where it re-prefills what it can't cache. That agrees with prefill-gap's finding that tang is 3–11× behind llama.cpp on prefill.

## Economics

Cost per M output tokens = $2.49/hr ÷ (aggregate out tok/s × busy fraction × 3600) × 10⁶.

Revenue is ~$2.69 per M output tokens all-in: the $0.12 / $0.07 cached input prices at ~25 input tokens per output token, plus $0.80 for the output itself.

| engine, operating point | out tok/s | $/M out @ 40% busy | margin @ 40% | $/M out @ 70% busy | margin @ 70% |
|---|---|---|---|---|---|
| vLLM, C=64 (TTFT p95 4 s) | 889 | $1.95 | +28% | $1.11 | +59% |
| **vLLM, C=32 (TTFT p95 0.5 s)** | 757 | **$2.28** | **+15%** | **$1.31** | **+51%** |
| vLLM, C=16 | 675 | $2.56 | +5% | $1.46 | +46% |
| **tang b32, C=32 (TTFT p95 1.4 s)** | 490 | **$3.53** | **−31%** | **$2.02** | **+25%** |
| tang b16, C=16 | 421 | $4.11 | −53% | $2.35 | +13% |

Break-even busy fraction against $2.69:

- vLLM at C=32: **34%**
- vLLM at C=64: **29%**
- tang b32 at C=32: **52%**
- tang b16 at C=16: **61%**

Per token at the 40% busy point, vLLM is $0.0000023 and tang is $0.0000035 per output token.

Caveat: prod runs tang at `--batch 48` with a 64k context, which we didn't measure. Going from b16 to b32 added 23% at C=32 but did worse at C=64 as queues built, so b48 alone won't close a 1.5× gap.

## What tang needs to beat vLLM

- **Prefill.** vLLM computed 2× tang's tokens (prefilled + generated) per second at C=16, and 4–5× at C=32/64. This is the main lever: prefill-gap / layerwise.
- **Batched decode past the batch size.** tang's throughput falls past `--batch`, and queued turns wait 10–50 s. vLLM keeps scaling to C=64.
- **Keep the cache lead.** vLLM's fix is CPU KV offload (LMCache), so tang's state spill is an advantage worth keeping as contexts grow.
- **Bar:** at least 757 out tok/s at C=32 with TTFT p95 ≤ 0.5 s on this load. That is ≤ $2.28 per M output at 40% busy.

## Reproducing

1. Rent one RTX PRO 6000, secure cloud. Keep `disk` ≤ 100 GB: larger asks failed for capacity on 2026-11-12.
   - The frog-models global volume was slow and wedged reads during this run (sccache and GGUF copies hung in D state). Pull weights from HF straight to container disk or `/dev/shm`.
2. vLLM: `uv pip install vllm hf_transfer`, then `hf download Qwen/Qwen3-Coder-Next-FP8`, then serve with the flags above plus `--enable-prompt-tokens-details`. Put the venv's bin on `PATH` (vLLM shells out to `ninja`).
3. tang: build with `RUSTC_WRAPPER= cargo build --release -p tang-llm --features cuda`. The empty `RUSTC_WRAPPER` matters because sccache on the volume hung. Then `TANG_CODER_KV=int8 tang-llm serve <gguf> --ctx 32768 --batch 32`.
4. Load: `CONC=<c> URL=<server> python3 docs/vllm-interim/agentload.py`, for c ∈ {1, 4, 16, 32, 64}.

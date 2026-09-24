# LLM inference speed frontier, and what tang/frog should bet on

Written 2026-09-23. Scope: single-user (batch-1) decode speed, time-to-first-token (TTFT), and wall-clock time per finished agent task on consumer hardware (Apple Silicon, RTX 3090), plus a possible hosted "frog Pro" tier.

How to read the labels: **[vendor]** means a vendor's own claim that nobody independent has checked. **[unverified]** means I only saw it in secondary coverage or search snippets and did not read the primary source. **[calc]** means my own arithmetic. Everything else links to the primary source I read, or to a close second-hand source.

---

## 0. TL;DR

1. **Tang is at about 45% of the RTX 3090's bandwidth ceiling.** Qwen3-8B at MLX 4-bit reads about 4.3 GB per token. At 90 tok/s that is roughly 390 GB/s out of 936 GB/s **[calc]**. Well-tuned batch-1 engines reach 70–80% of peak (the Hazy megakernel hit 78% on an H100). So the same model has **1.5–1.8x of pure kernel headroom** before any algorithmic trick.
2. **In agent contexts, the KV cache is half of the memory traffic.** Qwen3-8B stores about 147 KB of fp16 KV per context token. At 20K tokens of context, each decoded token reads about 2.9 GB of KV on top of 4.3 GB of weights, so the ceiling drops from about 206 to about 130 tok/s on a 3090 **[calc]**. Quantizing KV and using hybrid-attention models are decode-speed work, not just memory work.
3. **The largest proven algorithmic win for this workload is model-free drafting from session history.** SuffixDecoding reached up to 5.3x on agentic SQL and 1.8–4.5x end-to-end on SWE-Bench agent subtasks. It beats EAGLE-3 on these workloads and runs on the CPU. A learned drafter should be layered on top for novel text: native MTP heads measured +33–60% on a 3090, and DFlash block diffusion is another option.
4. **Apple Silicon behaves differently.** Verifying extra tokens is not nearly free on Metal the way it is on CUDA at batch 1. EAGLE-3 in MLX gave only 1.05x on M3 Ultra. Drafting on Mac only pays when acceptance is very high, which is the copy-heavy spans that suffix/prompt lookup catch. Prefill is what hurts on Mac: an M4 Max prefills an 8B model at roughly 0.5–1K tok/s. M5 Neural Accelerators give about 4x on TTFT, and KV reuse (in memory, then on disk) is the main lever.
5. **The speed hardware frontier is 1–17K tok/s per user, served from the cloud.** Cerebras reports about 2K tok/s on Qwen3-Coder-480B. Nvidia/Groq LPX reports about 3.4K tok/s. Taalas HC1 claims about 17K tok/s on a hard-wired Llama-3.1-8B, and AMD agreed to buy Taalas in August 2026. Diffusion LLMs (Mercury 2/2.5) serve about 1K tok/s. None of this transfers to local hardware. It matters for a "frog Pro" speed tier.
6. **Agent wall-clock depends on the tool setup.** Measured LLM share of runtime ranges from 71–98% in one study to 40% in another (tools were 60% for coding in PASTE). Cutting steps (parallel tool calls, speculative tool execution) produced 20–48% task-time reductions in papers. Frog should measure its own split before choosing between faster tokens and fewer, overlapped steps.

---

## 1. The physics

### 1.1 Decode is bandwidth-bound at batch 1

tok/s ≤ memory bandwidth / (weight bytes read per token + KV bytes read per token). In practice engines reach 50–80% of peak. The Hazy megakernel reached 78% of H100 bandwidth, where vLLM and SGLang sit around 50% ([Hazy Research, "No Bubbles", May 2025](https://hazyresearch.stanford.edu/blog/2025-05-27-no-bubbles); [repo](https://github.com/HazyResearch/Megakernels)).

Peak bandwidth (spec sheets):

| Hardware | Bandwidth | Notes |
|---|---|---|
| M4 Pro | 273 GB/s | |
| M3 Max | 300 / 400 GB/s | binned / full |
| M4 Max | 410 / 546 GB/s | binned / full |
| M5 Max | 460 / 614 GB/s | 32-core / 40-core GPU ([promptquorum, 2026](https://www.promptquorum.com/local-llms/apple-silicon-m5-local-llm); [openclawdc](https://openclawdc.com/blog/m5-max-macbook-pro-local-llm/)) |
| M3 Ultra | 819 GB/s | |
| M5 Ultra | ~1.2 TB/s | Mac Studio, Aug 2026 **[unverified: search snippet of the Apple newsroom page, not read directly]** ([Apple newsroom](https://www.apple.com/newsroom/2026/08/apple-introduces-new-mac-studio-with-m5-max-and-m5-ultra/)) |
| RTX 3090 / 4090 / 5090 | 936 / 1008 / 1792 GB/s | |
| H100 SXM / H200 / B200 | 3.35 / 4.8 / ~8 TB/s | |

**Qwen3-8B, MLX 4-bit, group size 64 (about 4.5 bits per weight, untied lm_head): about 4.26 GB of weights read per token. KV is 36 layers × 8 KV heads × 128 dim × K+V × fp16 = 147 KB per context token.** [calc]

Theoretical batch-1 decode ceilings (100% of peak bandwidth, fp16 KV) [calc]:

| Hardware | 2K ctx | 20K ctx | 60K ctx |
|---|---|---|---|
| M4 Pro | 60 | 38 | 21 |
| M3 Max (400) | 88 | 55 | 31 |
| M4 Max (546) | 120 | 76 | 42 |
| M5 Max (614) | 135 | 85 | 47 |
| M3 Ultra | 180 | 114 | 62 |
| M5 Ultra (~1.2T) | 264 | 166 | 92 |
| **RTX 3090** | **206** | **130** | **71** |
| RTX 5090 | 394 | 249 | 137 |

A realistic target is about 75% of these numbers.

**MoE, e.g. Qwen3-Coder-30B-A3B / Qwen3.5-35B-A3B at 4-bit.** About 3.3B active parameters means about 1.86 GB read per token. The ceiling is about 456 tok/s on a 3090 and about 266 on an M4 Max at 2K context [calc]. Real engines get far less, because expert reads are scattered and router/gather overhead dominates at small sizes. Measured: Qwen3-30B-A3B Q4_K_M on an RTX 5090 in llama.cpp went from about 247 to about 352 tok/s with optimizations ([mayhemcode, Sep 2026](https://www.mayhemcode.com/2026/09/rtx-5090-llamacpp-19x-local-ai.html) **[unverified blog]**). That is about 35–40% of the 5090 ceiling, so MoE kernels have the most headroom.

**Hybrid attention (Qwen3-Next / Qwen3.5+: about 75% Gated DeltaNet linear layers, 25% full attention) cuts KV growth by about 4x.** Most layers carry O(1) recurrent state instead of KV. Qwen reports about 4x decode at 4K and about 10x at 32K+ for Qwen3-Next versus Qwen3-32B ([Qwen3-Next model card](https://huggingface.co/Qwen/Qwen3-Next-80B-A3B-Instruct); [Qwen3.5 blog](https://qwen.ai/blog?id=qwen3.5)) **[vendor]**. For long agent contexts this matters more than weight quantization.

**Where current engines stand:**
- Tang, CUDA: about 90 tok/s on Qwen3-8B-4bit on a 3090, roughly 44% of the 2K-context ceiling [calc]. Context length is unknown. If that number was measured at around 20K context, tang is at about 70% of that context's ceiling, which is already good, and the remaining lever is KV bytes.
- MLX, M4 Max, Qwen3-8B: reported at 62 tok/s ([markaicode](https://markaicode.com/benchmarks/hugging-face-qwen-3-m4-max-throughput-benchmark/) **[suspicious: it mentions Q4_K_M, a GGUF format, "in MLX"]**). Community numbers are typically 90–100 tok/s, which is about 75–80% of peak.
- BaseRT (hand-written Metal 4 tensor kernels) reports decode 1.33x faster than MLX and 1.75x faster than llama.cpp on an M5 Pro ([arXiv 2607.19438, Jul 2026](https://arxiv.org/abs/2607.19438)). So even MLX leaves headroom on M5.

### 1.2 Prefill / TTFT is compute-bound

An 8B dense model costs about 2 × 8e9 = 16 GFLOP per prompt token, plus attention that grows with context.

- **RTX 3090:** about 71 TFLOPS FP16 tensor (FP16 accumulate; GeForce runs at half rate with FP32 accumulate) and roughly double for INT8 (spec sheet, approx.). At 40–50% MFU that is about 1.8–2.5K tok/s prefill for 8B. A 20K cold prompt takes about 10 s; a 3K uncached suffix takes about 1.5 s [calc].
- **M4 Max GPU:** about 17–18 TFLOPS FP16, with no tensor cores before M5. That gives roughly 0.5–1K tok/s for 8B. A 20K cold prompt takes 20–40 s; a 3K suffix takes about 3–6 s [calc]. **On a Mac, the uncached suffix of each turn is the main TTFT cost.**
- **M5 GPU Neural Accelerators:** Qwen3-14B-4bit TTFT was 4.06x faster than M4, while decode was only 1.19x faster ([Apple ML Research, "Exploring LLMs with MLX and the Neural Accelerators in the M5 GPU", late 2025](https://machinelearning.apple.com/research/exploring-llms-mlx-m5)). BaseRT reports prefill up to 6.4x faster than llama.cpp and 3.9x faster than MLX on an M5 Pro ([arXiv 2607.19438](https://arxiv.org/abs/2607.19438)).

**Implication for frog.** With 75–80% prefix reuse, a 20K-token turn still has 4–5K new tokens. On an M4 Max that is about 5–8 s TTFT per turn; on a 3090 it is about 2 s. Over 30–60 turns per task, prefill alone costs minutes on a Mac.

---

## 2. Frontier table

| Technique / hardware | Measured result | Model / workload / HW | Source (date) |
|---|---|---|---|
| **SuffixDecoding** (model-free suffix trees over prompt + past outputs) | Up to 5.3x on AgenticSQL; 2.8x faster than EAGLE-2/3 on agentic tasks | SWE-Bench agent traces, Text-to-SQL | [arXiv 2411.04975, NeurIPS'25 spotlight](https://arxiv.org/abs/2411.04975) |
| SuffixDecoding in Arctic Inference + vLLM | About 4x average on SWE-Bench agent tasks; 1.8–4.5x per subtask; up to 2.8x on open chat | OpenHands coding agent | [Snowflake eng blog](https://www.snowflake.com/en/engineering-blog/suffixdecoding-arctic-inference-vllm/) (2025) **[vendor, but the method is peer-reviewed]** |
| EAGLE-3 | 4.1–6.5x at T=0 on academic benchmarks; about 1.4x over EAGLE-2 at bs=1 | Llama-3.1-8B, 3.3-70B | [Red Hat, Jul 2025](https://developers.redhat.com/articles/2025/07/01/fly-eagle3-fly-faster-inference-vllm-speculative-decoding) |
| EAGLE 3.1 | **2.03x** per-user throughput at concurrency 1 on the SPEED-Bench **coding** set (1.71x at C=4) | Kimi-K2.6-NVFP4, GB200 TP4 | [vLLM blog, 2026-05-26](https://vllm.ai/blog/2026-05-26-eagle-3-1) |
| **EAGLE-3 on Apple Silicon (MLX)** | **1.05x** (113.7 → 118.9 tok/s), 34% acceptance | Llama-3.1-8B 4-bit, M3 Ultra | [mlx-lm discussion #890, 2026-02-14](https://github.com/ml-explore/mlx-lm/discussions/890) |
| **DFlash** (block-diffusion drafter, one pass per block) | 5.46x Qwen3-8B, 5.52x Qwen3-4B, 3.91x gpt-oss-20B (average, lossless) | Math/code benchmarks, datacenter GPU | [arXiv 2602.06036, Feb 2026](https://arxiv.org/abs/2602.06036); [repo](https://github.com/z-lab/dflash) (has an MLX backend and a Qwen3-8B checkpoint) **[numbers from search snippet; PDF not parsed]** |
| DFlash on a consumer GPU | 46.9 tok/s at 100 output tokens, **collapsing to 30 tok/s at 1–2K output tokens** (baseline 29) | Qwen3.6-27B Q4_K_M, RTX 3090 Ti, llama.cpp fork | [ianlpaterson.com, May 2026](https://ianlpaterson.com/blog/3090-ti-qwen-speedup-dflash-mtp/) |
| **Native MTP heads** (llama.cpp) | 39–49 tok/s vs 29 baseline, stable across output length; needs `--spec-draft-p-min 0.75` | Same setup | same |
| Native MTP, n-max 2 | 41.6 → 66.4 tok/s (**+59.8%**). Output was *not* byte-identical to greedy (92–100% of 1.6K-token outputs diverged) | Qwen3.8-27B, RTX 3090, llama.cpp | [hackmd thc1006, 2026-08-29](https://hackmd.io/@thc1006/qwen3-8-27b-speculative-decoding-rtx-3090) |
| FailFast (dLLM drafter, adaptive length, up to 70 tokens accepted) | Up to 4.9x over vanilla; 1.7x over EAGLE-3 | Various | [arXiv 2512.20573, Dec 2025](https://arxiv.org/abs/2512.20573) |
| Cursor "speculative edits" | About 1000 tok/s, about 13x over vanilla Llama-3-70B | Code-edit apply | [Cursor blog, 2024](https://cursor.com/blog/instant-apply) |
| Morph Fast Apply | 10,500 tok/s, 7B merge model | Code-edit apply | [Morph](https://www.morphllm.com/blog/morph-gets-faster) **[vendor]** |
| Layer-skip self-speculation | LayerSkip up to 2.16x (needs training); SWIFT 1.3–1.6x (training-free); ConfLayers about 1.4x | Llama family | [LayerSkip](https://arxiv.org/abs/2404.16710), [SWIFT](https://arxiv.org/pdf/2410.06916), [ConfLayers, Apr 2026](https://arxiv.org/html/2604.14612v1) |
| **Megakernel** (whole forward pass in one persistent kernel) | 78% of H100 bandwidth vs about 50% for vLLM/SGLang; 1.5x over SGLang and 2.5x over vLLM on H100; 3.5x over vLLM on B200 | Llama-3.2-1B, bs=1 | [Hazy, May 2025](https://hazyresearch.stanford.edu/blog/2025-05-27-no-bubbles) |
| Mirage Persistent Kernel (compiler that emits megakernels) | 1.2–6.7x latency reduction | HF models, multi-GPU | [Zhihao Jia, 2025](https://zhihaojia.medium.com/compiling-llms-into-a-megakernel-a-path-to-low-latency-inference-cf7840913c17); [repo](https://github.com/mirage-project/mirage/tree/mpk) |
| BaseRT (Metal 4 tensor API) | Prefill 3.9x over MLX (6.4x over llama.cpp); decode 1.33x over MLX | 15 configs, <1B–35B, M5 Pro | [arXiv 2607.19438, Jul 2026](https://arxiv.org/abs/2607.19438) |
| M5 Neural Accelerators | TTFT 4.06x vs M4; decode 1.19x | Qwen3-14B-4bit | [Apple MLR](https://machinelearning.apple.com/research/exploring-llms-mlx-m5) |
| NVFP4 vs Q4_K_M | About 1.45x from the quant swap; about 1.9x with MTP (24 → 45 tok/s) | Qwen3.6-27B, RTX 5090 laptop, 160K ctx | [boredconsultant, Jul 2026](https://boredconsultant.com/2026/07/18/45-tok-s-on-a-Laptop-Getting-Qwen3-6-27B-s-NVFP4-Quants-Running-on-llama-cpp/) **[blog]**. Blackwell only; the 3090 has no FP4 tensor cores |
| TurboQuant KV (3–4 bit, rotation + lookup table) | ≥6x KV memory reduction; identical LongBench at 3.5 bits; up to 8x faster attention logits (vs fp32 keys, H100) | Llama-3.1-8B | [ICLR 2026 coverage](https://themlsurgeon.substack.com/p/turboquant-what-3-bit-kv-caches-actually); [llama.cpp discussion](https://github.com/ggml-org/llama.cpp/discussions/20969) |
| Hybrid linear attention | Decode 4x at 4K and 10x at 32K+; prefill 7–10x | Qwen3-Next-80B-A3B vs Qwen3-32B | [Qwen](https://huggingface.co/Qwen/Qwen3-Next-80B-A3B-Instruct) **[vendor]** |
| SGLang HiCache (radix KV tree to host memory/storage) | Up to 6x throughput, up to 80% TTFT reduction | Multi-turn serving | [LMSYS, Sep 2025](https://www.lmsys.org/blog/2025-09-10-sglang-hicache/) |
| LMCache | Coding-agent session: 56% lower average TTFT, hit rate 40% → 80%; 128K prompt TTFT about 11 s → 1.5 s from disk | vLLM, H100/MI300X | [LMCache blog, May 2026](https://blog.lmcache.ai/en/2026/05/12/benchmarking-lmcache-for-multi-turn-agentic-workloads-on-amd-mi300x/); [Spheron](https://www.spheron.network/blog/nvme-kv-cache-offloading-llm-inference/) |
| XGrammar-2 | Near-zero per-token mask overhead; 6x faster tool-call grammar compile; cross-grammar cache | Tool calling | [MLC blog, 2026-05-04](https://blog.mlc.ai/2026/05/04/xgrammar-2-fast-customizable-structured-generation); [arXiv 2601.04426](https://arxiv.org/abs/2601.04426) |
| **PASTE** (speculative tool execution) | −48.5% average task time; tool latency 1.8x better; 93.8% hit rate with 27.8% top-1 | SWE-bench and others | [arXiv 2603.18897, Mar 2026](https://arxiv.org/html/2603.18897v1) |
| Speculative Actions | Up to 55% next-action accuracy, up to 20% latency reduction | Games, e-commerce, web search (not coding) | [arXiv 2510.04371, ICLR 2026](https://arxiv.org/abs/2510.04371) |
| Speculate with Memory | 19–39% better action prediction; up to 2.5x on observation prediction | 6 agent benchmarks | [arXiv 2607.12236, Jul 2026](https://arxiv.org/abs/2607.12236) |
| Parallel tool calls (W&D) | 3 tools per turn: 45.7 → 23.8 turns, **−40.6% wall-clock** | Deep-research agent | [arXiv 2602.07359, Feb 2026](https://arxiv.org/pdf/2602.07359) |
| Cerebras WSE | Qwen3-Coder-480B about 2,000 tok/s; gpt-oss-120B about 3,000; TTFT reported as multi-second | Cloud | [Cerebras](https://www.cerebras.ai/blog/qwen3-coder-480b-is-live-on-cerebras) **[vendor]**; [TTFT complaints](https://biggo.com/news/202508030143_Qwen3_Coder_480B_Speed_vs_Latency_Trade-offs) |
| Nvidia Groq 3 LPX | 3,400 tok/s (Artificial Analysis benchmark per Nvidia); 256 LPUs/rack, 128 GB SRAM | GTC 2026; racks online in 2026 | [CNBC, 2026-08-24](https://www.cnbc.com/2026/08/24/nvidia-says-groq-racks-will-be-online-this-year-after-20-billion-deal.html); [Techzine](https://www.techzine.eu/news/infrastructure/139653/nvidias-groq-3-lpu-targets-agentic-ai-inference-at-gtc-2026/) **[vendor]** |
| Taalas HC1 (weights hard-wired in silicon) | About 17,000 tok/s per user, Llama-3.1-8B only (LoRA supported). HC2 planned at 20B params with FP4. AMD agreed to acquire, 2026-08-06 | Single model | [CNX, Feb 2026](https://www.cnx-software.com/2026/02/22/taalas-hc1-hardwired-llama-3-1-8b-ai-accelerator-delivers-up-to-17000-tokens-s/); [TechTimes, Aug 2026](https://www.techtimes.com/articles/323482/20260807/amd-buys-taalas-hardwire-ai-models-silicon-bypassing-gpu-memory-wall.htm) **[vendor]** |
| Etched Sohu | ">500K tok/s on Llama-70B per 8-chip server", aggregate, **not independently verified as of Jun 2026** | | [Fastio review](https://fast.io/resources/etched-ai-review-2026/) **[vendor, unverified]** |
| Inception Mercury 2 / 2.5 (diffusion LLM) | 1,009 tok/s (Feb 2026, Blackwell); 1,107 tok/s (Sep 2026) | Proprietary, API only | [NYU RITS](https://rits.shanghai.nyu.edu/ai/inception-launches-mercury-2-diffusion-powered-reasoning-at-1000-tokens-per-second/); [runtimewire](https://runtimewire.com/article/inception-mercury-2-5-diffusion-language-model-launch) **[vendor]** |
| Gemini Diffusion | 1,479 tok/s; HumanEval 89.6 vs 90.2 for its AR counterpart | Experimental, I/O May 2025 | [dailydoseofds summary](https://www.dailydoseofds.com/diffusion-models-part-2/) **[vendor]** |
| Open dLLMs (LLaDA / Dream + distillation) | TAD-LLaDA 339–452 tok/s (10.9–14.5x over base); TAD-Dream 206–288 tok/s | Datacenter GPU, code/math | [arXiv 2605.09536](https://arxiv.org/pdf/2605.09536) |
| ANE (ANEMLL) | 47–62 tok/s on 1B; about 9 tok/s on 8B vs 93+ tok/s on GPU with MLX | Apple Neural Engine | [InsiderLLM](https://insiderllm.com/guides/apple-neural-engine-llm-inference/) **[blog]** |
| BitNet b1.58 | 2B4T model only; 100B-param speed demo was a synthetic model at 5–7 tok/s on CPU | CPU | [microsoft/BitNet](https://github.com/microsoft/BitNet) |

---

## 3. Speculative decoding: what works at batch 1 on your hardware

**Why it works.** At batch 1, a forward pass over k draft tokens reads the weights once. On a 3090, verifying 4–16 tokens costs close to one token, until compute or attention cost takes over. Speedup ≈ (accepted tokens + 1) / (1 + drafting cost + verification overhead).

**CUDA / 3090: verification is nearly free, so aggressive drafting pays.** Native MTP gave +33–60% on Qwen3.x-27B in llama.cpp. DFlash shows 5x+ in the paper, but in the llama.cpp fork it collapsed on long outputs because the drafter's KV competes for bandwidth.

**Metal / Apple Silicon: verification is not free.** The MLX EAGLE-3 prototype measured a per-token activation cost of 0.5–1 ms, so 34% acceptance yielded 1.05x. Two causes:
1. Apple's GPU has far less compute per byte of bandwidth than a 3090, so a k-token verify pass becomes compute-bound quickly.
2. MLX lacked tree attention: its KV cache tracks position with a single integer.

On Mac, only drafts with very high acceptance pay. Suffix/prompt-lookup copies are exactly that kind of draft.

**Why agentic coding fits.** Agent outputs copy heavily: file contents into edits, paths, identifiers, JSON keys, repeated tool-call scaffolding. SuffixDecoding adapts draft length to match confidence, drafting up to dozens of tokens when a long suffix match exists and nothing otherwise. This is how it beats EAGLE on agent traces. Your prompt-lookup result (1.6x on small-model logs) is the naive floor. A suffix tree over session history with adaptive length, plus a tree of candidate continuations, should do noticeably better.

**Grammar-forced tokens are free drafts.** Inside a tool call, many tokens are fully determined by the grammar (`{"`, key names, `":`, enum values). Jump-forward decoding (SGLang, 2024) appends them without a forward pass. With XGrammar-style masks, these become draft tokens with 100% acceptance.

---

## 4. New paradigms: diffusion LLMs

- **Hosted speed is real, and the numbers are vendor figures.** Mercury 2/2.5 reach about 1–1.1K tok/s and Gemini Diffusion about 1.5K tok/s. Both run on datacenter GPUs with batched serving. Mercury's quality sits in the "fast small model" class, not frontier.
- **Locally, open dLLMs are not yet a win.** LLaDA and Dream need many denoising steps. Distilled variants (d3LLM, TAD, LLaDA2.1 token editing) reach hundreds of tok/s on datacenter GPUs, but their decode is compute-bound across the full block. On a Mac, which has little compute, that cancels much of the advantage. One 2026 Medium post is titled "Diffusion LLMs Claim 1,000 Tokens a Second. I Got 1.05" (paywalled, not read).
- **The practical hybrid is a diffusion *drafter* with an AR verifier** (DFlash, FailFast, DFlare). This keeps the target model's quality, since output stays lossless under the target's verification, and uses parallel drafting. It is the most plausible way diffusion helps tang in 2026. Caveat: it only works where verification is cheap (CUDA), and the drafter's KV cost matters at long outputs.

---

## 5. Model-side levers, ranked for frog

1. **Architecture: hybrid-attention MoE** (Qwen3.5/3.6-35B-A3B class). This gives 2–3x the decode ceiling of a dense 8B at better quality, and KV growth is about 4x slower. Cost for tang: Gated DeltaNet kernels. Also, prefix caching now needs *recurrent-state checkpoints* at reusable boundaries, because you cannot truncate a linear-attention state to an arbitrary prefix. This is the non-obvious engineering tax.
2. **KV quantization** (int8 now; 4-bit or TurboQuant-style 3–4 bit later). At 20K context this lifts the 3090 ceiling from about 130 to about 165 tok/s with int8 KV, and toward about 185 with 4-bit [calc]. It also doubles or quadruples how many sessions can stay pinned.
3. **Weight quantization.** 4-bit is the sweet spot. On consumer Blackwell, NVFP4 is about 1.45x faster than Q4_K_M in llama.cpp, mostly from kernel efficiency. The 3090 has no FP4 path, so stay on int4 with good kernels. 2–3-bit quants of coding models lose measurable quality. BitNet has no competitive coding model.
4. **Early exit / layer skip.** Training-free versions give 1.3–1.6x. They are dominated by MTP and suffix drafting for this workload. Skip.
5. **Distillation to a small fast coder.** Use it for apply/merge (the Morph/Cursor pattern), not for the main agent.

---

## 6. Systems-side levers

- **Continuous batching** does not matter for one user, with one exception: *parallel subagents / parallel branches*. Batch 2–8 decode on memory-bound hardware costs roughly the same per step as batch 1. The 3090 is reported at about 1,000 tok/s aggregate over 64 streams (search snippet, Aug 2026). **Parallel work is almost free throughput** for fan-out subtasks, SPORK-style speculative forks ([arXiv 2607.03333](https://arxiv.org/pdf/2607.03333)), and best-of-n.
- **Radix/prefix KV reuse** is already done in session-pinned form. The next steps are cross-session sharing (system prompt, tool schemas, repo map) and disk tiering. The key numbers: Qwen3-8B KV for 20K tokens is 2.9 GB fp16 (1.5 GB int8). A Mac's internal SSD reads at 5–7 GB/s, so a reload takes about 0.3–0.6 s versus 20–40 s to re-prefill on an M4 Max. **That is about a 50x TTFT cut on a cold resume** [calc].
- **Megakernels / persistent kernels.** On CUDA this is a proven path: 78% bandwidth utilization at bs=1, and it compiles automatically via Mirage MPK. Gains shrink as the model grows, because 8B kernels are individually larger than 1B kernels. Expect 1.3–1.7x at 8B from 45% utilization [estimate]. On Metal there is no cooperative-groups grid sync and no forward-progress guarantee across threadgroups, so a true persistent kernel is risky. The practical Metal version: one command buffer per token, fewer and fatter fused kernels, indirect command buffers, no CPU round-trips. At about 10 ms per token with about 300+ dispatches, launch and encoding overhead can be 10–20% [estimate].
- **Constrained decoding.** XGrammar-2 overhead is near zero. The upside is using it as free drafting (section 3).
- **Streaming tool-call parsing.** Parse arguments incrementally and dispatch read-only tools the moment their arguments close, overlapping with the rest of the generation (multiple calls, closing text). PASTE ([v3 title: "Parallelizing Tool Execution and LLM Generation for Low-Latency Agent Serving"](https://arxiv.org/html/2603.18897v3)) is built around this.

---

## 7. Agent-level speed: model time vs tool time

- "Agentic AI Workload Characteristics" ([arXiv 2605.26297](https://arxiv.org/abs/2605.26297), May 2026): LLM inference is **71–98%** of runtime; tools are 2–29% (17.7% on SWE-bench Pro). With context caching, execution is *decode-dominated*.
- PASTE ([arXiv 2603.18897](https://arxiv.org/html/2603.18897v1)): tools are **35–61%** of request time, **60% for coding**. That setup has heavy test and containers.
- SPORK: tools are 16% (tau2), 19% (GAIA), 37% (BrowseComp); only 15–25% of tool calls can run in parallel with their predecessor.
- TraceLab ([arXiv 2606.30560](https://arxiv.org/abs/2606.30560), Jun 2026): 4,300 coding sessions, 350K LLM steps. The pattern is long contexts with short outputs, prefix hit rates that are high but imperfect, and heavy-tailed tool latency. It recommends "append-length-aware prefill" and KV management around human-paced gaps.

**Reading these for frog.** Local inference at about 90 tok/s is 10–30x slower than frontier cloud APIs. That pushes frog's split toward LLM-dominated: decode for outputs, plus uncached-suffix prefill on Mac. So per-token speed matters more for frog than for a cloud agent. But step count multiplies everything:
- Parallel tool calls (−40% wall-clock in W&D) and speculative read-only tool execution (−20% to −48%) are *orthogonal* to token speed.
- They also cut prefill, because fewer turns means fewer uncached suffixes.

`scripts/gateway_stats.py` is presumably where to measure this split from the logs; I did not open it.

---

## 8. Hardware frontier: what it means for frog Pro

- **Available now for rent:** Cerebras (1.5–3K tok/s on big open coders; TTFT has historically been the weak spot, and that matters for agents with many short turns), Groq/Nvidia LPX (about 1.5–3.4K), SambaNova (hundreds to low thousands; no fresh 2026 data found), Mercury 2.5 (about 1.1K, own model).
- **Announced:** Taalas HC2 (20B-class, FP4, "summer 2026"; now under AMD), Etched Sohu (shipping claims, unverified), Groq 3 racks paired with Vera Rubin in late 2026. d-Matrix: I found no 2026 per-user numbers; treat it as batch-throughput-oriented.
- **Frog Pro options:**
  - (a) Resell a speed provider (Cerebras/Groq) for a "turbo" tier. Fastest path to about 1–2K tok/s, but no control over prefix KV pinning.
  - (b) Self-host on B200/H200 with SGLang or vLLM, NVFP4, EAGLE 3.1 + Arctic suffix decoding, and session-affinity routing with HiCache/LMCache. Realistic per-user decode is about 300–600 tok/s on an A3B-class MoE, and it keeps session KV hot. For agent tasks, (b) with near-100% prefix hits may beat (a) end-to-end despite lower tok/s, because TTFT dominates short-output turns.

---

## 9. Ranked bets for tang/frog (months, not years)

Gains are relative to today's tang unless stated. "Smallest experiment" is meant to be a day or two of work.

### #1. Agent-aware speculative decoding: suffix tree + grammar-forced tokens + native MTP fallback
- **Expected gain:** 1.8–3x decode on agent turns on a 3090. Copies, edits and JSON get most of it; novel prose about 1.3–1.6x from MTP. On Mac, 1.3–2x, only from high-acceptance suffix drafts.
- **Components:**
  1. A per-session suffix tree (SuffixDecoding-style) indexing prompt, prior outputs, *and file contents the agent read*, with adaptive draft length and multi-candidate tree drafts.
  2. Grammar-forced tokens appended free inside tool calls.
  3. When the tree has no match: MTP heads (Qwen3.5+/GLM/DeepSeek ship them) on CUDA, or nothing on Metal.
  4. Tree verification (tree attention mask) in tang's attention kernel.
- **Depends on:** a cheap multi-token verify path. On Metal, measure the cost curve first.
- **Risk:** low on CUDA. Medium on Metal: verify cost may cap it, as with the MLX EAGLE 1.05x result.
- **Smallest experiment:**
  1. Offline: replay frog logs through a suffix-tree drafter vs current prompt lookup, and plot the accepted-length histogram (no GPU needed).
  2. On both backends, time a forward pass at k = 1, 2, 4, 8, 16, 32 tokens at 2K and 20K context.
  3. Multiply the two to predict speedup per backend before building anything.

### #2. KV persistence across turns and sessions, disk-backed, with shared prefixes
- **Expected gain:** TTFT on a cold resume, a subagent spawn, or an app restart drops from tens of seconds to under 1 s on Mac (about 50x) [calc]. Steady-state per-turn TTFT improves if the shared prefix (system prompt, tools, repo map) is deduplicated across sessions.
- **Components:**
  1. A content-addressed KV block store (radix/hashed blocks) spanning sessions.
  2. Spill to SSD with mmap/zero-copy into unified memory on Mac (no PCIe copy; wire straight into MTLBuffers).
  3. int8 KV to halve bytes on disk and in memory.
  4. For hybrid models: recurrent-state checkpoints at message boundaries.
- **Depends on:** a stable prompt layout (append-only; no timestamps or reordering in the prefix). The logs' 75–80% reuse suggests it is mostly stable already.
- **Risk:** low to medium (invalidation bugs, disk usage). Very high product value on Mac.
- **Smallest experiment:** serialize a 20K-token session KV to disk, kill the process, then time reload + first token against re-prefill on an M-series Mac and on the 3090.

### #3. Speculative and streaming tool execution
- **Expected gain:** 15–45% of task wall-clock, independent of token speed (PASTE −48.5% on its setup, Speculative Actions up to −20%, W&D parallel calls −40%).
- **Components:**
  1. Streaming JSON parse; dispatch each read-only call (read/grep/glob/ls) as soon as its arguments close.
  2. While the model decodes, prefetch predicted next reads: files named in the output so far, `git diff`, test files that match edited files.
  3. Speculatively start `cargo check` / tests on edited worktrees, in a sandbox, and discard on mismatch.
  4. Prompt and train toward parallel tool calls.
- **Depends on:** tool side-effect classification. Only read-only or sandboxed calls should run speculatively.
- **Risk:** low for read-only tools; medium for mutating tools (keep them off).
- **Smallest experiment:** from frog logs, compute (a) the fraction of wall-clock in tools, (b) the idle gaps between a tool call's arguments closing and generation ending, and (c) how often the next call is predictable from the current output (file mentioned → read). That gives an upper bound in an afternoon.

### #4. CUDA decode megakernel (or near-megakernel) for the 3090
- **Expected gain:** 1.3–1.7x on 8B dense at short context, taking bandwidth utilization from about 45% to 70–78%. For A3B MoE the upside is bigger, since MoE engines sit at 35–40% of ceiling.
- **Components:** a persistent kernel with an on-GPU instruction scheduler (Hazy style), or MPK-generated code as a reference, fused RMSNorm+QKV+RoPE, fused attention+O-proj, and overlapping the next layer's weight loads with the current compute. Start with CUDA Graphs + fusion as a stepping stone and measure what remains.
- **Depends on:** nsys/ncu profiling to confirm the gap is bubbles and launch overhead rather than dequant ALU cost. 4-bit dequant on Ampere can be ALU-bound.
- **Risk:** medium, a lot of engineering; gains shrink with KV-heavy long contexts.
- **Smallest experiment:** measure achieved DRAM bandwidth per kernel with ncu for one decode step, then sum idle gaps between kernels. If the gaps are over 20% of step time, the megakernel pays.

### #5. Metal "one command buffer per token" plus M5 tensor-API prefill
- **Expected gain:** decode 1.1–1.3x (BaseRT reports 1.33x over MLX on M5). Prefill on M5 hardware 3–4x (Apple and BaseRT), which directly cuts per-turn TTFT, the Mac's biggest cost.
- **Depends on:** Metal 4 tensor APIs (M5 only for the Neural Accelerators). Older Macs only get the dispatch-overhead part.
- **Risk:** low to medium. Do not attempt a true persistent kernel on Metal (no grid-sync guarantees).
- **Smallest experiment:** Metal System Trace of one decode step: count dispatches and GPU idle time. Separately, port one GEMM to the Metal 4 tensor API and benchmark prefill on an M5.

### #6. MTP / DFlash-style parallel drafting as the novel-text drafter (CUDA first)
- **Expected gain:** +30–60% on novel text (measured with MTP on a 3090); higher with DFlash on short outputs.
- **Depends on:** the model shipping MTP heads, or an available DFlash checkpoint (Qwen3-8B, Qwen3-Coder-30B-A3B, and Qwen3.5 checkpoints exist).
- **Risk:** medium. The drafter's KV bandwidth can erase gains on long outputs (seen with DFlash in llama.cpp). Also, MTP may not reproduce greedy output byte for byte (the 3090 study).
- **Smallest experiment:** run the z-lab DFlash MLX backend and llama.cpp MTP on frog-like prompts, and record tok/s at 100/500/2000 output tokens.

### #7. Move the default local model to a hybrid-attention A3B MoE, with int8 KV
- **Expected gain:** 2–3x decode ceiling at equal or better quality; context-length slowdown about 4x smaller.
- **Depends on:** Gated DeltaNet kernels in tang, recurrent-state prefix checkpoints (ties to #2), MoE kernels.
- **Risk:** medium to high engineering. The memory footprint (about 17–20 GB at 4-bit) rules out 16 GB Macs.
- **Smallest experiment:** run Qwen3.5-35B-A3B in MLX / llama.cpp on the same frog tasks. Compare wall-clock and pass rate against Qwen3-8B.

### #8. Free-batch parallelism: subagents, forks and best-of-n
- **Expected gain:** 2–4 parallel streams at about 1x per-stream cost on memory-bound hardware. It turns "more steps" into "wider steps".
- **Depends on:** batched decode in tang with a paged KV cache, and harness support for fan-out.
- **Risk:** low for the engine side; the harness design is where the risk is.
- **Smallest experiment:** time tang decode at bs = 1, 2, 4, 8 on the 3090 and on a Mac.

### Deprioritized
- EAGLE-3 heads on Mac: 1.05x measured.
- ANE decode: slower than the GPU.
- BitNet: no competitive coding model exists.
- Open dLLMs as the main model locally.

---

## 10. Hype, or doesn't transfer to batch-1 consumer hardware

- **Headline tok/s from specialized silicon** (Taalas 17K, Etched 500K, Groq 3.4K, Cerebras 2–3K). They are real for cloud serving, mostly vendor-measured, single-model or aggregate, and irrelevant locally. Etched is unverified; Taalas is one model per chip.
- **Diffusion LLMs at "1000+ tok/s".** These are hosted and batched on Blackwell/H100. Open dLLMs locally are compute-bound, and Macs are compute-poor. Treat diffusion as a *drafter* idea.
- **Academic EAGLE numbers of 4–6x.** They come from fp16 models on A100/H100 on chat benchmarks at T=0. On 4-bit models on Mac the result was 1.05x. On real coding at concurrency 1 on GB200 it was 2.03x. Always ask: what precision, what hardware, what temperature, what workload.
- **Megakernel "3.5x".** That was against vLLM on a 1B model. Against a tuned engine on an 8B model, expect 1.3–1.7x.
- **KV-quant "8x attention speedup".** That compares against fp32 keys. Against fp16, the decode gain is proportional to the KV share of bytes read, which is large only at long context.
- **The ANE for LLMs.** It is power-efficient but about 10x slower than the GPU on 8B.
- **Continuous-batching throughput numbers.** They say nothing about single-user latency, except for the parallel-subagent use in bet #8.
- **Speculative Actions accuracy numbers.** They come from games and e-commerce; coding-agent results (PASTE) are more relevant.

---

## Appendix: numbers to re-verify before quoting externally

- M5 Ultra bandwidth "1.2 TB/s" (search snippet of the Apple newsroom page).
- DFlash per-model speedups (search snippet; PDF not parsed). Check the [paper](https://arxiv.org/abs/2602.06036).
- MLX Qwen3-8B on M4 Max "62 tok/s" (likely a bad benchmark).
- RTX 3090 tensor TFLOPS (spec sheet from memory; FP16-accumulate vs FP32-accumulate rates differ on GeForce).
- Everything marked [vendor] for Taalas, Etched, Groq, Cerebras and Inception.

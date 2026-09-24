# Decentralized inference on consumer/idle GPUs: the frontier, as of 2026-09-23

Scope: can people pool idle consumer GPUs (a 3090, a Mac) and get 100B–1T MoE open models (DeepSeek / Kimi / GLM / Qwen class) free or cheap, for solo developers running agentic coding loops? This covers what has shipped, what the physics allows, and what kiln should build.

Legend: **[V]** means I checked it against a primary source (paper, project docs, vendor page). **[S]** means a secondary source (blog or aggregator). **[M]** means a marketing or self-reported claim nobody has checked independently. **[calc]** means my own back-of-envelope math, with the assumptions shown.

---

## TL;DR

1. **Two very different things get called "decentralized inference."** The first is datacenter GPUs sold through a token-subsidized marketplace (Chutes, AkashML, io.net). That works: full-size DeepSeek/Kimi/GLM at normal speeds and 40–70% below Together's prices. But the discount comes from token emissions, not idle consumer hardware. The second is actually pooling consumer GPUs across the internet (Petals, Prime Intellect's pipeline inference, Parallax, public Mesh LLM). That works for **batch throughput** (for example, synthetic data). For interactive use it stalls at **2–6 tok/s** on 70B+ models, and nobody has made it cheap.
2. **Centralized open-model tokens are almost free now.** DeepSeek V4 Flash (284B/13B active) is **$0.054 in / $0.242 out per M tokens** on OpenRouter ([OpenRouter, Jun 2026](https://openrouter.ai/blog/insights/the-open-weight-models-that-matter-june-2026/)) [V]. An hour of a 3090's electricity (~$0.06–0.08) buys roughly **0.5–1M tokens** of a frontier-class open model from a datacenter [calc]. A WAN-pooled consumer network running a 671B model costs about **$100+/M output tokens in electricity alone** [calc, below]. That is a 100–500× gap, and better software doesn't close it.
3. **Payment for idle 3090s is already at the electricity floor.** Salad cut 3090 earnings to **$0.063–0.102/hr** on 2026-09-12 ([Salad](https://blog.salad.com/earning-rate-changes-september-2026/)) [V]. A 3090 system at load draws ~$0.06–0.08/hr in US electricity [calc]. "Contribute your GPU, get big models free" has only worked where someone else pays: AI Horde through volunteers with small models, Chutes through TAO emissions (22–40× revenue).
4. **Privacy with untrusted consumer nodes is unsolved.** Consumer GPUs have no confidential computing (H100/H200/B200 and RTX PRO 6000 **Server Edition** only). Layer-splitting doesn't hide prompts either: activation inversion recovers **88–98%** of tokens.
5. **For kiln:** build the **own-devices + trusted-friends pool**. Use request-level routing to whichever node holds the whole model, and split layers or experts only over LAN/Thunderbolt. Treat the public "contribute a 3090, get Kimi free" network as a trap for now. The smallest useful experiment costs nothing to run: inject the latency profile the pool would have into kiln's existing hosted-provider path, then see whether agent tasks still finish and whether you'd tolerate it.

---

## 1. Prior art: where each project landed

| Project | What it actually is | Models actually served | Measured speed | Price | Status (2026) |
|---|---|---|---|---|---|
| **Petals** (BigScience/HF, 2022) | BitTorrent-style layer pipeline across volunteer GPUs over the internet | Llama 3.1 405B, Mixtral 8x22B, Falcon 180B, BLOOM 176B | **≤6 tok/s Llama-2-70B, ≤4 tok/s Falcon-180B**, single batch ([petals.dev](https://petals.dev/), [paper](https://arxiv.org/abs/2209.01188)) [V] | Free (volunteer) | Functional but dormant. "Limited recent GitHub activity" per the HN revisit ([explainx, 2026-07-23](https://explainx.ai/blog/petals-distributed-llm-inference-revisited-july-2026)) [S]. Bandwidth is the stated bottleneck. |
| **Exo** (exo labs) | LAN / Thunderbolt cluster of your own devices | DeepSeek V3.1 671B, Kimi K2 Thinking 1T | **32.5 tok/s DeepSeek V3.1, ~28–32 tok/s Kimi K2 Thinking** on 4× M3 Ultra Mac Studio (1.5 TB) with RDMA over TB5. llama.cpp over TCP: 14.6 tok/s ([Jeff Geerling, Dec 2025](https://www.jeffgeerling.com/blog/2025/15-tb-vram-on-mac-studio-rdma-over-thunderbolt-5)) [V]. Earlier: **5.37 tok/s** DeepSeek V3 on 8× M4 Pro Mac mini over TCP ([exo blog, Dec 2024](https://blog.exolabs.net/day-2/)) [V] | Hardware cost (~$40k+ for 4 Studios) | Alive. The best "big model, private" point, but only over sub-10µs RDMA links (TB5 RDMA ~5–9µs vs ~300µs TCP). |
| **Prime Intellect** | Pipeline-parallel inference over the public internet (PRIME-VLLM, PRIME-IROH), verified by TOPLOC | Used to generate SYNTHETIC-2 (4M reasoning traces). **1,250+ GPUs joined in 3 days**, a mix of H100s and consumer 3090/4090s ([Jun 2025](https://www.primeintellect.ai/blog/synthetic-2)) [V] | Their own analysis: a 2-stage pipeline bottlenecked by the network gets **~5 tok/s** vs 121 tok/s single-H100 for Llama-2-13B. "Increasing the number of stages doesn't improve throughput." No fault tolerance implemented ([Apr 2025](https://www.primeintellect.ai/blog/inference)) [V] | n/a (batch jobs) | Pivoted. INTELLECT-3 (106B) trained on a **centralized 512-GPU cluster** ([report, Dec 2025](https://arxiv.org/html/2512.16144v1); [implicator](https://www.implicator.ai/prime-intellects-intellect-3-open-source-ambition-meets-centralized-reality/)) [V/S]. No public interactive inference network. Their product is now "Lab" (hosted training and eval). |
| **Nous Research – Psyche** | Decentralized *training* on Solana (DisTrO). Inference is a planned "phase 2" | Hermes 4.3, post-trained on Psyche (Dec 2025) | n/a for inference | n/a | Training only. The inference layer isn't shipped ([Nous](https://nousresearch.com/nous-psyche)) [V]. |
| **Bittensor SN64 – Chutes** | Permissionless miners. In practice datacenter H100/H200, TEE mode on Intel TDX + NVIDIA CC | DeepSeek V3.x, Kimi, GLM, Qwen, and others at full size | Normal datacenter speeds | DeepSeek V3.1 **$0.27/$1.00** vs Together $0.60/$1.70 ([ownyourmind, Mar 2026](https://ownyourmind.ai/tokenomics/chutes-bittensor-revenue-machine/)) [S] | Largest "decentralized" inference by volume, but **subsidized 22–40× revenue** by TAO emissions. Verified revenue $1.3–2.4M/yr vs a claimed ~$10M ARR [S/M]. Self-reported 160B tok/day vs **6.8B tok/day verifiable on OpenRouter** [S]. Unsubsidized break-even ≈ $1.41/M [S]. Feb 2026: subscriptions capped at 5× PAYG value because heavy users were extracting **56–324× their subscription value** ([Chutes, 2026-02-27](https://chutes.ai/news/community-announcement-february)) [V]. |
| **Inference.net (ex-Kuzco)** | Request-level routing to heterogeneous GPUs, laptops up to Tier-3 DCs. LOGIC log-prob verification | Models that fit on one worker | ~5,200 devices, ~4,400 req/min at devnet ([docs](https://docs.devnet.inference.net/)) [V/M] | n/a | $11.8M seed (a16z CSX, Multicoin), Oct 2025. LOGIC is the useful artifact ([blog](https://inference.net/blog/logic/)) [V]. |
| **Parallax** (Gradient) | Pipeline sharding across heterogeneous NVIDIA + Apple Silicon, paged KV + continuous batching, DP scheduler | Qwen3-32B in the paper. README claims Qwen2.5-72B and larger | Paper: **5×5090 + 2×4090 across DCs at ~10 ms RTT**. Up to 3.6× throughput, 3.2× lower p99 than HexGen (p99 78 ms). **No separate TTFT/ITL reported** ([arXiv 2509.26182, Oct 2025](https://arxiv.org/html/2509.26182)) [V]. "5.3× lower ITL than Petals" is README-only [M] | Free / open source | Alive. Note the 10 ms RTT testbed is far kinder than residential WAN. |
| **Mesh LLM** | Rust + iroh QUIC P2P. Serves locally when the model fits, otherwise "Skippy" contiguous layer stages. Private (invite) and public (Nostr-discovered) meshes | 40+ presets up to 235B | **No published throughput/latency benchmarks** ([GitHub](https://github.com/Mesh-LLM/mesh-llm)) [V] | Free, no credit system | Launched 2026-07-11, ~3.4k stars. Ships coding-agent launchers (`mesh-llm claude`, goose, opencode, pi). **The closest existing thing to what kiln would build.** |
| **AI Horde** | Volunteer workers. Kudos buys queue priority. Kudos are non-sellable | Mostly small/medium text models plus image models | Queue-dependent | Free | Alive for roleplay/art (SillyTavern users). The one working "contribute → get priority" economy, but at small-model scale ([aihorde.net](https://aihorde.net/contribute/workers/)) [V]. |
| **Salad** | Consumer-GPU container cloud (gamers "chop") | Whatever fits on one 24–32 GB card | n/a | 3090 rents ~$0.10–0.25/hr [S] | Alive. It's a GPU rental market, not an inference network. Earnings detailed in §5. |
| **Vast.ai** | P2P GPU rental marketplace (mostly pro hosts) | n/a | n/a | 3090 from ~$0.07–0.27/hr [S] | Alive. Consumer GPUs earn "$0.30–0.60/GPU-hr" **(5090)** at 80% util ([Vast, 2026-05-18](https://vast.ai/article/how-much-money-can-you-earn-renting-out-your-gpu-on-vast-ai)) [M] |
| **Akash / AkashML** | DC-provider marketplace. "Homenode" consumer beta opened Q1 2026 | Open models via AkashML | **1.7B → 10B+ tok/day** by Jul 2026 ([Akash Q1 2026](https://akash.network/blog/akash-network-q1-2026-report/)) [M] | OpenRouter-competitive | Growing. Named users are mostly other crypto-AI projects. Consumer supply is new and unproven. |
| **io.net** | DC + consumer GPU marketplace. IO Intelligence API (25+ models) | DeepSeek, Llama, etc. | n/a | n/a | ~$12.5M annualized revenue [S]. Registered-GPU counts are marketing [M]. |
| **Hyperbolic** | Aggregates "vetted DC partners" | DeepSeek R1 $3/M, Llama 405B $4/M | n/a | H100 $3.19/hr (Aug 2026) [S] | Now effectively a centralized GPU reseller. It moved away from the consumer-GPU pitch. |
| **Apple Private Cloud Compute** | Apple-silicon servers. Stateless, no privileged access, non-targetable, public transparency log ([Apple, 2024-06-10](https://security.apple.com/blog/private-cloud-compute/)) [V] | Apple's own models | n/a | n/a | The gold standard for *privacy architecture*. It depends on owning the hardware and its attestation chain, so it can't be replicated on strangers' 3090s. |

**Pattern:** every project that reached real volume did it with **datacenter GPUs** plus a subsidy (Chutes, Akash, io.net) or by giving up interactivity (Prime Intellect's batch synthetic data). No project serves a 100B+ model interactively from **consumer GPUs over the WAN** at a usable speed and price.

---

## 2. Frontier table

Assumed workload: one agentic-coding request with a large shared prefix (30–100k tokens) plus a few thousand new tokens per turn.

| Approach | Model size / quality | Decode tok/s (single stream) | TTFT at ~50k ctx | $/M tokens | Privacy vs node operator | Reliability | Verification overhead |
|---|---|---|---|---|---|---|---|
| **A. Centralized API** (OpenRouter → DeepSeek V4 Flash / GLM 5.2 / Kimi K2.6) | Frontier open (284B–1T MoE) | **59–84** ([OpenRouter](https://openrouter.ai/blog/insights/the-open-weight-models-that-matter-june-2026/)) | ~1–5 s with prefix cache [est., unverified] | **$0.05–0.45 in / $0.24–3.31 out** [V] | Provider sees everything | High. Provider quality varies (see K2 Vendor Verifier) | None. You trust the provider. The Kimi [K2 Vendor Verifier](https://github.com/MoonshotAI/K2-Vendor-Verifier) found real tool-call accuracy gaps across 12–18 providers |
| **B. Subsidized DC "decentralized"** (Chutes, AkashML) | Same full-size models | Similar to A | Similar to A | 40–70% below Together, **while emissions last** | Chutes TEE: hardware-attested (H100/H200 + TDX) | Medium. Overload episodes drove the Feb 2026 plan changes | TEE attestation, ~2–5% ([NVIDIA CC](https://developer.nvidia.com/blog/announcing-confidential-computing-general-access-on-nvidia-h100-tensor-core-gpus/)) |
| **C. Single box, MoE CPU-offload** (llama.cpp / KTransformers, one 3090 + 192 GB RAM) | 284B/13B DeepSeek V4 Flash | **~9–11** on DDR4-2400; DDR5 expected ~2× ([MindStudio, 2026-08-25](https://www.mindstudio.ai/blog/freetoken-deepseek-v4-flash-single-3090)) [S] | Slow. Prefill is bound by expert reads over PCIe/RAM: **minutes** at 50k [calc, unverified] | Electricity only (~$0.06–0.08/hr) | Total (your box) | Your box | None |
| **D. LAN / Thunderbolt pool of your own devices** (exo 1.0 RDMA, Mesh LLM private) | 671B–1T at native/4-bit | **28–32** (4× M3 Ultra, RDMA TB5) [V]. **~15** over TCP [V] | Seconds (M3 Ultra prefill is the weak spot) | Hardware capex | Total | Good. One node dies = model down | None needed |
| **E. Trusted-friends pool, request-level routing** (whole model on one friend's box, WAN only carries tokens) | Whatever the biggest single box holds (C or D class) | Same as that box, minus nothing | Box TTFT + ~1 RTT | ~Free (reciprocal) | Friend *can* read prompts. Social trust only | Low–medium (home uptime) | None. Trust |
| **F. Public consumer pipeline over WAN** (Petals, PI PRIME-VLLM, Parallax/Mesh public) | 70B–405B dense or 671B MoE across 4–16 cards | **2–6** ([Petals](https://petals.dev/), [PI](https://www.primeintellect.ai/blog/inference)) [V] | **~100 s per stage hop** at 50k ctx over median US upload, without cached prefixes [calc] | **~$100+/M output** in electricity at batch 1 [calc] | **None.** Activations invert to 88–98% of prompt tokens | Poor. Churn kills whole pipelines. PI shipped no fault tolerance | TOPLOC: 5–20% validator cost, ~258 B/32 tokens ([arXiv 2501.16007](https://arxiv.org/abs/2501.16007)) |
| **G. Public consumer network, request-level** (Inference.net, AI Horde, Salad) | ≤ what fits in 24–32 GB (≤~32B dense 4-bit, or ~30B-A3B MoE) | Good (30–100+ on small models) [est.] | Fine | Cheap, but hosted small models are also nearly free | None (plaintext at operator) | Medium (churn handled by retry) | LOGIC: ~250–313 KB per 10k tokens, 10 single-token recomputes ([Inference.net](https://inference.net/blog/logic/)) |
| **H. Cryptographic privacy** (MPC / FHE / zkML) | Small models | Seconds–minutes per token | Unusable | Very high | Strong | n/a | zkML **100–10,000×**, ~2–4 h to prove 50–100 LLM tokens ([Equilibrium, Feb 2025](https://equilibrium.co/writing/state-of-verifiable-inference)) |

**The Pareto frontier for a solo developer today has three points:** A (cheapest and fastest for big models), D (private and big, if you own the hardware), and C (private and big-ish on one GPU, but slow). E is D/C with sharing added. B lies on the frontier only while subsidized. F and G are dominated for this use case. F loses to A on every axis except "the operator isn't a company," and it doesn't even win on privacy.

---

## 3. The fundamental trade-offs, with numbers

### 3.1 Memory forces splitting, and splitting over WAN forces serial latency
- DeepSeek V3-class (671B) at 4-bit ≈ 350–400 GB of weights, so **~16× 3090** before KV cache [calc]. Kimi K2 (1T, native int4) ≈ 500+ GB, so ~22 cards [calc].
- Pipeline decode cost per token ≈ Σ(stage compute) + N_hops × one-way latency. With 16 stages at 15–25 ms one-way (regional residential), that's 0.25–0.4 s/token, so **~2.5–4 tok/s**. This matches Petals' measured 4–6 tok/s on smaller splits [calc/V].
- The same 16× 3090 on a LAN is compute/bandwidth-bound: 13–37B active params at 4-bit ≈ 7–19 GB read per token, spread over 936 GB/s cards, gives a theoretical ~40+ tok/s. Exo measures 28–32 tok/s on 4 Mac Studios over RDMA [V].
- **Expert parallelism over the WAN is worse than pipeline.** Every MoE layer needs an all-to-all dispatch and combine. DeepSeek V3 has 58 MoE layers, so ~58 RTTs per token, or **~2+ s/token at 40 ms RTT** [calc]. DeepSeek itself only runs cross-node EP inside InfiniBand clusters ([DeepSeek infra overview, Mar 2025](https://github.com/deepseek-ai/open-infra-index/blob/main/202502OpenSourceWeek/day_6_one_more_thing_deepseekV3R1_inference_system_overview.md)). MoE sharding across consumer machines only makes sense on a LAN or Thunderbolt.

### 3.2 Agentic coding is prefill-heavy, and prefill over residential upload is brutal
- SWE-bench Verified trajectories are ~24–29k tokens median/mean, and input dominates ([2026 study via search](https://arxiv.org/pdf/2609.20804)) [S]. Real kiln sessions will re-send 30–100k-token contexts many times.
- The DeepSeek V3 hidden size is 7168, so a BF16 activation is ~14 KB/token/hop. A 50k-token prefill is **~717 MB per stage boundary**. At the US median fixed upload of **~56 Mbps** ([Ookla via search, Feb 2026](https://techblog.comsoc.org/2026/08/27/ookla-u-s-fixed-wireless-access-crosses-17-million-connections-as-adoption-shifts-from-rural-to-urban/)) [S] that's **~100 s per hop**, or ~50 s at FP8 [calc]. Compute isn't the limiter: 16 pipelined 3090s at ~35 TFLOPS effective each do the 3.7 PFLOP in ~7 s.
- **KV/prefix-cache locality is therefore mandatory.** If a session is pinned to the same pipeline and only the 2–5k new tokens move, the hop cost drops to ~4–10 s per turn [calc]. But that pins you to nodes that churn, so churn means a cold re-prefill. On 24 GB cards the KV cache also competes with weights. PI measured OOM at a single 4k sequence of Llama-2-13B on a 24 GB card with unquantized weights ([PI](https://www.primeintellect.ai/blog/inference)).

### 3.3 Batching economics: datacenters win by ~4 orders of magnitude per GPU
- DeepSeek's production system does **~14.8k output tok/s per 8×H800 node (~1.85k/GPU)** and ~73.7k input tok/s/node, reporting a 545% "theoretical" margin at R1 prices ([DeepSeek, Mar 2025](https://github.com/deepseek-ai/open-infra-index/blob/main/202502OpenSourceWeek/day_6_one_more_thing_deepseekV3R1_inference_system_overview.md)) [V]. This works because large EP spreads each expert's weights across hundreds of concurrent sequences.
- A 16× 3090 WAN pipeline at batch 1 does ~3 tok/s, or **~0.2 tok/s per GPU**. At ~$0.07/hr electricity per card that's $1.12/hr for ~10.8k tokens, **≈ $100/M output tokens** before hardware wear or the operator's margin [calc]. Batching helps only until 24 GB cards run out of KV room. Even at 20× batch you're at ~$5/M, still 5–20× above hosted DeepSeek V4 Flash output ($0.24/M).
- Consumer-GPU networks are only *economically* sensible for models that **fit on one card**, where each card runs its own batch. Those small models are also the ones that are nearly free from hosted providers.

### 3.4 Speculative decoding helps pipelines, but less than hoped
- In a WAN pipeline, speculation raises tokens per round-trip. With k=4–5 drafts at 70–85% acceptance, roughly 2.5–3.5 tokens per pass, so ~3 → ~8–10 tok/s [calc]. DeepSeek/Kimi-style MTP heads give a free draft.
- For *edge draft + remote verify*, a Sept 2026 analysis finds co-located speculative decoding "matches or beats synchronous DSD on every comparison dimension." Pipelining can't hide RTT once RTT ≥ γ·t_draft (~50 ms at γ=5, 10 ms drafts). DSD's real win is **multi-tenant server capacity** (SpecEdge: 2.22× server throughput, only 11% ITL reduction) ([Lyu et al., 2026-09-05](https://arxiv.org/html/2606.25091); [SpecEdge, NeurIPS 2025](https://arxiv.org/abs/2505.17052)) [V]. So a local draft model does **not** make a remote big model feel local.

### 3.5 Quantization: you can't see the quality cost, and it hurts tool calls most
- To fit consumer VRAM you go to 4-bit or lower. Kimi's own vendor verifier found measurable **tool-call trigger/schema accuracy gaps across 12–18 commercial providers** serving the "same" K2 model, attributed to quantization and KV/implementation bugs ([K2-Vendor-Verifier](https://github.com/MoonshotAI/K2-Vendor-Verifier); last round 2025-10-23) [V]. Agent loops compound tool-call errors. A heterogeneous consumer network with mixed quants will be worse, and a single bad stage silently degrades the whole pipeline.
- K2-Thinking/K2.6 ship native int4, and DeepSeek V4 Flash is small-active. Newer models are *designed* for 4-bit, which narrows this cost [V].

### 3.6 Churn
- Pipelines fail as a unit: P(all 16 nodes up for a 10-minute session) = p^16. At p = 0.99 per node that's 85%. At 0.95 it's 44% [calc]. Petals re-routes at the cost of re-prefill. PI openly shipped none. Request-level networks (Inference.net, Horde) handle churn with a retry, which is another reason they're the only ones with real consumer volume.

---

## 4. Verification and trust

| Method | What it catches | Overhead | Notes |
|---|---|---|---|
| **Redundant execution (k-of-n)** | Anything | k× compute | GPU nondeterminism means bitwise voting fails. You need tolerance-based comparison. |
| **Random spot checks + stake/slash** | Lazy/cheating nodes, probabilistically | Tunable (e.g. 1–5% re-exec) | Needs identity/stake. Bittensor validators work this way. |
| **TOPLOC** (Prime Intellect, Jan 2025) | Model swap, prompt tamper, precision change. 100% in their tests | **258 B per 32 tokens** commit. Validation up to **100× faster** than generation. **5–20%** validator overhead ([arXiv 2501.16007](https://arxiv.org/abs/2501.16007)) [V] | v2 adds group-level pipeline verification and blame replay stage-by-stage ([SYNTHETIC-2](https://www.primeintellect.ai/blog/synthetic-2)) [V]. The sampling-proof paper was "coming". I couldn't confirm it was published. |
| **LOGIC** (Inference.net) | Model substitution, quant spoofing, spec-decoding attacks | ~250–313 KB per 10k tokens. 10 single-token recomputes | Works with vLLM/SGLang ([blog](https://inference.net/blog/logic/)) [V]. Detection rates are self-reported [M]. |
| **DiFR** (Karvonen et al., Nov 2025) | Quantization and model substitution despite nondeterminism | Claimed practical. I couldn't extract exact numbers | [arXiv 2511.20621](https://arxiv.org/pdf/2511.20621) [V, partial] |
| **TEE attestation** | Everything, if you trust NVIDIA/Intel | ~2–5% on H100 CC | Datacenter-only (§5). |
| **zkML** | Everything, trustlessly | 100–10,000×. Hours per 100 tokens | Not viable for LLMs ([Equilibrium](https://equilibrium.co/writing/state-of-verifiable-inference)) [V] |
| **Reputation / trusted pool** | Social | ~0 | What a friends pool actually uses. |

**Solved enough:** detecting "wrong model / wrong quant / garbage" is cheap now (TOPLOC, LOGIC, DiFR). **Not solved:** detecting *subtle* degradations (a slightly lower quant that passes fingerprint tolerance, KV-cache bugs that only show at long context) and doing it without a verifier that itself holds the model. Verifying a 1T model means someone trusted must be able to run prefill of that 1T model.

---

## 5. Privacy

- **What a node sees.** A request-level node sees plaintext prompts and outputs. A pipeline stage sees activations. Those are *not* private. Prompt-inversion attacks recover **88.4% of tokens** from Llama-65B activations ([IEEE S&P 2025](https://arxiv.org/abs/2503.09022)) and **98%+** at a 5-block split (~70% at 7 blocks) ([May 2026](https://arxiv.org/html/2605.23158v1)) [V]. Noise and sparsification defenses either fail or wreck output quality. The best (PriPert) cuts reconstruction to ~18% precision at 70% sparsity with a noticeable quality loss. Code prompts contain secrets, keys, and proprietary source, so this matters for kiln's users.
- **Confidential computing.** NVIDIA CC runs only on **H100/H200, B200/GB200, and RTX PRO 6000 Blackwell Server Edition** (single-GPU passthrough only). The Workstation/Max-Q editions are "expected in future releases." **No GeForce card (3090/4090/5090) supports it**, and A100/Ampere doesn't either ([NVIDIA](https://developer.nvidia.com/blog/announcing-confidential-computing-general-access-on-nvidia-h100-tensor-core-gpus/); [Super Protocol](https://superprotocol.com/resources/gpu-cpu-tee-requirements); [Edgeless](https://www.edgeless.systems/wiki/hardware/nvidia-hopper-h100)) [V/S]. Overhead where supported is ~2–5%. Chutes' TEE mode shows it's deployable (TDX + H100/H200 CC + E2E-encrypted prompts, Mar 2026) ([Chutes](https://chutes.ai/news/confidential-compute-for-ai-inference-how-chutes-delivers-verifiable-privacy-with-trusted-execution-environments)) [V]. Apple Silicon Macs have Secure Enclave, but Apple offers no third-party GPU-memory attestation. PCC's guarantees rely on Apple-controlled server hardware.
- **Crypto (MPC/FHE).** Recent work reports relative speedups (e.g. 13× over BOLT) but still nowhere near interactive for 100B+ models [V]. Not a 2026–2027 option.
- **Transport encryption** (iroh/QUIC, as in Mesh LLM) protects against relays, **not** against the node doing the compute.
- **Realistic mitigations:** (1) only route to nodes you trust (your own devices, named friends); (2) keep the embedding and first few layers local, which the inversion results show is insufficient alone; (3) pay a TEE datacenter provider; (4) redact secrets before sending. For public consumer networks there's no real fix today.

---

## 6. Economics for contributors

- **What a 3090 earns (Sept 2026).** Salad pays **$0.102 / $0.093 / $0.082 / $0.063 per hr** (high/med/low/lowest priority), *cut* from $0.150/$0.128/$0.100 on 2026-09-12. Salad doesn't guarantee utilization ([Salad](https://blog.salad.com/earning-rate-changes-september-2026/)) [V]. Vast rents 3090s from ~$0.07–0.27/hr, with hosts earning ~75–80% of list price [S].
- **What it costs to run** [calc]: 350 W card, ~450 W at the wall with the system, at the ~$0.17/kWh US residential average gives **~$0.06–0.08/hr**. Net margin for a 3090 is roughly **$0.00–0.04/hr** with perfect utilization, before hardware wear. Europe's higher power prices make it negative.
- **What that hour is worth in tokens.** At DeepSeek V4 Flash prices (blended ~$0.10/M), $0.07 buys **~700k tokens** of a 284B model with 1M context, served at 84 tok/s [calc from V prices]. A contributor who donates an hour of 3090 time and receives an hour's electricity worth of hosted tokens gets a *better* model *faster* than anything the pool can produce.
- **Has "contribute to get big models free" worked?** Only at small-model scale (AI Horde kudos, non-sellable, volunteer-run) or where a token subsidy pays the difference (Chutes: emissions ≈ 22–40× revenue, and even then it had to cap heavy users who pulled 56–324× their plan's value). I found **no example** of a self-sustaining contributor-for-access network serving 100B+ models interactively.
- **Structural reason.** Consumer GPUs are memory-poor (24 GB) and on high-latency links, while frontier MoE economics reward huge-memory, high-bandwidth, big-batch clusters. The cheapest tokens come from maximum batching, which is exactly what WAN-distributed consumer cards can't do.

---

## 7. Agentic coding specifically

Rough tolerance: an agent task is 20–100 sequential calls. If each call costs TTFT + output/tps, then with 50 calls × (TTFT 3 s + 500 tokens / 50 tok/s = 13 s) ≈ **11 minutes**. The same task at TTFT 30 s and 5 tok/s is 50 × (30 + 100) s ≈ **1.8 hours** [calc]. Interactive pairing needs roughly TTFT under 5 s and 30+ tok/s. Background or overnight "go fix this" runs can tolerate 5–10× worse, but only if the pool stays up for the whole run.

| Frontier point | Usable for agentic coding? |
|---|---|
| A. Centralized API | Yes. Best by far, with prompt caching. |
| B. Subsidized DC decentralized | Yes, as a cheaper provider. Subsidy and throttling risk. |
| C. Single 3090 + big RAM | Borderline. ~10 tok/s decode is OK, but 50k-token prefill is the killer. Good for background jobs and small-context edits. |
| D. Own LAN/Thunderbolt pool | Yes, for people who own the hardware (28–32 tok/s on 671B–1T). Prefill on Apple Silicon is the bottleneck to measure. |
| E. Trusted pool, request-routed | Yes, if one member has a C/D-class box. The pool adds ~1 RTT. |
| F. Public WAN pipeline | No for interactive work. Maybe for overnight batch, but churn kills long runs. |
| G. Public request-level, small models | Usable, but it competes with near-free hosted small models and a local 30B-A3B on the user's own GPU. No reason to exist for kiln users. |

---

## 8. Solved vs unsolved

**Solved or good enough**
- Running 671B–1T MoE on your own hardware at interactive decode speed over a LAN or Thunderbolt (exo 1.0 + macOS 26.2 RDMA, Dec 2025).
- Running ~284B MoE on one 24 GB GPU + ~192 GB RAM at ~10 tok/s.
- NAT traversal, encrypted P2P transport, and discovery (iroh, Mesh LLM, Nostr).
- Cheap detection of model/quant substitution (TOPLOC, LOGIC, DiFR).
- Heterogeneous scheduling across NVIDIA and Apple devices (Parallax, Mesh LLM).
- Batch/offline pipeline inference over the WAN with verification (SYNTHETIC-2).

**Unsolved**
- Interactive (>20 tok/s, <5 s TTFT at 50k context) serving of 100B+ models across consumer GPUs over residential WAN. Latency × hop count and upload bandwidth for prefill are physics, not engineering debt.
- Privacy against the node that computes, on consumer GPUs. No TEE, and activation-splitting leaks.
- Fault tolerance for long sessions in pipelines, where KV cache lives on churny nodes.
- Contributor economics that beat datacenter token prices without a subsidy.
- Detecting subtle quality degradation (quant drift, long-context KV bugs) without a trusted full-model verifier.

---

## 9. Recommendation for kiln

**Build this slice: "your devices + people you trust," with request-level routing first.**
1. **Own-device pooling (tier 1).** Kiln already speaks to multiple backends. Let a user's Mac(s), a 3090 box, and a Linux server announce "I can serve model X at quant Q with context C." Route each whole request to the best node that holds the full model. Split layers or experts **only** across devices on the same LAN or Thunderbolt fabric (tang's Metal + planned CUDA backends are the differentiator here, since a pipeline across one Mac and one 3090 box on gigabit LAN is plausible). Add **sticky sessions + prefix/KV cache** on the serving node, because that's the single biggest lever for agent loops.
2. **Trusted pool (tier 2).** Invite-only meshes (Mesh LLM's model is a good template, and it also uses iroh), with fair-share credits instead of tokens. Your friend with 4 Mac Studios serves your Kimi requests, and you serve their Qwen requests. State plainly that the host can read prompts, and add optional secret redaction. Use a cheap spot-check (re-run a few tokens' log-probs locally on a small model, or TOPLOC/LOGIC-style commits) mainly to catch *misconfiguration* (wrong quant, broken KV), not malice.
3. **Hosted fallback always on.** When no trusted node can serve within latency budget X, fall back to OpenRouter/DeepSeek. That's what users will actually do anyway.

**Traps to avoid**
- **A public "contribute a 3090, get DeepSeek/Kimi free" network.** It's dominated on speed, cost, and privacy by $0.05–0.25/M hosted tokens. It needs a token subsidy to recruit supply, TOPLOC-class verification plus reputation to stop garbage, and it still can't protect users' code from node operators.
- **WAN expert parallelism** (~58 RTTs per token for DeepSeek-class MoE).
- **Counting on edge speculative decoding to hide WAN latency.** Research says the single-stream gain is small, and the win is server multi-tenancy.
- **Benchmarking only decode tok/s.** Agentic coding is prefill-dominated, so measure TTFT at 30–100k context with and without cache hits.
- **Building a Petals/Parallax/Mesh LLM clone.** Mesh LLM (Jul 2026, Rust, iroh, coding-agent launchers) already occupies the "generic pooled mesh" slot. Kiln's edge is integration: agent-aware routing, cache affinity, tang kernels, and a Mac app.

**Smallest experiment that tests the most important assumption**

The riskiest assumption is: *"solo developers will accept the latency/throughput profile a pooled network can deliver, instead of paying ~$0.10–0.30/M for hosted open models."* You can test this **without building any network**:

1. Add a latency-shaping shim to kiln's hosted provider path (OpenRouter → DeepSeek V4 Flash or GLM 5.2, same model). It holds each response to a target profile: `TTFT = a + b × uncached_prompt_tokens`, a decode cap of N tok/s, and random node-failure/re-prefill events at rate p.
2. Run ~10–20 real kiln coding tasks under four profiles:
   - hosted (baseline)
   - "own LAN pool" ≈ TTFT 5–15 s @ 50k, 25 tok/s
   - "trusted WAN, request-routed" ≈ hosted + 1 RTT, 10 tok/s
   - "public WAN pipeline" ≈ TTFT 60–120 s uncached, 3–5 tok/s, 5% failure per call
3. Measure task wall-clock, success rate, and whether *you* would keep using it (write down your honest reaction per task).
4. Separately, a one-day real measurement: `tc netem` (or a macOS equivalent) with 30 ms RTT and a 50 Mbps upload cap between two of your machines, a 2-stage tang/llama.cpp pipeline on a ~70B or 30B-A3B model, measuring TTFT at 8k/32k/64k context with and without prefix cache. This calibrates the "b" coefficient in step 1 with real numbers instead of mine.

If the "trusted WAN / own LAN" profiles keep tasks under ~2× baseline wall-clock with equal success, tier 1–2 is worth building. If even the LAN profile feels bad, spend the effort on single-box performance (MoE offload, prefix caching in tang) and a great hosted-provider experience instead.

---

## 10. Couldn't verify, or treat with suspicion
- Chutes' 160B tok/day and ~$10M ARR (the gap vs OpenRouter-visible volume is ~24×). AkashML token counts and io.net GPU counts are self-reported.
- Parallax's "5.3× lower ITL than Petals" appears only in the README. The paper compares against HexGen on a 10 ms RTT testbed.
- Mesh LLM performance: no published benchmarks.
- KTransformers / DeepSeek V4 Flash single-3090 numbers come from secondary blogs summarizing demos (MindStudio, 2026-08-25). Prefill numbers are missing.
- Vast.ai "$0.30–0.60/GPU-hr" is for a 5090 at an assumed 80% utilization, from Vast's own marketing article.
- Hosted-API TTFT at 50k context is my estimate. Measure it in the experiment.
- TOPLOC v2 sampling-proof paper publication status, and DiFR's exact overhead numbers.
- The US median upload (~56 Mbps) comes from a secondary citation of Ookla data.
- All [calc] numbers are order-of-magnitude, with assumptions stated inline. The conclusions hold even if they're off by 3–5×.

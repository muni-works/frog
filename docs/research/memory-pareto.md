# Memory beyond the context window: the Pareto frontier, and where compiled memory sits

Survey date 2026-10-28. "Verified" means I read the claim in the arXiv abstract or listing during this survey. Numbers recalled from well-known papers but not re-read this session are marked **[unverified]**. Qwenputer numbers come from the blog and repo (not on arXiv), plus our own tang checks.

## 1. Answer

The frontier has three points, and each wins on different axes:

- **Text memory (RAG and agent memory stores: MemGPT/Letta, Mem0, A-MEM).** Needs no training, does no damage to the model, persists as a portable plaintext artifact, and has shipped in products. It pays context tokens on every turn and its recall is lossy, limited by retrieval.
- **KV-cache reuse (prefix caching, CacheBlend, LMCache).** Recall is exact for whatever is cached, with no damage to the model. Shipped in inference engines. The artifact is large, tied to one model, and the cached tokens still occupy attention context.
- **Learned constant-size state (GDN, GDN-2, Titans, Trellis, TTT and In-Place TTT, FwPKM, LiveMem).** Costs zero context tokens and fixed compute per token. Recall is lossy, and these methods need pretraining or post-training.

Knowledge editing (ROME, MEMIT) and one-step LoRA "memory" are dominated for agent recall. "Beyond Perplexity" measured free-form recall at zero after the updates.

Compiled memory (qwenputer) sits at a corner no other approach occupies: **exact recall, zero context, no training, near-zero damage (KL 6e-4)**. It pays for this with extra layers and a larger checkpoint, every lookup costs 2–3 decode steps, the store is capped at a fixed size, it does not port across models, and it is research-only. It is on the frontier only if exact recall at zero context matters. Against text RAG it is dominated on portability, capacity, privacy legibility and maturity.

## 2. Table

| Approach | 1 Fidelity | 2 Context/turn | 3 Compute | 4 Base damage | 5 Persistence | 6 Privacy | 7 Training | 8 Maturity |
|---|---|---|---|---|---|---|---|---|
| RAG / vector store | lossy, retrieval-bound | k retrieved chunks | embed at write; ANN plus prefill at read | none | text plus embeddings; portable across models | plaintext at host | none | shipped (products) |
| MemGPT/Letta ([2310.08560](https://arxiv.org/abs/2310.08560)) | lossy | core memory plus paged-in text | extra LLM calls to manage memory | none | text DB, portable | plaintext | none | shipped (Letta) |
| Mem0 ([2504.19413](https://arxiv.org/abs/2504.19413)) | LOCOMO +26% rel. vs OpenAI memory [unverified] | >90% fewer tokens than full context [unverified] | LLM extraction at write | none | text/graph, portable | plaintext | none | shipped |
| A-MEM ([2502.12110](https://arxiv.org/abs/2502.12110)) | lossy, beats MemGPT on LoCoMo [unverified] | retrieved notes | LLM linking at write | none | text notes, portable | plaintext | none | research/OSS |
| Prefix KV cache / LMCache | exact for the prefix | full prefix still in attention (prefill saved) | ~0 prefill on a hit; KV bytes are large | none | KV blobs, model-locked | KV is invertible-ish; host holds it | none | shipped in engines (vLLM, SGLang) |
| CacheBlend ([2405.16444](https://arxiv.org/abs/2405.16444)) | near-exact (partial recompute) | chunks in context | 2.2–3.3x TTFT cut [unverified] | small quality delta [unverified] | KV chunks, model-locked | as above | none | integrated w/ LMCache [unverified] |
| Trellis ([2512.23852](https://arxiv.org/abs/2512.23852)) | lossy, bounded m slots | 0 beyond slots | fixed per token | new architecture | slot state, model-locked | opaque state | pretrain | research |
| GDN / GDN-2 state ([2412.06464](https://arxiv.org/abs/2412.06464), [2605.22791](https://arxiv.org/abs/2605.22791)) | lossy, decays | 0 | O(1) per token | n/a (native) | state, ~MBs, model-locked | opaque state | pretrain | shipped in models (Qwen3-Next) |
| Titans/MIRAS ([2501.00663](https://arxiv.org/abs/2501.00663), [2504.13173](https://arxiv.org/abs/2504.13173)) | lossy; >2M ctx NIAH [unverified] | 0 | test-time gradient steps | new arch | neural memory weights | opaque | pretrain | research |
| Infini-attention ([2404.07143](https://arxiv.org/abs/2404.07143)) | lossy; 1M passkey [unverified] | 0 | fixed | continual pretrain | compressive memory | opaque | continued pretraining | research |
| TTT / In-Place TTT ([2407.04620](https://arxiv.org/abs/2407.04620), [2604.06169](https://arxiv.org/abs/2604.06169)) | lossy; 4B model strong to 128k | 0 | negligible prefill overhead (In-Place) | drop-in to MLP projections | fast weights | opaque | continued training | research (ICLR'26 oral) |
| Latent Context Compilation ([2602.21221](https://arxiv.org/abs/2602.21221)) | lossy at 16x compression | ~1/16 of context as buffer tokens | LoRA compile per context | frozen base | buffer tokens, "portable" | opaque-ish | per-context LoRA compile | research |
| One-step LoRA memory ([2607.00368](https://arxiv.org/abs/2607.00368)) | free-form recall 0 | 0 | gradient step at write | weights change | adapter | opaque | yes | research (negative) |
| FwPKM ([2601.00671](https://arxiv.org/abs/2601.00671)) | NIAH to 128K from 4K training | 0 | low, fixed, sparse | new layer | sparse fast weights | opaque | pretrain | research |
| ROME/MEMIT ([2202.05262](https://arxiv.org/abs/2202.05262), [2210.07229](https://arxiv.org/abs/2210.07229)) | facts only, ~10k edits [unverified] | 0 | solve per edit | degrades at scale [unverified] | edited weights | baked into weights | none (closed-form) | research |
| LiveMem ([2608.02515](https://arxiv.org/abs/2608.02515)) | "leading" on LongMemEval (no number in abstract) | bounded KV window | fixed memory state | memory post-training | session state | opaque | post-training | research |
| **Compiled memory (qwenputer)** | **exact**; 90% vs 30% cross-chat recall (blog) | **0** | +extra layers on every token; 2–3 decode steps per lookup | **KL 6e-4** (blog) | saved recurrent state (512 files, ~53k tok); checkpoint grows | opaque but decodable (one-hot) | **none (compiled)** | research/hobby |

## 3. Families: what was measured

**RAG and agent memory**
- MemGPT treats the context as RAM and external storage as disk, with the LLM paging between them through function calls ([2310.08560](https://arxiv.org/abs/2310.08560)).
- Mem0 reports +26% relative LLM-judge score over OpenAI memory on LOCOMO, 91% lower p95 latency and >90% token savings versus full context [unverified] ([2504.19413](https://arxiv.org/abs/2504.19413)).
- A-MEM uses Zettelkasten-style linked notes and reports gains over MemGPT and Mem0-style baselines on LoCoMo [unverified] ([2502.12110](https://arxiv.org/abs/2502.12110)).
- 2026 successors: I did not verify specific 2026 agent-memory papers beyond LiveMem. **Not found** in this pass.

**KV caching and KV as memory**
- CacheBlend reuses non-prefix KV chunks and recomputes a small fraction of tokens: 2.2–3.3x TTFT, 2.8–5x throughput [unverified] ([2405.16444](https://arxiv.org/abs/2405.16444)).
- Trellis replaces the KV cache with m bounded slots written by online gradient descent with a forget gate. Its advantage grows with sequence length (abstract, verified) ([2512.23852](https://arxiv.org/abs/2512.23852)).
- The KV-compression survey "Key, Value, Compress" maps the trade space ([2503.11816](https://arxiv.org/abs/2503.11816)).
- LMCache-style offload: I did not verify an arXiv paper and number this session. **[unverified]**

**Recurrent and linear-attention state**
- Fast weight programmers: linear attention is a fast-weight memory, and the delta rule fixes capacity overwrite ([2102.11174](https://arxiv.org/abs/2102.11174)).
- Gated DeltaNet combines a decay gate with the delta rule ([2412.06464](https://arxiv.org/abs/2412.06464)).
- Gated DeltaNet-2 decouples channel-wise erase and write gates. At 1.3B params and 100B tokens it beats Mamba-2, GDN, KDA and Mamba-3 on LM, commonsense and retrieval (verified via listing) ([2605.22791](https://arxiv.org/abs/2605.22791)). Decoupled erase and write is the trained-model analogue of qwenputer's pinned gates.
- Titans uses test-time-learned neural memory with surprise-gated updates. MIRAS generalizes this into attentional bias plus retention [numbers unverified] ([2501.00663](https://arxiv.org/abs/2501.00663), [2504.13173](https://arxiv.org/abs/2504.13173)).
- Log-linear attention keeps a log-growing set of states ([2506.04761](https://arxiv.org/abs/2506.04761)). Infini-attention adds compressive memory to attention ([2404.07143](https://arxiv.org/abs/2404.07143)).
- Stuffed Mamba shows that recurrent state collapses and forgets beyond the training length ([2410.07145](https://arxiv.org/abs/2410.07145)) [details unverified]. This is the failure mode that pinning the gate to 1 avoids.

**Test-time training and parametric memory**
- TTT layers make the hidden state a model updated by self-supervised steps ([2407.04620](https://arxiv.org/abs/2407.04620)).
- In-Place TTT (ICLR 2026 oral) uses the MLP final projections as fast weights with an NTP-aligned objective. It is a drop-in for existing LLMs and lets a 4B model do well to 128k with negligible prefill overhead ([2604.06169](https://arxiv.org/abs/2604.06169)).
- Latent Context Compilation uses a disposable LoRA "compiler" to compress a context into buffer tokens for a frozen base, keeping detail at 16x on Llama-3.1-8B ([2602.21221](https://arxiv.org/abs/2602.21221)).
- Beyond Perplexity tested one-step LoRA updates on nonce facts across 3 Qwen3 scales. Support and answer loss dropped, but **free-form recall stayed at 0** ([2607.00368](https://arxiv.org/abs/2607.00368)).
- Fast Weight Attention for Continual Learning (Falcon-1/2/3) uses prefix-aligned (k_{t-1}, v_t) NLMS updates. It is competitive at LM and extrapolates better on addition; the abstract gives no numbers ([2608.27763](https://arxiv.org/abs/2608.27763)).

**Knowledge editing and in-weight memory**
- ROME edits single facts through rank-one MLP edits ([2202.05262](https://arxiv.org/abs/2202.05262)). MEMIT scales to thousands of edits, with degradation at scale [unverified] ([2210.07229](https://arxiv.org/abs/2210.07229)).
- Product-key memories are large sparse key-value layers ([1907.05242](https://arxiv.org/abs/1907.05242)).
- FwPKM makes PKM slots fast weights updated by chunk-level GD. It reaches NIAH at 128K after 4K training ([2601.00671](https://arxiv.org/abs/2601.00671)).

**Compiled transformers**
- Tracr compiles RASP programs into transformer weights ([2301.05062](https://arxiv.org/abs/2301.05062)).
- Learning Transformer Programs trains networks that decompile into readable programs ([2306.01128](https://arxiv.org/abs/2306.01128)).
- Qwenputer (blog and code, not arXiv) pins GDN gate=1 and β=1 with one-hot keys, which turns a state row into exact RAM. It is a 512-file, ~53k-token store. Blog numbers: 90% vs 30% cross-chat recall, KL 6e-4, 2–3 decode steps per lookup. Our own tang checks: bitwise exact, and only with dedicated heads.

**Persisting state in engines, and privacy**
- LiveMem adds a fixed-capacity memory state plus a bounded KV window and state-aware serving, evaluated on LongMemEval ([2608.02515](https://arxiv.org/abs/2608.02515)).
- vLLM and SGLang hybrid-model (Mamba/GDN) state prefix caching: these are engine docs, and I found no arXiv paper. **Not found**.
- Hidden-state privacy and recurrent-state exfiltration: **not found** in this pass. Embedding and KV inversion work exists but I did not verify it here.

## 4. What compiled memory dominates, and what dominates it

**Dominates:**
- *Paste-old-chats / long-context replay.* Compiled memory has better recall (90 vs 30, blog), zero context and no training.
- *One-step LoRA and parametric memory* ([2607.00368](https://arxiv.org/abs/2607.00368)). Compiled memory recalls exactly; the LoRA updates recalled 0.
- *Knowledge editing.* Compiled memory is exact, needs no solve per edit, and its damage is bounded.
- *Native GDN state as memory.* Pinning gives exact recall instead of decay, the failure Stuffed Mamba describes ([2410.07145](https://arxiv.org/abs/2410.07145)).

**Dominated by or traded against (closest competitors):**
1. **RAG / Mem0-style text memory.** Wins on capacity (unbounded), portability across models, auditable plaintext, maturity and zero compute overhead. Loses on context cost per turn and on exactness.
2. **Prefix KV caching (LMCache, CacheBlend).** Also exact with no damage and already in engines. Loses on context occupancy and artifact size per token, since KV is far larger than a one-hot state row.
3. **In-Place TTT** ([2604.06169](https://arxiv.org/abs/2604.06169)). Zero context with negligible overhead, and capacity scales to 128k. It is lossy and needs training.
4. **Latent Context Compilation** ([2602.21221](https://arxiv.org/abs/2602.21221)). A "compile, don't train the base" philosophy; 16x compression with a portable artifact. It is lossy and still uses some context.

## 5. Open questions our experiments could answer

- Overhead of compiled layers on Qwen3-Coder-Next in tang: tokens/s and bytes, measured against prefix-cache hits for the same 53k tokens.
- Does the KL of ~6e-4 hold on the 80B hybrid and on coding benchmarks (SWE-style)? No paper measures this for compiled heads.
- Capacity scaling: what does the cost look like past 512 files? Is there a hybrid that indexes text RAG through compiled pointers?
- Does the agent actually *issue* lookups when it needs to? This is the gap "Beyond Perplexity" names: proxy metrics versus behavior.
- Head-to-head on LongMemEval and LoCoMo against Mem0 and LiveMem at an equal token budget.
- Privacy: one-hot state is trivially decodable. Can the saved state be encrypted at rest and the decode kept local? No literature found.
- Can GDN-2's decoupled erase and write gates be pinned to give the same exact RAM without extra heads ([2605.22791](https://arxiv.org/abs/2605.22791))?

## 6. Sources

MemGPT [2310.08560](https://arxiv.org/abs/2310.08560) · Mem0 [2504.19413](https://arxiv.org/abs/2504.19413) · A-MEM [2502.12110](https://arxiv.org/abs/2502.12110) · CacheBlend [2405.16444](https://arxiv.org/abs/2405.16444) · KV compression survey [2503.11816](https://arxiv.org/abs/2503.11816) · Trellis [2512.23852](https://arxiv.org/abs/2512.23852) · FWP [2102.11174](https://arxiv.org/abs/2102.11174) · Gated DeltaNet [2412.06464](https://arxiv.org/abs/2412.06464) · GDN-2 [2605.22791](https://arxiv.org/abs/2605.22791) · Titans [2501.00663](https://arxiv.org/abs/2501.00663) · MIRAS [2504.13173](https://arxiv.org/abs/2504.13173) · Log-linear attention [2506.04761](https://arxiv.org/abs/2506.04761) · Infini-attention [2404.07143](https://arxiv.org/abs/2404.07143) · Stuffed Mamba [2410.07145](https://arxiv.org/abs/2410.07145) · TTT [2407.04620](https://arxiv.org/abs/2407.04620) · In-Place TTT [2604.06169](https://arxiv.org/abs/2604.06169) · LCC [2602.21221](https://arxiv.org/abs/2602.21221) · Beyond Perplexity [2607.00368](https://arxiv.org/abs/2607.00368) · Fast Weight Attention CL [2608.27763](https://arxiv.org/abs/2608.27763) · ROME [2202.05262](https://arxiv.org/abs/2202.05262) · MEMIT [2210.07229](https://arxiv.org/abs/2210.07229) · PKM [1907.05242](https://arxiv.org/abs/1907.05242) · FwPKM [2601.00671](https://arxiv.org/abs/2601.00671) · Tracr [2301.05062](https://arxiv.org/abs/2301.05062) · Learning Transformer Programs [2306.01128](https://arxiv.org/abs/2306.01128) · LiveMem [2608.02515](https://arxiv.org/abs/2608.02515) · Qwenputer: https://divagr.com/blog/qwenputer, https://github.com/divagr18/qwenputer (not arXiv)

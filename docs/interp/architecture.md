# What's inside the models frog runs: architectures as tang implements them

Research note, 2026-10-26. It covers the two models frog serves through tang, as the code
implements them:
- **Qwen3-Coder-Next**: frog cloud's default and the model `cloud/qwen3-coder-next` points at.
- **GLM-5.3-Flash** (`cloud/glm-5.3-flash`).

For each one it lists the internal signals that exist and could be shown to a user, and where
each one is computed. All paths are relative to `~/Developer/tang/crates/tang-llm/` unless they
start with `crates/frog-engine`. Line numbers match tang as checked out on 2026-10-26.

**Short version.** Both models are **hybrid linear-attention MoE** models.
- About 3 in 4 layers are a fixed-size recurrent "fast-weight" memory. In Coder-Next that's
  Gated DeltaNet; in GLM it's Kimi Delta Attention.
- About 1 in 4 layers are softmax attention over the whole context.
- Every token's FFN is a sparse pick from hundreds of experts.

Three cheap, high-value signals already sit in the hot path. tang computes them for its own
purposes and discards them:
1. top-k logits / argmax and runner-up probabilities in the head;
2. expert ids and weights from the router;
3. draft acceptance, both MTP and suffix-match.

None of them reaches frog today. frog's OpenAI client drops every chunk field except text, tool
calls, reasoning and usage (`crates/frog-engine/src/provider/openai.rs:244-325`).

---

## 1. Findings that differ from the brief

These are findings, not errors in the brief. Each needs action or awareness before anyone
builds on it.

1. **"Resident experts" in GLM-5.3-Flash means "everything is on the GPU"**, not hot-expert
   caching.
   - All 288 experts per layer are uploaded once in GGUF quant form and stay there
     (`src/flash/glm5/engine.rs:45-49,228-248`; `src/flash/glm5/moe_gpu.rs:139-169`).
   - There is no residency table, no offload and no usage counter. That expert-cache
     machinery exists only in the Qwen Flash-Next engine (`src/flash/engine.rs:570,1715`) and
     isn't wired for glm5.
   - `docs/models.md:36` still says "expert offload even on H200". The code does none.
2. **GLM's "full attention" layers are DSA**: DeepSeek-V3.2-style MLA with **no RoPE**
   (`qk_rope_head_dim = 0`) plus a pooled top-k indexer (`src/flash/glm5/mla.rs:10-15`).
   - **The model has no positional encoding at all.** Position comes only from the KDA
     recurrence and its short conv (`docs/models/glm5-gguf-map.md:247-248`).
   - Interp consequence: in GLM, "where am I in the file" lives entirely in the recurrent
     state.
3. **Likely GPU bug in GLM's DSA path** (found while tracing where attention would be logged).
   I haven't run it to confirm. Report it to the tang owner.
   - `GpuFfn::load` builds one `MlaCuda` per device from a *single sample layer*
     (`src/flash/glm5/engine.rs:138-144`).
   - `dsa_gpu` then uses `g.mla_k[d]` for **every** DSA layer on that device
     (`engine.rs:455-462`).
   - `MlaCuda::attend` uses the `wk_d`/`wv_d` staged at construction and ignores the
     per-layer slices it's passed. Its own comment assumes they're "the same data re-gathered
     per call" (`src/flash/glm5/mla.rs:2030-2039`). That's false across layers.
   - The resident seq-0 latent cache also looks shared across layers (`mla.rs:1565-1579`).
   - If this is confirmed, all 11 DSA layers run with layer 3's K/V weights on GPU.
   - The tiny fixture has one DSA layer, so `engine_gpu_mla_matches_cpu` can't catch it. Only
     the env-gated `engine_real_weights_gpu_matches_cpu` (`engine.rs:1107-1156`) would.
   - Until it's resolved, take any DSA activations from `TANG_GLM5_GPU_MLA=0` or the
     `glm5-ref` forward.
4. **GLM's cross-turn "cache hits" are not real reuse.**
   - `restore_running` resets the engine and **re-prefills the whole prefix**
     (`src/flash/glm5/serve_glue.rs:77-85`): "the engine's recurrent state is not exposed for
     snapshotting".
   - `FlashServe::prefill` still counts that as `reused` (`src/flash/serve.rs:1222-1248`).
   - The `reused` count is reported to clients as `prompt_tokens_details.cached_tokens`
     (`serve.rs:1393-1404`, `src/server.rs:2234`).
   - So frog's cost popover overstates GLM cache hits. Only the live-sequence-extends case
     (`live_ok`, `serve.rs:1223`) is actually free. Coder-Next does have real snapshots (§3.4).
5. **GLM sampling is greedy only.**
   - `--temp` must be 0, and `set_sampling` is a no-op (`src/flash/glm5/engine.rs:966-974,
     1012-1015`; `serve_glue.rs:152-158`).
   - The MTP block (blk.45) is in the GGUF but nothing runs it.
6. **`docs/models.md` is stale.** It lists Coder-Next as "GPU: no" (`docs/models.md:33`) and
   GLM as "tang today: no" (`:36`). Both have CUDA engines (`src/flash/coder.rs`,
   `src/flash/glm5/`).
7. **The GLM KDA comment's state size is off by about 4%.**
   - `kda.rs:161` says "141.4 MiB". 34 layers × 64 heads × 128 × 128 × 4 B = **136 MiB**,
     plus about 9.6 MiB of conv state.
   - The 141.4 figure is probably decimal MB of state plus conv.
8. **Coder-Next "no MTP" is only true of the public GGUFs.** tang can load an MTP sidecar GGUF
   built by `scripts/qwen3next_mtp_sidecar.py` (`src/flash/coder.rs:61`). Without one, serving
   falls back to suffix drafts (`src/flash/serve.rs:65,503-508`).

---

## 2. GLM-5.3-Flash (`src/flash/glm5/`, GGUF arch `glm5-next`)

Hyperparameters come from `Hparams` / `from_gguf` (`src/flash/glm5/mod.rs:36-225`). There is a
hardcoded mirror in `KdaConfig::glm53()` (`kda.rs:89-97`).

### 2.1 Layer stack

| | |
|---|---|
| Trunk | 45 layers plus 1 MTP/NextN block (blk.45) that never runs (`mod.rs:105-115`) |
| Pattern | KDA when `head_count_kv == 0` (`mod.rs:116-124`). **DSA at layers ≡ 3 mod 4** (3, 7, …, 43): **11 DSA + 34 KDA** |
| Width | hidden 4096, vocab 154,880, RMSNorm eps 1e-5 |
| Heads | 64 (KDA head dim 128; DSA q_lora 1536, kv_lora 512, qk_nope 256, v 256, rope 0) |
| FFN | layers 0-2 dense (12288). Layers 3-44 MoE |
| Residual | mHC, 4 streams |
| Positional | none (see §1.2) |
| Total / active | 321B / about 18B (`docs/models.md:36`) |

### 2.2 KDA (Kimi Delta Attention), 34 layers

The recurrence per head is `head_step` (`kda.rs:375-421`):
- `q, k ← l2norm`, then `q /= √128`.
- `S ← diag(exp g) · S`. The decay is **per key channel**.
- `δ = β · (v − Sᵀk)`, then `S ← S + k δᵀ`. This is the delta rule.
- `o = Sᵀ q`.

The forget gate `g = −5 · σ(exp(A_log) · (f_b(f_a(x)) + dt_bias))` is per channel over
64 × 128 (`kda.rs:264-289`). It's low-rank: 4096 → 128 → 8192. β is per head
(`kda.rs:291-295`). A depthwise causal conv (k = 4, SiLU) runs over q|k|v (`kda.rs:300-370`).
The output goes through a gated per-head RMSNorm (`kda.rs:700-714`). Prefill is chunked with
C = 64 (`kda.rs:459-634`).

**State per sequence (fixed, independent of context length):**

| | shape | per layer | 34 layers |
|---|---|---|---|
| recurrent `S` | `[64][128][128]` f32 (`kda.rs:157-163`) | 4 MiB | 136 MiB |
| conv | `[24576][3]` f32 (`kda.rs:177-181`) | 288 KiB | 9.6 MiB |

**Where the state lives:**
- Host: `Glm5Engine.kda` (`engine.rs:285`), swapped around each layer (`engine.rs:635-639`).
- GPU: `DevKda.st` (`kda_dev.rs:24-30,66-69`; `kda_cuda.rs:373-422`). Read it back with
  `DevKda::read_state` (`kda_cuda.rs:565-568`) or `DevLayer::read_back` (`engine.rs:428`).
- The host copy is stale while `kda_dev_fresh[l]` is set (`engine.rs:58-59,433-440`).

**Interp-relevant signals that are already computed per token:**
- `g`: per-channel decay. This is the model's own "how fast am I forgetting" at each layer.
  `exp(g)` near 1 means it's holding; near e⁻⁵ means it's wiping.
- `β`: per head, the write strength.
- `‖v − Sᵀk‖`: the **delta-rule prediction error**. It measures how surprising this token's
  value is to the memory.

All three live in `kda.rs:264-295` (CPU) and in the `kda_k5.cuh` kernels.
`TANG_GLM5_KDA_DUMP=1` prints the first few values (`kda.rs:657,689`). Nothing aggregates them.

### 2.3 DSA (MLA with no RoPE), 11 layers

- **KV per token per layer:** the normed 512-dim latent. bf16 on GPU is 1024 B
  (`mla.rs:835,1221-1223`); f32 on CPU is 2048 B. Add indexer rows `k[128]` + `gate[128]`
  (f32, 1024 B), a valid byte, and pooled keys (about 128 B/token). That's **about 2.2 KB per
  token per layer, about 24 KB per token over 11 layers**.
- Host mirror: `DsaCache` (`engine.rs:30-43`). GPU copies live in `MlaCuda.seqs`, an LRU with
  cap 4 where only seq 0 is used (`mla.rs:1263-1305`).
- **Indexer:**
  - Dense while kv_len ≤ 2048.
  - Past that, each query attends to the **top 2048 tokens chosen by the indexer** plus a
    3-token tail (`mla.rs:31-41`; `indexer_is_dense`, `mla.rs:349`).
  - The selected indices come out of `indexer_select` (`mla.rs:378`) or `cu.idx_run`
    (`engine.rs:928-944`).
  - **This is a ready-made, model-computed "what in the context mattered" set** for long
    contexts (§4, signal S5).

### 2.4 MoE (288 routed, top-8, 1 shared), layers 3-44

Router: `route` (`moe.rs:280-333`).
- `s = sigmoid(W·x)` (`moe.rs:301-304`).
- Selection runs on `s + e_score_correction_bias`, which is aux-loss-free `noaux_tc`
  (`moe.rs:305`).
- Group limiting is a no-op here (n_group = 1).
- Weights are the *unbiased* `s`, renormalised over the top 8, × 2.5 (`moe.rs:321-330`).
- It returns `(ids [t][8], wts [t][8])`. This is the cleanest extraction point.
- The shared expert has width 2048, no gate and weight 1. SwiGLU is clamped at 10
  (`moe.rs:1-19`).

GPU path:
- `g5_router_logits` writes `sc [T][288]`, then `g5_router_select` writes `ids`/`wts [T][8]`
  (`moe_gpu.rs:219-314`; kernels at `moe_cuda.cuh:118,130`).
- **These buffers are freed when `ffn()` returns and are never read back.** Extracting them
  costs one 64 B D2H copy per token per layer (8 × u32 ids + 8 × f32). Or accumulate a
  `[42][288]` histogram on device and read it once per request.

### 2.5 mHC (manifold-constrained hyper-connections)

Each block has its own `fn [24][16384]`, `base[24]` and `scale[3]` (`mhc.rs:16-19,95-110`).

Per block (`mhc.rs:249-308,314-347`):
1. RMSNorm over the flat 4 × 4096.
2. Split into `pre[4]` (σ + eps), `post[4]` (2σ) and `comb[4][4]`. `comb` is a softmax and then
   **Sinkhorn-Knopp**: 1 column pass, then 19 × (row, column) (`mhc.rs:205-230`). That makes it
   doubly stochastic.
3. The block reads `x = Σ pre[s] · r[s]`.
4. It writes `r'[d] = post[d] · y + Σ_s comb[s][d] · r[s]`.

The head is the mean of the 4 streams (`mhc.rs:351-366`).

**The per-token `post`/`comb` mixes are already copied back to the host as `Vec<Mix>`, even on
the GPU path** (`engine.rs:536-553`). Logging them is free. Whether they mean anything to a
user is an open question (see survey §7).

### 2.6 Head, logits, sampling

- `output.weight` (Q8_0) is applied **on the CPU** after dequant (`engine.rs:687-692`;
  `forward.rs:478-491`). Full `[t][154880]` f32 logits are on the host every window
  (`engine.rs:588,711`).
- Sampling is greedy argmax only (`engine.rs:966-974`).
- **Entropy, top-k logprobs and the top-1/top-2 margin are a loop over a vector that's already
  in host memory.** That's about 155k flops per token, essentially free.
- `top_logprobs` exists for the `glm5-ref` CLI (`forward.rs:495-498,563-568`; it uses
  `reference.rs:1837`).

### 2.7 Existing hooks

| Hook | Gives | Where |
|---|---|---|
| `TANG_DUMP_DIR` (`DumpSink`) | per-layer post-FFN 4 × 4096 streams, `final_x`, logits. **Last position of each window only** | `dump.rs:47-107`; called at `engine.rs:665-670,695-704` |
| `glm5-ref --dump --logits --top K` | per-layer `hc_attn_out`, `post_attn`, `ffn_out`, `post_ffn` at the last position (CPU, slow) | `forward.rs:226-466,500-581` |
| `TANG_GLM5_PROF=1` | per-stage ms | `engine.rs:591-596` |
| `TANG_GLM5_KDA_DUMP=1` | x/qkv/g/β heads | `kda.rs:657,689` |
| OTel `tang_llm.glm5.window` | window wall time | `src/telemetry.rs:165` |

`DumpSink` caveats:
- `entries` is never cleared, so `index.json` collects duplicates and memory grows.
- Every window overwrites the same files, so only the last window survives.

Fix both before using it for anything per-token.

---

## 3. Qwen3-Coder-Next (`src/flash/coder.rs`, GGUF arch `qwen3next`)

This is a CUDA engine (`coder.rs:1-25`). The geometry is read from GGUF into the shared
`Hparams` (`src/flash/reference.rs:59-93,290-358`). Published values are in
`docs/models.md:33` and `docs/qwen3next-profile.md`.

### 3.1 Layer stack

| | |
|---|---|
| Total / active | 80B / 3B |
| Layers | 48. Recurrent unless `(i+1) % full_attention_interval == 0` (default 4) (`reference.rs:306-314`), so **36 GDN + 12 gated full attention**, 3:1 |
| GDN | 16 k heads, 32 v heads (grouped, `h / r`; `reference.rs:363-367`), d_state 128, conv 4 (`coder.rs:886-889`) |
| Attention | gated GQA, 16 q × 256, 2 kv heads, RoPE on 64 of 256 dims, θ 5e6 (`coder.rs:892`). Split-K over every earlier cell, no indexer (`coder.rs:10`) |
| MoE | 512 routed, top-10 (FF 512) plus a shared expert (512, sigmoid gate), every layer. All experts VRAM-resident (`coder.rs:11-12`) |
| Residual | one stream with pre-norms. No hyper-connections (`coder.rs:8-9`) |

### 3.2 State sizes per sequence

| | per layer | total |
|---|---|---|
| GDN `S`: `hv × 128 × 128` f32 (`coder.rs:1291-1297,4317`) | 2 MiB | 72 MiB (36 layers) |
| GDN conv history `3 × conv` f32 | small | about 1 MiB |
| Attention K and V: `max_ctx × 2 × 256` bf16 each (`coder.rs:1280,1298-1302`) | 2 KiB/token | **24 KiB/token** (12 layers) |

At 128k context that's about 3 GiB of KV against about 73 MiB of recurrent state. **The
recurrent state is the cheap, fixed-size part. The KV is what grows.**

### 3.3 Router, head, sampler

- Router: a GEMV `router` with `n_expert + 1` rows, the extra being the shared-expert gate row
  (`coder.rs:2846,4362-4370`). Then the `route` kernel writes top-10 `ids`/`w`
  (`coder.rs:2862-2869`), one warp per token.
- The per-layer `ids` buffer is live on device (`coder.rs:684-685`). A **`Probe` already
  downloads it** (`coder.rs:3227-3234`), along with `mixer_out`, `moe_out` and `post_moe`.
  - The `Probe` struct is at `src/flash/engine.rs:526-535`.
  - It's used for parity checks by `flash-*` CLIs (`src/flash/cli.rs:941-976,1739-1768`).
  - **Probes sync the device after every layer and only capture the last row.** They're a
    research hook, not a serving one.
- Head: logits stay in `s.head [t][vocab]` on device, downloaded by `Coder::logits`
  (`coder.rs:3874-3879`). The vocab is about 152k, so about 600 KB per token if pulled whole.
  Don't.
- Sampling is on device: argmax kernels (`coder.rs:3143-3170`), or `flash/sampler.rs`
  (top-k, top-p, presence) when not greedy (`coder.rs:804-805,3142`).
- **The MTP pick kernel already computes argmax, its softmax probability and the runner-up**
  per row (`coder.rs:226,256-290`). A per-token *margin* signal therefore exists in CUDA today.
  It's computed only for the MTP draft rows.

### 3.4 Cross-turn cache (`src/flash/serve.rs`)

From the module doc (`serve.rs:1-18`):
- The engine keeps the **live sequence**. A prompt that extends it prefills only the new tokens.
- Otherwise it restores the **longest saved `RunningState`** that the prompt extends. That's
  the recurrent state, about 118 MB in host RAM for Flash-Next.
- Snapshots are taken:
  - at the end of the system prompt (pinned, and saved to disk);
  - at each prompt's last turn boundary;
  - at the end of each request.
- An assistant message the server generated is **spliced back as its exact tokens**, so
  follow-ups extend token for token.

Coder implements real `save_running` / `restore_running` (`coder.rs:4580-4660`; wired at
`serve.rs:279-289`), plus positional save/restore for KV (`coder.rs:4745-4760`). Snapshot count
and bytes are configured at `serve.rs:56-57,710-711`.

Reporting:
- `cached_tokens = reused` (`serve.rs:1401`) → `prompt_tokens_details.cached_tokens`
  (`src/server.rs:2234`).
- OTel `tang_llm.prefix.hit_ratio` (`src/telemetry.rs:148,274`).

The dense engine (`src/engine.rs`, `src/blocks.rs`) uses paged, hash-chained KV blocks with an
on-disk tier (`src/kvstore.rs:1-12`). Prefix sharing there is per block and can be shared
across conversations.

### 3.5 Speculative decoding

- **MTP drafts** (only with a sidecar GGUF). `Policy` prices draft length per width and keeps a
  **live calibration table from draft probability to acceptance rate**, in 10 buckets
  (`serve.rs:404-478`). `observe` updates it every verify (`serve.rs:467-478`).
- **Suffix drafts** (`src/draft.rs`, SuffixDecoding-style). There are two suffix automata
  (`draft.rs:1-14`):
  - one over this request's prompt plus its output;
  - a bounded global one over earlier completions.

  `Sam` keeps a `first` end position per state (`draft.rs:68-79`). That means **an accepted
  suffix draft knows *where in the prompt* the copied span came from**.
  - The per-match-length acceptance is calibrated online: `Calibration`, priors 0.35 → 0.9
    (`draft.rs:597-615`).
  - The prior's own comment: "short matches are often coincidental, long ones usually copies."
- Per-request totals `drafted`/`accepted` (`serve.rs:1429,1578-1579`) are **already sent to
  clients** as `usage.timings.draft_n` / `draft_n_accepted` (`src/server.rs:2236-2243`).
  frog's `read_usage` ignores them (`crates/frog-engine/src/provider/openai.rs:343-361`).

---

## 4. Signal inventory: what exists, what it costs, where to tap it

Cost is the extra work *per generated token* at serving time on our stack.

| # | Signal | Models | Exists today? | Tap point | Cost to surface |
|---|---|---|---|---|---|
| S1 | **Token logprob, top-k alternatives, entropy, top-1/top-2 margin** | GLM | full logits on host each window | `glm5/engine.rs:711` (after `window()`), next to `argmax` `:966` | about 0 (host loop over 155k floats) |
| S1 | same | Coder | logits on device; argmax/prob/runner-up kernel exists for MTP rows | `coder.rs:3143-3170` (head); reuse `cx_mtp_pick` (`coder.rs:226-290`) | one small kernel per window: logsumexp + top-5, 48 B/token D2H |
| S1 | same | dense (Mac local) | `Logits::Top` = top-64 raw logits on device (`src/model.rs:920,1006,1085`) | `src/engine.rs:1563-1568` | needs the full-vocab logsumexp too (one reduction). Then free |
| S2 | **Expert routing (ids, weights) per token per layer** | GLM | computed, freed | `glm5/moe.rs:330` (CPU) / after `g5_router_select` (`moe_gpu.rs:270-286`) | 64 B × 42 layers per token, or an on-device `[42][288]` count read once per request (about 48 KB) |
| S2 | same | Coder | computed. `Probe` downloads it (with a per-layer sync) | `coder.rs:2862-2869`; `Probe` at `:3227` | the same histogram trick: `[48][512]` u32 = 96 KB per request. Don't use `Probe` in serving |
| S3 | **Draft acceptance** (MTP or suffix) | Coder, Flash-Next | per-request totals already in `usage.timings`; per-draft accept/reject and probability bucket in `Policy::observe` | `serve.rs:467,1578`; `server.rs:2241` | 0 for totals (frog just has to parse them). Per-token accept flags: 1 bit/token |
| S4 | **Copy provenance**: an accepted suffix draft's source position in the prompt | Coder (suffix mode), dense | `Sam.first` end positions | `src/draft.rs:68-79,237` | about 0. Map source token position → message/tool-result index on the server |
| S5 | **DSA indexer top-2048 selection** (which past tokens a long-context query attends to) | GLM, at kv > 2048 | computed per token per DSA layer | `glm5/mla.rs:378`; `engine.rs:928-944` | 2048 × u32 × 11 layers is too big per token. Pool to per-message counts on device (a few hundred bytes) |
| S6 | **Attention weights** (full-attention layers) | Coder (12 layers), GLM (11) | inside split-K / flash kernels, never materialised | `coder.rs:2630-2700` (split-K launch); `glm5/mla.rs` attend | real cost. Needs an extra pass or an online per-span accumulator in the kernel. Do it on demand only |
| S7 | **Recurrent-layer gates**: KDA per-channel decay `g`, write strength β, delta error ‖v − Sᵀk‖ | GLM (and GDN in Coder) | computed per token | `glm5/kda.rs:264-295`; GDN step in `coder.rs:2584` | per-layer scalars (mean `g`, mean β, ‖δ‖): 3 floats × 34 layers per token, reduced on device |
| S8 | **Recurrent state snapshot** (fixed size: 136 MiB GLM, 72 MiB Coder) | both | Coder: `save_running` (`coder.rs:4580`). GLM: `DevKda::read_state` (`kda_cuda.rs:565`) but not wired (`serve_glue.rs:77-85`) | as listed | already paid for Coder snapshots. Any probe on S ("does the memory still hold file X?") runs offline on a snapshot |
| S9 | **Residual stream / hidden states** (for linear probes) | both | `Probe` (Coder), `DumpSink` (GLM), last row only | `coder.rs:3205-3234`; `glm5/dump.rs` | a probe is a dot product: 2048-d (Coder) or 4 × 4096 (GLM) per token at 1-2 chosen layers. About 0 compute if fused after the layer's add-norm; no sync |
| S10 | **mHC mixes** (`pre`/`post`/`comb`, per token per block) | GLM | already on host | `glm5/engine.rs:536-553` | 0 |
| S11 | **Cache provenance**: live extend vs snapshot restore vs cold, restore ms, snapshot hit | both | `Line` (`serve.rs:482-498`) logs it to the server log | `serve.rs:1393-1410` | 0; add fields to usage. **Fix the GLM over-report first (§1.4)** |
| S12 | **Router margin / "expert confidence"** (top-k weight mass, sigmoid scores of the near-misses) | both | `sc [T][288]` (GLM), router GEMV output `lg` (Coder, `coder.rs:683`) | as S2 | same as S2 |

### 4.1 Plumbing gap in frog

- **Request:** add an `Extensions` flag (`crates/frog-engine/src/provider/mod.rs:45-52`),
  advertised via the `/v1/models` capabilities that tang already lists
  (`provider/mod.rs:279-300`; `openai.rs:91-110`).
- **Stream:** parse `choices[0].logprobs` (standard OpenAI shape) and a tang extension object in
  the loop at `openai.rs:263-277`. Add a `StreamEvent::TokenMeta`; the enum is at
  `provider/mod.rs:54-73`.
- **Alignment:** visible text is re-chunked by `TagFilter` (`crates/frog-engine/src/engine.rs:
  4705-4709`). Carry character offsets, not chunk indices.
- **Persistence:** text deltas are live-only (`crates/frog-engine/src/protocol.rs:801-833`), so
  per-token signals vanish on reload. Store **aggregates on the completed `Item`**: spans of
  low confidence, expert histogram, copy spans. Don't store raw per-token data.
- **Per-call totals:** `Usage` (`crates/frog-engine/src/message.rs:82`) → `CallTiming`
  (`crates/frog-engine/src/protocol.rs:1198-1228`). `draft_n`/`draft_n_accepted` can go there
  today with no tang change.
- **Swift:** a new `Delta` type must be added to `apps/FrogKit/Core/Protocol.swift:548-584`.
  Unknown types decode as `.text`, which would print the metadata.

### 4.2 What does **not** exist and would be expensive

- **Attribution graphs or transcoders for either model.** No public transcoders exist for
  Qwen3-Next or GLM-5.x. The largest public Qwen-family set is for dense Qwen3 ≤ 14B (see
  survey §2). Training CLTs on an 80B/512-expert hybrid is a research project, not a feature.
- **Materialised attention maps** (S6) in serving.
- **Any SAE.** You'd need one per layer, trained on our own activations.

---

## 5. Notes for whoever builds this

- Start with S1 + S3 + S11. They need **no new kernels on GLM**, one tiny kernel on Coder, and
  a parser change in frog.
- S2 (routing) is cheap, but its *meaning* is weak: MoE experts specialise by syntax more than
  by topic (survey §5). Show it as texture ("fingerprint"), never as explanation.
- S4 (copy provenance) is the sleeper. It's nearly free, it's exact rather than inferred, and
  it answers "where did this come from" for the large fraction of agent output that is copied
  file content.
- Any per-token tang extension should ride **inside the SSE chunk** as a single optional
  object, for example `"tang": {"lp": -0.12, "alt": [[id, lp], …], "copy": [msg, off]}`. Gate
  it by a request flag so normal clients pay nothing.

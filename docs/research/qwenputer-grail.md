# Qwenputer on tang: exact RAM, compiled memory, and the instant-prefill grail

Research note, 2026-10-28. Trigger: [divagr.com/blog/qwenputer](https://divagr.com/blog/qwenputer)
compiles a RISC-V CPU and a 512-file filesystem into Qwen 3.5 4B's Gated DeltaNet (GDN) layers,
using the recurrent state as exact, addressable RAM (gate and write strength set to 1, one-hot
keys). No training; extra layers and dims; the base weights untouched; KL to base Qwen 6e-4.

Question: what of that transfers to frog's stack, where tang owns the forward pass of
Qwen3-Coder-Next (36 GDN + 12 attention layers, 72 MiB fixed recurrent state, snapshots to disk
already shipped)? And is "instant prefill" reachable from it?

Five experiments, all in tang, all committed on branches (none pushed, none merged):

| branch | what | result |
| --- | --- | --- |
| `frog/gdn-one-hot-ram` | one-hot write/read in the CPU GDN spec (the CUDA kernel is verified bitwise against it) | exact |
| `frog/gdn-freerun` | 50k-token register machine; device ReadOnly→Commit path; CUDA parity on mew | exact |
| `frog/gdn-poke-probe` | trained gate statistics on real GLM-5.3-Flash weights (34 KDA layers) | no channel is exact RAM |
| `frog/gdn-prefill-bench` | GDN recurrence share of prefill, 3090 | ~4.5% (H200 baseline: 5.5%) |
| `frog/gdn-splice-probe` | context-free chunk precomputation on real GLM weights | ~0.1 nat/token, not lossless |

## 1. Exact RAM holds in tang's kernel

With the decay gate and β exactly 1.0 (reachable from realistic projections: a + dt = −30 gives
exp(softplus) that rounds to 1.0f; sigmoid(40) rounds to 1.0f) and one-hot keys:
- a write into an empty row stores v bitwise and moves no other row of any of the 48 heads;
- a one-hot query reads the row back (scaled by 128^-½ before the output norm);
- an overwrite stores `fma(1, v − s, s)`: bitwise v whenever `v − s` is exact. On random floats in
  ±1000 that is 8643 exact vs 15933 off by one rounding. **Rule for a compiler: keep stored values
  integral and below 2^24.** The RV32 core does by construction.
- a 50k-token free run as a register machine matched a plain Rust model bitwise throughout, on
  the Mac and on mew's 3090 (`cuda_gdn_vs_cpu` passes). Windows are capped at 8 tokens by the
  contract (`MAX_T`).
- **one token with g < 1 ends exactness for good**: every row is scaled by a non-power-of-two,
  the integers go fractional, and later g = 1 overwrites are inexact because `v − s` rounds.

## 2. Trained heads cannot hold exact data

Measured on GLM-5.3-Flash UD-Q4_K_XL on mew (427 tokens of prose, every KDA layer, 8192
head-channel pairs per layer; 91 min, nearly all of it the CPU shadow). KDA is GDN with a
per-channel gate, standing in for Coder-Next's GDN since no Qwen3-Next-family main GGUF is on mew.

| layers | g mean | per-channel min g, best | β mean / max | channels with g bitwise 1.0 on all tokens |
| --- | --- | --- | --- | --- |
| early (0–10) | 0.51–0.68 | 0.999994 | 0.54–0.71 / ≤0.997 | 0 / 8192 |
| mid (12–26) | 0.73–0.87 | 0.999999 | 0.64–0.77 / ≤1.000 | 0 / 8192 |
| late (28–44) | 0.67–0.79 | 0.999997 | 0.55–0.84 / 1.000 | 0 / 8192 |

So exact storage needs dedicated heads with compiled gates, which is exactly the qwenputer
design. There is no shortcut through existing heads. Curiosity for interp: 1–8% of channels per
layer have mean g > 0.999, and the best (L14 h33 c83) has a gate-only half-life of ~3M tokens. The
model keeps a few slow analog registers. β erosion is not counted, so these are upper bounds.

Disturbance (KL after poking existing heads) was not measured on real weights: it needs the
state poked mid-run on the GPU (plumbing via `Glm5Engine::snapshot()` on `frog/glm5-forward`) plus
two more 90-minute shadow runs. A synthetic run with random-init gates showed pokes erase
themselves within 10–100 tokens; not meaningful for trained weights.

## 3. Chunked GDN prefill is real but small

tang's `fl_gdn_conv_step` runs one 512-thread block per v head (48 blocks on 82 SMs) and steps
tokens serially even in a 512-row wide window. On the 3090: 2.1–4.4 µs per token per layer,
about 2–4% of fp32 peak; a chunk-64 tensor-core kernel has a ~35× ceiling at T = 512. But the
recurrence is ~4.5% of a prefill window (synthetic, 3090) and 5.5% on the H200 baseline, so the
whole prize is a few percent of prefill.

Already built, 2026-10-21: `claude/gdn-chunked-prefill` (chunk 16, CUDA cores; run on an H200 and
**slower** than baseline, raising the stage to 14.8%) and `claude/gdn-chunked-v2` (full FLA
three-phase form on tensor cores, chunk 64; CPU reference tested, CUDA never compiled; needs
150 KB smem per block, so H200-only). fa2 attention on the same branch took 54k cold prefill from
87 s to 41 s; that is where prefill time lives.

`frog/gdn-prefill-bench` adds a `gdn [T ..]` subcommand and a GDN share line to the `window` bench.
Caveats: T = 256/512 rows were run as back-to-back 64-token steps (the wrapper caps T at 64),
and the GPU was shared.

## 4. Precomputed chunk maps are not an exact prefill

The delta rule is affine in S, so a chunk of text collapses to one (A, B) pair per head; if a
chunk's k/v/β/g did not depend on earlier context, prefill would be a few matmuls per chunk.
Measured on real GLM-5.3-Flash on the CPU reference (448 tokens of README + Rust, chunk 32,
spliced chunks 4/8/12, 35 min): run the chunk alone from zero context, apply its map to the
oracle S_start, continue with the oracle context.

| spliced chunk | state rel-L2 early / mid / late | KL next 32 tok, mean / max (nats) | top-1 agree |
| --- | --- | --- | --- |
| 4 | .34 / .65 / .54 | .095 / .80 | 30/32 |
| 8 | .30 / .62 / .46 | .103 / 1.13 | 27/32 |
| 12 | .44 / .98 / .60 | .111 / .89 | 31/32 |
| skip control (chunk never touches S) | .5–.7 everywhere | .30–.58 / 3.7–5.5 | 26–28/32 |

True context in the first 4 recurrent layers (K = 4) zeroes their error but it returns by
mid-depth; KL is mixed. Mid and late layers' k/v/β/g depend heavily on context, not position
(GLM has no RoPE; the only "position" is the conv history). The skip control is weak because the
attention layers still see the chunk; a real precompute would also need the chunk's attention KV,
which was not spliced. Error compounding over longer horizons and several spliced chunks was not
measured.

Verdict: an approximate cache at ~0.1 nat/token right after the splice, 4–6× better than
skipping the chunk, not lossless, and fixing it means recomputing most of the depth.

## What this means for frog

1. **Instant prefill of new context: no.** Not by poking state (the trained heads can only read
   state their own prefill would produce), not by precomputed chunk maps (§4), and the chunked
   kernel is a few percent (§3). Prefill time is attention and MoE; fa2 was the real lever.
2. **Instant restore of old context: already shipped.** The recurrent state is fixed-size and
   snapshotted; the disk tier brings a resumed 7k session back in ~0.1 s. 3 of 4 layers carry no
   KV growth.
3. **Zero-context memory is the real prize**, and it needs exactly the qwenputer design:
   dedicated compiled heads/layers with g = β = 1, integer values, one-hot keys. tang's kernel
   supports it bitwise (§1); the driver the author hand-rolled (keeping trace tokens out of the
   base layers) becomes an engine feature since tang owns decode; the snapshot path persists the
   store across sessions for free. The author's recall across chats: 90% from state vs 30% from
   pasting old chats back in. That is frog's memory problem.
4. **Cost of the prize**: a compiler retargeted from Qwen 3.5 4B's dims to Coder-Next's, ~11
   extra layers' compute per token, a few decoded tokens per lookup (seconds for big
   computations), and a larger checkpoint (mostly zero padding; store it sparse).

## 5. Phase-1 prototype: the store exists

`frog/gdn-memstore` (tang, `crates/tang-llm/src/flash/memstore.rs`, design in
`docs/design/gdn-memstore.md`): a file store in dedicated GDN heads of one layer, every write and
read through the real `gdn_step` kernel path with one-hot keys and pinned gates, so a compiled read
circuit later sees exactly this state. Layout follows the qwenputer repo's `rv-store` branch where
it fits (18-bit token ids, directory + content rows), nothing ported.
- 4 k heads and their 12 v heads (25% of one layer): a 1,024-slot directory (FNV-1a, linear
  probing, tombstones; 8 slots per state row so one token reads a bucket) and 512 content rows of
  127 ids. Capacity 512 files / 65k tokens in 768 KiB of state.
- values below 2^18, not 2^24: a read passes the rms norm and a division (~8 roundings), so exact
  readback needs values under ~2^20; a marker column restores the scale the norm discards.
- 1-row put or get = 2 windows; `list` = 16. Full 512-file fill: 3.4 s release on the CPU device;
  10k random ops checked against a HashMap: 26.7 s.
- 7 tests pass (round-trip to capacity, overwrite/delete, collisions, random workload, persistence
  via the same bytes `RunningState` carries and via store-heads-only transfer into another
  conversation's state, poison detection, base heads bitwise untouched).
- not wired: `RunningState`, the serve session and the disk tier (the flash engine builds only
  with cuda). Uses real heads 12–15, so production needs a widened layer, not borrowed heads.
- phase 2 estimate (agent's, unmeasured): compiled chip layers in the repo's style, store tool
  calls run as engine-internal ≤8-token windows that never touch the base layers or KV; ~0.1
  GFLOP/token, ~2% of Coder-Next's active compute; 4–8 engineer-weeks; main risk is keeping the
  chip rows exact under quantized projections.

See also `docs/research/memory-pareto.md` for where this sits against RAG, KV reuse, test-time
training and parametric memory.

## 6. Phase 2: proven on the author's checkpoint, in the author's code and in tang's math

Three more tang branches and one reproduction (`docs/research/qwenputer-repro.md`):

- **`frog/gdn-memserve`**: the serve-side wiring. The store heads are named in `RunningState`;
  store ops run as engine-internal ≤8-token GDN windows on the store layer only (never the base
  layers, LM head, KV or sampler); `/v1/memory/{load,op,end}` and `GET /v1/memory` keyed by
  `prompt_cache_key`; `--memory-ephemeral` zeroes the store heads on slot reuse, eviction and
  session end, blanks them before shared-prefix snapshots and writes them to the disk tier as
  zeros; `tang-llm memory dump` prints a blob. 6 CPU tests, plus a 60-op CUDA-vs-CPU bitwise test
  on mew. Finding: memstore's layout assumed 48 v heads (Flash-Next); Qwen3.5-4B and Coder-Next
  are 16 k / 32 v, so the engine refuses the store on Coder-Next until a 32-head layout lands
  (grouped k-head mapping `vh / 2`, not `vh % 16`).
- **Reproduction on mew's 3090** with the author's RvChat code (chunked prefill added; their
  `generate` OOMs on 24 GB): Qwen issued all nine store calls itself (3 puts, list, 3 gets,
  delete, list), 160 model-printed tokens with 0 mismatches against the author's reference; state
  saved to a 14 KB file and reloaded into an empty conversation listed and read the files back
  exactly; KL to base 6.9e-4 vs a 6.7e-4 floor, and bitwise identical with files loaded or not.
  Latency 1.0–1.65 s per op (35–55 positions, ~30 ms each, PyTorch fallback kernels; the store
  itself adds 1–3 tokens per op). Layout: 12 compiled layers before Qwen's 32, hidden 2560→4608,
  16 k / 32 v heads, store in 49 key heads (1,024-slot directory in 8 heads, 32 content heads,
  small register/order/length/next-chunk tables); gates pinned by β = sigmoid(±128), dt_bias −110,
  A_log 0.
- **`frog/gdn-chip`, milestone 1**: tang's reference math runs the checkpoint's 12 compiled
  layers (a 9 GB tensor slice) on the author's teacher-forced trace: all 126 fed tokens identical,
  every store head's 128×128 state bitwise equal after each op when tang rounds to bf16 at the
  same points HF does (plain f32 within 1.2e-4). The GDN recurrence is now one shared function
  used by the reference and the chip path. Measured: 332 M multiply-adds per token for the chip
  layers' nonzero blocks (~8% of the 4B model; 2.4 G if dense), ~13 ms per decode step on the Mac
  CPU reference. Verified here: `cargo test --release -p tang-llm --lib chip -- --include-ignored`,
  3/3.

- **`frog/gdn-chip-compiler`, milestone 2**: `crates/tang-chip`, a Rust port of the q35 lowering
  (IR `Expr`/`Ffn`/`Head`/`Graph`, `allocate`, `emit_layers`, `embedding_rows`, `pick_hidden`;
  each rule cites its emit.py line; MIT NOTICE). The store circuit itself is not transcribed: the
  python builder's graph is exported once and bundled gzipped (600 KB: 3,753 dims, 164 heads,
  47,532 units, 12 layers; RV32 core plus put/get/list/delete/append). Parity at Qwen3.5-4B
  shapes: all 168 tensors of layers 0–11 equal the checkpoint bitwise in bf16, zero padding
  included (2.44 G elements, 1.24 M nonzero); the emitted layers replay the author's trace with
  all 126 tokens and every store head bitwise equal. Retarget to Coder-Next-like shapes (hidden
  2048 + 1,920 chip dims = 3968, 16 k / 32 v, 12 layers): put/get/list bitwise against the trace
  from zero state, no weight touches a host dim, 2.3 s release. Verified here: tang-chip 3/3 and
  tang-llm chip 5/5 with the checkpoint env vars. Emitted weights are ~0.05% dense and run as CSR.

**Not done.** A Coder-Next build needs the IR re-exported from the python builder with Coder-Next's
tokenizer (the id code is token-id bits) and its text rows; hosts with other head counts or a
narrower MLP need the python builder to re-schedule, or a Rust port of the builder (not
started); the 32-head memstore layout; append/delete/calc coverage in the chip test; the engine
and CUDA integration of the chip layers (doc only); the frog-side memory tool and a
LongMemEval/LoCoMo-style cross-session eval.

## Open

- Disturbance KL of a poke on real weights (needs state injection on the GPU).
- The same gate statistics on Coder-Next's actual GDN layers (needs the GGUF on a CUDA box).
- Whether splice error compounds over many chunks.
- Finishing `claude/gdn-chunked-v2` on an H200, for a few percent.

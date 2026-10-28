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

## Open

- Disturbance KL of a poke on real weights (needs state injection on the GPU).
- The same gate statistics on Coder-Next's actual GDN layers (needs the GGUF on a CUDA box).
- Whether splice error compounds over many chunks.
- Finishing `claude/gdn-chunked-v2` on an H200, for a few percent.

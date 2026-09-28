# tang architecture: crate map, repo boundary, and the "nodes as tang evaluators" wish

Written 2026-09-24. Read-only survey of `~/Developer/tang-kiln` (branch `kiln-llm`, 23 crates) and `~/Developer/kiln`. No cargo was run; "unused" means no source or manifest reference, not compiler-verified dead code. Twelve load-bearing claims were sent to three independent verifiers each; section 4 records the verdicts.

## 1. TL;DR

1. **Should the LLM code be a separate project?** Not first. The boundary is already right in the dependency graph (tang-llm depends only on tang-compute; tang-compute needs `tang::Scalar` and four tang-expr items) and wrong in everything that expresses it: CI is red on PR #16, the stacked PRs get no CI, the README omits 8 of 23 crates, frog's build script hunts for a worktree, and the published `tang` umbrella carries a 39k-line stale fork of the siblings. Fix those inside one workspace (mostly deletion, ~2 weeks), and a later `git subtree split` of `tang-llm` + `tang-compute` becomes a small job. One caveat the verifiers found: tang-compute has two out-of-tree dependents (gaia by path, phyz-dream by git rev), so "sole dependent" is only true inside tang.
2. **Should tang-llm be built on tang IR?** Not on the IR that exists. tang-expr is a 12-node scalar DAG (9 arithmetic primitives + Var/Lit/Select) whose codegen emits one kernel shape: 256-wide f32 elementwise, no reductions, indexing, dtypes or state. tang-compile is 746 unwired lines over that same graph with a no-op fusion pass. Every op that makes decode fast (Q4 GEMV, split-KV attention, fused RoPE+cache write, RMSNorm) is a hand-written MSL/CUDA string in tang-compute, and no production stack derives those from scalar primitives. The realistic version is the ggml/MLX shape: a small, serializable **step plan** whose ops are the 15 LLM methods `ComputeDevice` already has, with tang-expr embedded as an `Elementwise` op for new fused tails.
3. **Can frog nodes be simple tang evaluators?** No. A node's value is its resident state (weights, KV slots, drafter store, compiled kernels), and every feature frog relies on (prefix reuse, speculation, thinking budget, streaming) is stateful request logic that has to sit next to the KV. Graph-shipping evaluators (ggml RPC, burn-remote, petals, tang-mesh) stayed proofs of concept; the design that scaled on consumer hardware (exo 1.0) is an engine per node behind a thin protocol. That is what ROADMAP N0 already specifies: `tang-llm node`.

## 2. The crate map

LOC are `wc -l` of `src/` (plus tests/examples where noted). "IR" means tang-expr graphs. Dates are last substantive commit.

| crate | purpose | LOC | backends | IR relationship | health | overlaps |
|---|---|---|---|---|---|---|
| tang | no_std geometry core (`Scalar`, `Dual`, Vec/Mat/Quat/Transform) plus feature-gated vendored copies of 11 siblings | 44,023 (core ~4.8k) | core CPU; copies wgpu/Metal/CUDA | core none; `src/expr/` is a stale fork of the IR | core active (08-11); copies frozen 04-23 | ~39k LOC duplicates; compute copy differs by ~9k lines and does not compile against its own cudarc 0.12 pin |
| tang-la | dense LA, decompositions on `Dual` | 4,512 | CPU (NEON, opt Accelerate) | none | stable (08-11) | copy in tang; one of four GEMMs |
| tang-ad | tape reverse-mode AD | 571 | CPU | none (tang-expr has its own diff) | dormant | copy in tang; dead dep of optim/train |
| tang-sparse | COO/CSR/CSC | 370 | CPU | none | stale, 0 dependents | none |
| tang-expr | scalar expression IR: trace, diff, simplify, codegen to WGSL/MSL/CUDA/C | 2,985 | source text only; CPU closure | **is the IR** | stable (04-23), 0.1.1 published | `wgsl.rs` vs `codegen.rs`; copy in tang |
| tang-compile | passes over tang-expr | 746 | none | consumes IR; `FuseElementwise` returns graph unchanged | dead: 3 commits, 0 dependents | duplicates `ExprGraph::simplify` |
| tang-gpu | wgpu runtime: expr fusion + hand WGSL training/LLM stack | 8,000 | wgpu | partial: ~300 LOC elementwise core; `llm.rs` (3,751) is hand WGSL | stale (04-23); tests need a GPU, excluded from CI | LLM stack #1; training dup of tang-train; device dup of tang-compute |
| tang-compute | `ComputeDevice` trait (~80 methods) with CPU/Metal/CUDA impls, 68 hand kernels | 21,244 | CPU, Metal, CUDA | only `elementwise` traces a closure and calls `to_kernel`; Metal impl round-trips inputs through the CPU | very active (09-24) | tang-gpu; March training half unused in tree |
| tang-tensor | CPU N-d array | 995 | CPU | none (README diagram is wrong) | stable | three Shape/tensor types in workspace |
| tang-optim | f64 optimizers | 507 | CPU | none | dormant, 0 real consumers | 4–5 Adam implementations |
| tang-train | CPU NN training, ~35 layers | 11,935 | CPU | none; module.rs says "use tang-expr directly" | lightly active (09-05) | copy in tang lacks conv/ctc; layers re-done in tang-gpu, tang-compute |
| tang-safetensors | loader to `Tensor<f64/f32>` | 453 | CPU | none | stable (04-11) | 3–4 safetensors readers |
| tang-hub | hf-hub download + f64 weights | 325 | none | none | stale (02-26), 0 dependents | 3 HF-cache walkers (tang-hub, tang-llm, frog) |
| tang-infer | CPU KV cache, sampler, GGML Q4/Q8 | 1,511 | CPU | none | stale (08-11) | LLM stack #2; tang-llm reimplements all three |
| tang-onnx | "TONX" graph model, no real ONNX | 1,374 | none | separate op enum | dead, 0 dependents | parallel graph IR |
| tang-mesh | iroh+tarpc: ship scalar WireGraph to wgpu workers; plus CPU "coded" transformer | 8,242 | wgpu (1 work item per dispatch), CPU | consumes IR (WireGraph mirrors 12 nodes) | stale (02-28), 0 dependents | LLM stack #3 (`inference.rs`, 3,152) |
| tang-3dgs | gaussian splatting rasterizer | 4,484 | wgpu | none; 4 declared tang deps unused | stable (09-03) | copy in tang has pre-fix Jacobian |
| tang-holo | talking-head pipeline (ffmpeg/python) | 2,195 | CPU | none | stale (03-11) | copy in tang |
| tang-sheffer | operator-search research | 7,965 | CPU rayon, opt wgpu | none; own trees and WGSL | dormant (04-14) | own evaluator |
| tang-sheffer-wasm | blog demo | 208 | wasm | none | frozen | none |
| tang-site-wasm | site demo | 352 | wasm | none | dormant | none |
| tang-bench | criterion suites | 3,429 | CPU, wgpu | benchmarks the IR | stable | never touched by LLM work |
| tang-llm | Qwen3/Gemma3 inference, chat templates, speculation, OpenAI server | 5,026 | Metal, CUDA (via tang-compute) | none: zero `tang_expr` references | very active: 25 commits since 09-22 | LLM stack #4 (the live one); own loader, sampler, cache |

**Dependency picture.** Sixteen crates depend on `tang` (for `Scalar`). tang-expr is consumed by tang-compile, tang-compute, tang-gpu, tang-mesh, tang-bench (tang-3dgs declares it, unused). tang-compute's only in-tree dependent is tang-llm; out of tree, `~/Developer/gaia` (gaia-infer, gaia-train) depends on it by path and uses the March training modules, and `~/Developer/phyz` (phyz-dream) by git rev behind an off-by-default `gpu` feature. tang-llm has no dependents in tang; frog consumes it as a spawned binary over HTTP (`apps/macos/scripts/build-engine.sh`, `crates/frog-engine/src/sidecar.rs`) and has no Cargo dependency on any tang crate.

**Velocity.** Since main's last commit (2026-09-09), all 33 commits (+10,796/-35) are in tang-llm (21 files) and tang-compute (8 files) plus lockfile. In the 90 days before that, work was in tang, tang-train, tang-la, tang-bench, tang-3dgs; tang-compute was untouched.

## 3. What the seams showed

### IR coverage for inference

- `crates/tang-expr/src/node.rs`: `Node` has 12 variants, all scalar f64. `codegen.rs` hard-codes `workgroup_size = 256`, one thread per work item, `n_inputs` f32 in, `n_outputs` f32 out, fresh output buffer. No shared memory, no integer or bit ops, no loops, no in-place writes.
- `crates/tang-compile/src/passes.rs`: `FuseElementwise::run` returns `(graph.clone(), outputs.to_vec())` with the comment that fusion "actually happens" in `to_wgsl`. `fusion.rs`: "Non-element-wise ops (like MatMul via Var nodes) act as barriers." Matmul is not representable; it can only appear as an opaque input.
- `crates/tang-compute/src/device.rs`: `elementwise` (lines 93-105) is the only IR entry; everything after the "Hand-optimized operations" header, including the 15 LLM methods at 878-1130 (`upload_q4`, `attention_prep`, `kv_attention_window`, `linear`, `swiglu_split`, ...), is a hand kernel from `kernels/*_msl.rs` / `*_cuda.rs` (24 MSL and 22 CUDA entry points in the `llm_*` files alone). Metal and CUDA override `add_tensors_buf`/`swiglu_fused_buf` with native kernels, so on the GPU decode path tang-expr is never executed.
- `crates/tang-llm/src/model.rs` `decode_layers` (391-465) is an imperative sequence of those calls; no graph object exists to serialize.
- Per op, what the IR lacks: embedding needs integer gather and bf16/Q4 dtypes; RMSNorm/softmax need reductions; GEMV needs nibble unpack, simd sums, register tiling; attention needs dynamic loop bounds and threadgroup memory; cache writes need mutation of a persistent buffer; the vision tower needs a host-side pool. Only the residual add and the silu/gelu math are expressible.
- Gates that any change must keep passing: `crates/tang-llm/tests/gpu_logits.rs` (GPU vs CPU max-KL over prefill + 4 decode steps) and `tests/speculate.rs` (drafting on/off bitwise identical).

### Duplication

| concept | copies |
|---|---|
| transformer forward | tang-train `layers.rs`, tang-gpu `llm.rs`, tang-mesh `inference.rs`, tang-llm `model.rs`, `tang-train/examples/smollm.rs` |
| KV cache | tang-infer, tang-train, tang-compute `modules.rs` (re-uploads on every read), tang-gpu, tang-llm `Cache<B>` (the only device-resident, prefix-reusable one) |
| sampler | tang-infer (f64, repetition penalty) vs tang-llm `sample.rs` (f32, xorshift) |
| Q4 | tang-infer GGML Q4_0 block 32, CPU only; tang-llm MLX affine group 64 with Metal/CUDA kernels; incompatible formats |
| safetensors | tang-safetensors, tang-gpu `safetensors.rs`, tang-llm `weights.rs` (mmap, sharded, native dtypes), plus the umbrella copy |
| HF cache walk | tang-hub (downloads, f64 only), tang-llm `resolve_model`, frog `models.rs:172` |
| Adam | tang-optim, tang-train, tang-3dgs, tang-sheffer, tang-gpu kernel, plus umbrella copies |
| GPU device/tensor | tang-gpu (wgpu) and tang-compute (Metal/CUDA): two traits, no shared code |
| the umbrella | `crates/tang/src/{la,ad,expr,gpu,compute,tensor,optim,train,safetensors,splatting,holo}`: 39,140 lines copied at f82c629 (2026-03-11), now drifted; no workspace crate, frog, or mew enables any of the 15 gated features |

### tang-mesh vs a frog node

tang-mesh is the one in-repo instance of "node receives a graph and evaluates it". `protocol.rs` `WireNode` mirrors the 12 tang-expr nodes; `worker.rs` compiles a WireGraph to WGSL and calls `KernelCache::dispatch(..., 1)`: one work item. RPC is tarpc over `tokio_serde::formats::Json` (the README's "postcard" claim is wrong for the RPC path). Its LLM-shaped code (`CodedInferenceServer`) is a CPU f32 transformer; the worker's GPU branch drops its buffers with "For now, use CPU path". No KV cache, loader, tokenizer, tang-compute dependency, or consumer. Last feature commit 2026-02-28.

Against ROADMAP "Your devices" (`docs/ROADMAP.md:186-209`), the node needs telemetry, model pull/load/unload, KV slots, priority queues, pairing, discovery, and a finish-time scheduler. tang-mesh has none of these; the reusable piece is iroh's Ed25519 endpoint identity for N3 pairing, which tang-llm can adopt directly.

### Consumers and release

- frog: `build-engine.sh` runs `cargo build -p tang-llm` against `TANG_DIR` (defaults to `../tang`, falls back to `../tang-kiln`), no `--features`, so it relies on tang-llm's `default = ["metal"]`. `sidecar.rs` spawns `tang-llm serve <model> --ctx N --port 8911` and polls `/v1/models`. Contract surface: that CLI shape, `/v1/models` (`data[].id`, `max_model_len`, `capabilities` incl. `thinking_budget`), `/props`, `/v1/chat/completions`. frog's `models.rs` also hard-codes `model_type == "qwen3"`, so Gemma 3 checkpoints tang-llm can run are invisible to frog.
- mew: CUDA host built with `--no-default-features --features cuda` (`crates/tang-llm/CUDA.md:28`).
- CI (`.github/workflows/ci.yml`): ubuntu only, `pull_request: branches: [main]`, `cargo build --workspace` minus the two wasm crates. PR #16 fails with E0455 (`core-graphics-types` via metal 0.33 via tang-llm's default feature). PRs #17-#20 target non-main bases and get no Actions runs.
- Publishing: tang 0.2.1, tang-la/ad/expr 0.1.1, tang-optim 0.1.1 on crates.io; everything else staged or `publish = false`. No tags, no CHANGELOG. Downstream users of the math crates (phyz, vcad, kosm) exist outside this repo.

### Prior art

Every comparable stack separates the LLM product from the tensor core and keeps kernels with the core: mlx-lm split from mlx-examples 2025-03-13 (https://github.com/ml-explore/mlx-examples/discussions/1344); mlc-llm over TVM (https://github.com/mlc-ai/mlc-llm); shark-ai over IREE (https://github.com/nod-ai/shark-ai); candle-transformers in-repo over candle-core with `CustomOp` for flash-attn (https://github.com/huggingface/candle). ggml is the exception, developed inside llama.cpp and synced out with `scripts/sync-ggml.sh`.

Every competitive decode path lets hand-written fused ops be graph nodes: ggml (`flash_attn_ext`, `rms_norm`, quantized matmul), MLX `mx.fast` and `metal_kernel`, MAX Mojo kernels, MLC via FlashInfer. The compile-everything stacks publish the gap: luminal reports trailing hand kernels with 10 min to 10 h compile per model (https://news.ycombinator.com/item?id=44963135); luminal's 15 primitives include SumReduce, MaxReduce, Gather, Scatter, Cast, exactly what tang-expr lacks. The KV cache is a runtime object outside the graph everywhere (llama_kv_cache views, MLC PagedKVCache, tinygrad `.assign`, JAX padded buffers). Graph-shipping nodes: ggml RPC is documented as "fragile and insecure" (https://github.com/ggml-org/llama.cpp/blob/master/tools/rpc/README.md); burn-remote streams per-op (https://docs.rs/burn-remote); petals is stalled (https://github.com/bigscience-workshop/petals/issues/633). exo 1.0 (Dec 2025) scaled with an MLX engine per node and RDMA over Thunderbolt 5 (https://www.jeffgeerling.com/blog/2025/15-tb-vram-on-mac-studio-rdma-over-thunderbolt-5/).

## 4. Recommendation

One repo, three explicit tiers enforced by CI and the README, not by moving code yet:

- **Tier A, math library** (published, ubuntu CI): tang (geometry core after 0.3.0), tang-la, tang-ad, tang-sparse, tang-expr, tang-tensor, tang-optim, tang-train, tang-safetensors, tang-hub, tang-bench.
- **Tier B, wgpu / research** (labelled experimental): tang-gpu, tang-3dgs, tang-holo, tang-mesh ("not the frog node"), tang-sheffer(-wasm), tang-site-wasm. tang-compile and tang-onnx are deletion candidates.
- **Tier C, inference product** (`publish = false`, macOS Metal + CUDA CI): tang-compute and tang-llm.

**IR:** tang-expr stays a scalar codegen IR. A **step plan** (`crates/tang-llm/src/plan.rs`, est. 400-600 lines) with one `Op` variant per existing hand kernel plus `Elementwise(ExprGraph)` and `Custom`, symbolic `rows`/`pos` dims so one plan serves prefill, decode and k+1 verify, `WeightRef`/`StateRef` resources, built from config (not recorded), serde-serializable and testable against `CpuDevice` in GPU-free CI. Hand kernels stay as the op bodies; the decode loop, sampler, prefix reuse, drafter, thinking budget and chat template stay on the host.

**Node:** `tang-llm node` = today's `server.rs` plus KV slots keyed by an `X-Frog-Session` header (LRU under a VRAM budget), two priority lanes, `/node` telemetry, `/models` list/pull/load/unload; `serve` stays an alias with the same port and routes. Nothing ships weights, KV or graphs. Only N6 (splitting a model across nodes) uses a plan cut at layer boundaries, and only if measured to beat the best single node.

**Split trigger** (do Phase 8 if any fires): tang's CI time or lockfile churn becomes the bottleneck; a second external consumer of the LLM surface appears; or six months pass with zero tang-expr codegen changes (a *go* signal; frequent lockstep changes are a *stay* signal).

### Verification verdicts

| claim | verdict | note |
|---|---|---|
| tang-expr is 12 scalar nodes with one 256-wide f32 elementwise kernel shape; cannot express RMSNorm, Q4 GEMV, split-KV attention, KV write | confirmed 3/3 | luminal needed 6 more primitives (reduce, gather, scatter, cast, iota) before it could; the hard part is the scheduler, not the node count |
| tang-llm never references tang_expr/tang_compile; tang-compute touches only `trace`, `to_kernel`, `Dialect`, `ExprId` | confirmed 3/3 | nuance: `Dialect` also backs `dialect()`; `ExprId` appears in trait defaults that Metal/CUDA override, so only `CpuDevice` reaches the IR at runtime |
| tang-compile: 0 consumers, 3 commits, no-op fusion, matmul as barrier | confirmed 3/3 | crate is 741 lines, not 746; lib.rs advertises a CSE pass that does not exist |
| `default = []` on tang-llm fixes PR #16's E0455 | **refuted 2/3** | the cfg-gated bin and `new_cpu()` arrive in #17 (commit 0ee10e9), not #16; #16's bin imports `MetalDevice` unconditionally. Also `tests/gpu_logits.rs` has no crate-level `#![cfg]`, so clippy `-D warnings` would still fail. Corrected in Phase 1 |
| CI is ubuntu-only, filters PRs to main, so #17-#20 get no checks | confirmed 3/3 | `gh pr checks` shows only Vercel/choji statuses on #17-#20 |
| CUDA graph capture is already implemented and would replace the every-4-layers flush | **refuted 2/3** | `begin_capture`/`end_capture` exist (cuda.rs:402-416) but are never called anywhere; on CUDA `flush` is the trait's no-op default, so there is no cadence to replace (the flush at model.rs:458 is Metal-only; vision.rs:146 also flushes). cudarc 0.16's `CudaGraph` has only `launch()`, no exec-update; `pos` is a by-value kernel arg; pool addresses are baked in; a pool miss during capture would panic. Realistic cost 1-2 weeks CUDA-only; llama.cpp's precedent is 1.1-1.3x on small models. Downgraded in Phase 6 |
| tang-la/tang-expr depend on tang, so umbrella re-exports cycle; 0.3.0 must be pure deletion | confirmed 2/3 | one verifier reproduced the cycle: Cargo rejects it even with the feature off. The dissent: serde_core/rand_core/burn-core precedent says extract a `tang-core` (only `Scalar` and the fixed-size types are imported by la/expr) rather than "must delete"; either is fine, deletion is cheaper |
| umbrella compute copy is stale, pins cudarc 0.12/metal 0.31, no in-tree consumer; deletion invisible to workspace, frog, mew | confirmed 3/3 | stronger than stale: the copy calls `CudaContext::new`, which does not exist in cudarc 0.12, so `tang/cuda` cannot build. README.md:289's `--all-features` command is already broken |
| tang-compute's tang-expr needs are met by published 0.1.1 | confirmed 3/3 | published tarball is byte-identical to the worktree. Caveat: after tang 0.3.0, tang-expr needs a republish against `tang ^0.3` before a split repo can use both |
| frog consumes tang-llm only as a spawned binary over HTTP | confirmed 3/3 | contract also includes `capabilities`, `max_model_len`, `/props`, and the `serve` CLI shape; frog's model list filters `model_type == "qwen3"` |
| tang-mesh cannot serve as the frog node | confirmed 3/3 | protocol.rs says "11 variants", the enum has 12; the coded path issues one JSON RPC per linear layer per replica |
| 100% of work since 09-09 is in tang-llm/tang-compute; tang-compute's sole dependent is tang-llm; split is mechanical | confirmed 2/3 | dissent found gaia (path dep, uses training modules) and phyz-dream (git rev 9d28b81, `gpu` feature off) depend on tang-compute out of tree; the recommendation's "check gaia does not build against a git dependency" would miss a path dependency. Phases 7 and 8 adjusted |

## 5. Phased plan

Every phase ships; frog keeps building and running throughout. Effort is an estimate from reading the code.

| phase | repo | effort | what it does | what frog gets |
|---|---|---|---|---|
| 0 | frog | 0.1 wk | `build-engine.sh` passes `--features metal` explicitly; `TANG_DIR` defaults to `../tang` once main has the crate | no more worktree hunt after Phase 1 |
| 1 | tang | 0.5-1 wk | unbreak CI and merge the stack. Either move commit 0ee10e9 (device selection + `new_cpu`) from #17 into #16, or merge #16 and #17 together; set `default = []`; add `#![cfg(any(feature="metal", feature="cuda"))]` to `tests/gpu_logits.rs`; drop `branches: [main]` from `pull_request`; add a `macos-latest` job with `--features metal`. Fallback: `--exclude tang-llm` on ubuntu plus the macOS job. Merge #16, #17, #18/#19, #20 (retargeted) | tang-llm on main; `kiln-llm*` worktrees can go; mew rebuilds from main |
| 2 | tang | 0.5 wk | README lists all 23 crates in three tiers; tang-mesh labelled; tang-llm README; tang-compute description corrected; dead Cargo deps removed; `GAIA_TF32`/`GAIA_SIMPLE_BWD` renamed with old names still read; CHANGELOG and tags | none directly; boundary becomes visible |
| 3 | both | 2 wk | KV slots (ROADMAP M1): `slots.rs`, `X-Frog-Session`, LRU under VRAM budget; frog provider sends the header. Gate: `speculate.rs` plus an interleaved-sessions test asserting zero re-prefill | zero-prefill turns across concurrent sessions |
| 4 | both | 2-3 wk | `tang-llm node` (N0): `/node`, `/models` (one cache walk shared with frog, pull, load with fit check, unload), priority lanes; `serve` as alias. frog: `ProviderKind::Node`, Devices pane; also lift the `qwen3` filter in `models.rs` | LAN nodes with telemetry and model management; mew switches from `serve` to `node` |
| 5 | tang | 1 wk (parallel with 3-4) | tang 0.3.0: delete the 11 vendored module dirs and 15 gated features; keep the geometry core and its 77 tests; check phyz/vcad/kosm for `features = [...]` on tang first; republish tang-expr against `^0.3` | nothing visible; removes the drifted 3dgs Jacobian and the uncompilable compute fork |
| 6 | tang | 2-3 wk | step plan: `plan.rs`; `decode_layers`, `forward`, `forward_hidden`, vision call through `Model::run`; CPU unit tests assert the Qwen3 vs Gemma 3 op lists. Metal: one command buffer per token instead of flush every 4 layers. CUDA graph capture is a separate, measured follow-up (needs static input/pos buffers, deterministic arena, per-row-bucket graphs, cudarc exec-update or raw sys calls); ship only if `bench-verify`/`bench-spec` show a win on the 3090 | a CPU-testable model description; the seam N6 needs; possibly single-digit to ~15% decode on CUDA |
| 7 | tang | 1 wk, optional | retire dormant stacks: tang-compile, tang-onnx; tang-compute's training half behind a `training` feature for one release, then delete **after repointing gaia's path dependency** (`~/Developer/gaia/crates/gaia-{infer,train}/Cargo.toml`) and confirming phyz-dream's pin; mark or delete tang-gpu `llm.rs` and tang-mesh `inference.rs`. One PR per deletion | none directly |
| 8 | both | 0.5-1 wk, on trigger | `git subtree split` (or `git filter-repo --path` for two dirs) of tang-llm + tang-compute into its own repo with `tang = "0.3"`, `tang-expr` from crates.io; same binary, features, port, routes; gaia and phyz re-pointed; macOS + self-hosted CUDA CI | `TANG_DIR` points at one repo |

Required (0-6): roughly 9-11 engineer-weeks, of which ~2 are CI and deletion, 4-5 are roadmap work frog needs anyway (M1, N0), and 2-3 are the plan. Frog's critical path is 0, 1, 3, 4; none of it waits on 0.3.0 or the plan.

Rejected: rewriting tang-llm on tang-expr/tang-compile (a tinygrad/luminal-scale project that both publish trails hand kernels); a published `tang-graph` IR crate with tang-mesh as the node (unstable op enum in the math workspace, plus a full rewrite of mesh); splitting now and closing #16-#20 (loses review threads and measured numbers, fixes none of the pain); umbrella feature flags as re-exports (package cycle); recording the plan by wrapping `ComputeDevice` (couples the plan to whatever the imperative path does); per-token graph shipping or a public GPU network (ROADMAP already decided against; ggml RPC, burn-remote and petals agree).

What this gives up: tang-llm stays a hand-scheduled kernel library with a Rust driver; the plan is an op list, not something tang-compile optimizes. Nodes are model servers, not evaluators. The two GPU stacks are not unified. tokio/axum/iroh stay in tang's lockfile until Phase 8. crates.io users of the umbrella's gated features, if any, lose them at 0.3.0.

## 6. Open questions

1. Does anyone on crates.io use `tang` 0.2.x with `gpu`/`compute`/`train` features? If yes, 0.3.0 needs a deprecation note; if the answer is unknowable, ship it anyway since the compute copy does not build.
2. gaia is dormant (last commit 2026-03-30) but path-depends on tang-compute's training half. Keep the training half alive for it, port gaia to tang-gpu, or let gaia pin an old commit?
3. Should frog nodes ever run non-LLM tang workloads (physics graphs, where tang-mesh's shape is right)? If yes, two node models coexist and the mesh transport needs a binary codec first.
4. Is a `tang-core` extraction (the serde_core pattern) worth doing so `tang` can become a facade again, or is the umbrella simply the geometry crate from 0.3.0 on?
5. What does capture actually buy on the 3090 for 8-12B Q4 models? Nothing here was measured; llama.cpp's numbers suggest 10-30% on small models and near zero on large ones.
6. N6 (splitting a model across nodes): hidden-state traffic per token at layer-boundary cuts was sketched, not sized, for a concrete model and link.
7. The `elementwise` Metal path round-trips through the CPU. Is it worth an on-device interleave (about two days) before the first hot tail needs it, or never?

# tang image generation: design (2026-10-05)

Roadmap item "Images" (Niceties): one `Image` tool, results in the lightbox. This plan covers the local path: text-to-image inside `tang-llm serve`, on the Mac first and on mew second. Image *input* already works (Gemma's SigLIP tower, `tang-llm/src/vision.rs`) and is not in scope.

Surveyed against `~/Developer/tang-serve` at e4ee81e.

## Decisions

- **A DiT, not a UNet.** Modern open models (Z-Image, FLUX, Qwen-Image) are transformers. They reuse tang's matmul and attention. A UNet (SDXL) would be mostly new conv kernels.
- **Z-Image-Turbo first.** It has 6B params, needs about 8 steps, and is Apache 2.0. Its text encoder is Qwen3-4B, which tang already runs. In bf16 it is about 12 GB plus about 8 GB for the encoder, so it fits the 64 GB Mac with room left for a coding model. FLUX.1-schnell (12B, T5 + CLIP encoders) comes second, for mew. Qwen-Image (20B) only comes later.
- **bf16 weights, no Q4.** Diffusion quality drops off much sooner than LLM quality under quantization. fp8 on CUDA is an option later.
- **The loop must be closed.** Generating images is the means. The point is an agent that generates a target, builds toward it, looks at the result, and keeps going until they match (section 7). Real-time generation is a cherry on top (section 8) and never blocks the loop.
- **The frog side ships first, on a stub backend.** Lock down the tool and the UX while the tang port is in progress.

## I0 implementation status

Implemented in frog: `Image` tool with explicit `[image]` configuration, PNG stub
placeholders and a remote OpenAI-compatible base64 backend. Existing `Output.images`
provides transcript/lightbox delivery and vision input. Generation uses its own session
permission key and emits start/completion progress. The remote path is tested through the real `frog --serve` executable against
local chat/image fixtures, including approval, denial, vision delivery, replay, errors
and cancellation. Native Frog testing verified thumbnails, lightbox navigation/zoom,
session reopening and byte-exact PNG export. A captured session backs the dark/light
snapshot and lightbox regression test. No paid service was called during validation.

The stub uses PNG rather than SVG so it exercises the raster attachment path. Remote
responses must contain `data[].b64_json`; URL fetching is deliberately unsupported.
Requests preserve prompt, dimensions, count and optional seed in durable tool events.
Remote reproducibility still depends on the provider. Requested seed/steps and returned
model/seed/steps/dimensions are retained in asset manifests, together with model hashes
when supplied by the backend. Tang fingerprints actual checkpoint bytes at resident load
and streams step progress with JSON fallback. The Apple API
adapter returns availability errors because its non-UI API is unavailable on macOS 27+.
Calibrated Tang step previews now reach the Frog transcript as bounded, replayable
image deltas. The latest approximate frame is replaced by final attachments and never
enters model vision context. Real eight-step generation verifies ordering, replay,
final-only vision input and byte-identical final PNGs with previews on/off. Native
protocol/replacement/cancellation tests pass; a running preview was visually inspected.
Final native replacement inspection remains pending because the Mac locked during
replay. General backend autodiscovery remains later work. See the README for limits.

## Native tang dependency status

[Tang PR #32](https://github.com/ecto/tang/pull/32) adds penultimate Qwen conditioning,
the Z-Image DiT, tiled VAE decode, static-shift Euler scheduling and a lazy resident
image worker. CPU and Metal reference checks cover every selected boundary, production
128-wide attention heads and 256×256 VAE output; maximum errors are below 1.1e-5 for
the DiT and 2e-5 for the VAE. These deterministic random checkpoints establish operator
parity. The pinned trained checkpoint passed real Frog generation at 320×192 and 512×512,
including all streamed steps and actual asset metadata. Native transcript and lightbox
display were inspected. Repeating seed 42 with the resident pipeline produced a byte-identical
PNG. One eight-step 320×192 request took 52.3 seconds including loading, its resident
repeat took 11.1 seconds, and 512×512 took 52.2 seconds. These individual smoke tests do
not establish broad quality or speed. The dependency now also mounts images in the chat/vision
service, retains both models and serializes heavy inference with a shared resource lock.
Real Frog generation passed against that combined service. A local Gemma 3 4B vision
judge passed the Screenshot/Compare integration and durable-stop test, but invented
some missing-letter differences; broad judge-quality validation remains unfinished.
Full trained DiT reference checks still fail at several late boundaries despite small
final-output error; deterministic random-checkpoint parity does not cover that failure.
An independent PyTorch math-versus-CPU-flash attention audit also fails the same
pointwise tolerance at ten late boundaries (final relative L2 about 5.9e-6). The
dependency retains these diagnostics rather than relaxing the acceptance bounds.

Fused Metal RMS scale and gated residual kernels reduce three resident 320×192
requests from 13.79/12.91/13.24 seconds to 8.68/8.74/8.75 seconds. The three fused
outputs are byte-identical; their largest RGB difference from the unfused output is
one channel value. A fused 512×512 request passes at 37.79 seconds.
Subsequent Metal group normalization, nearest upsampling and implicit tiled
convolution keep the VAE on device. Three resident 320×192 requests take
5.824/5.905/5.980 seconds, and 512×512 takes 24.534 seconds. The tested outputs are
byte-identical to the preceding device-normalization implementation, and all 83
Metal compute tests plus selected trained/random VAE references pass at unchanged
tolerances. Real Frog streaming and hash-manifest validation also pass at 128×128.
Final-layer channel modulation now stays on device and preserves the previous 256×256 PNG bytes, including a resident repeat. Native unary SiLU also preserves these final PNG bytes. Explicit VAE-calibrated latent
previews pass real generation and held-out projection checks; a resident 256×256 pair
measured 5.742 seconds with previews and 5.882 without. This pair does not establish a
general performance bound. Packing and the staged draft/refinement workflow remain open.

The local host has 48 GiB RAM. The public checkpoint was downloaded at pinned
revision `f332072aa78be7aecdf3ee76d5c247082da564a6`, with upstream LFS hash checks and
streamed F32-matrix conversion to BF16. This reduces disk output from about 32.8 GB to
20.5 GB while retaining 4 GiB headroom. No existing model or workload is evicted.

## L1 implementation status

Implemented: Screenshot with WebKit capture in frog-apple and configurable renderer
endpoint; Compare with full-image and worst-region crop vision judging plus local SSIM;
bundled visual-loop skill; persisted match/stall/round stops; new PNG asset output and
prompt/model/seed manifests. Real WebKit capture was exercised through frog --serve,
with a fixture vision judge; its scores are not evidence of production judge quality.
Native replay verifies retained screenshot output. Existing output files are never overwritten.
An optional Chromium sidecar now passes the real Frog Screenshot/Compare regression.
An optional workspace-contained SVG tracer now passes generated PNG → SVG → Chromium
→ local Gemma Compare, with the raster and tracing metadata retained. Photos are rejected
by default. Judge quality and cross-queue priority
scheduling remain unfinished. Shared image/vision residency is implemented in Tang PR #32.

## Current validation and open gates

Tang’s checkpoint attention scale is now applied to queries after normalization and RoPE. This matters for Gemma 3 27B (128-wide heads, attention scalar 168); 4B/12B use equal head dimension and scalar. CPU and CUDA-enabled LLM suites pass 56 tests (one ignored), including independently rescaled query-projection equivalence; CUDA compute passes 65 tests (one ignored). The corrected CUDA release build and Tang CI pass.

A pinned, upstream-hash-verified Gemma 3 27B checkpoint loads on mew with a 12,288-token context, one KV slot and a 2 GB KV budget. Real structured-response checks pass conflicting prompts, numeric bounds, invalid-schema rejection and streamed JSON. Frog accesses this test service through a loopback-only SSH tunnel; no user model was evicted. The autonomous generation → editable CSS → WebKit capture → Compare benchmark remains an open acceptance gate. Its first real comparison rejects a poor silhouette at 35/100; this is evidence of rejection, not convergence.

Frog now retains Image/Screenshot/Compare in compact project contexts, preserves the initial task and generated-target identity through compaction, and bounds verbose judge feedback. Compare additionally provides bounded plain-background pixel measurements (bounds, sampled disjoint row spans and dominant foreground color) to the judge and coder; measurements do not identify semantic objects or relax the score gate. The 198-test engine suite passes. The 8K compaction regression verifies the original target path and model-visible reference image after resume. Native replay also verifies distinct generated/captured image cards, target lightbox rendering, zoom and Escape dismissal. These integration results do not establish unattended coding or judge quality.

## Verified upstream corrections

The official [Z-Image-Turbo config](https://huggingface.co/Tongyi-MAI/Z-Image-Turbo/blob/main/transformer/config.json)
uses dim 3840, 30 attention heads and head_dim 128, with RoPE axis widths 32/48/48.
The [diffusers implementation](https://github.com/huggingface/diffusers/blob/main/src/diffusers/models/transformers/transformer_z_image.py)
uses RMSNorm, SwiGLU and scale/gate modulation with tanh gates, rather than the
simplified adaLN/GELU sketch below. The dependency adds a genuine penultimate-state
extraction path; the previously named forward_hidden returns logits. Trained-weight
validation is still required before claiming the complete local pipeline is finished.

Initial environment checks on 2026-10-05 found no image weights locally or in mew’s ComfyUI and less than 1 GiB of free VRAM on mew. A later read-only check found about 22.8 GiB free on its RTX 3090; the earlier availability constraint is obsolete.
The original checkpoint exceeded local free disk space; the streamed conversion above
addresses that download constraint. Apple ImageCreator returns notSupported
on this macOS 27.0.1 host, consistent with Apple's documented API removal. Do not
evict active workloads or silently switch to a paid endpoint to bypass these constraints.

## 1. What tang already has

The SigLIP vision tower (`Vision::project`) is a bidirectional transformer over image patches. Its op list is most of a DiT block:

| DiT needs | tang today |
|---|---|
| patchify + linear embed | `patches()` + `linear` (vision.rs) |
| bidirectional attention, ~4k tokens | `attention_full` → Metal `flash_prefill` (simdgroup tiled), CUDA impl exists |
| LayerNorm / RMSNorm | `layer_norm`, `rms_norm` |
| GELU / SiLU MLP | `gelu_tanh`, `elementwise` |
| bf16 weights | `upload_bf16` + `linear` |
| text encoder (Qwen3-4B) | `tang-llm` model; needs a "return hidden states" path (`forward_hidden` exists) |

## 2. What's missing

1. **adaLN modulation.** The timestep embedding (sinusoid → MLP) produces scale, shift and gate per block. `x * (1 + scale) + shift` and `x + gate * y` are fused elementwise ops, so start with `elementwise` and fuse later.
2. **2D/3D RoPE.** Position ids are (frame, row, col) instead of a single index. The existing rope kernel takes per-axis frequency bands, or this is a small new one.
3. **Joint text+image sequence.** Z-Image is single-stream (text and image tokens are concatenated into one sequence), so this is just a longer `n` passed to `attention_full`. Check that head_dim ≤ 128 so we stay on `flash_prefill`. **Verify against the config.**
4. **VAE decoder** (FLUX VAE, 16 latent channels, 8× upsample). It needs conv2d 3×3, GroupNorm(32), SiLU, nearest-neighbor 2× upsample, and one mid-block attention.
   - v0: conv as im2col + `linear`. That is memory-hungry at 1024² but correct, and it runs once per image.
   - v1: a real implicit-GEMM conv kernel in MSL.
   - GroupNorm is `layer_norm` over reshaped groups, a small kernel.
5. **Scheduler.** Flow-matching Euler with Z-Image's shift schedule. About 30 lines on the host, no GPU work.
6. **Weights.** Load diffusers safetensors (`tang-safetensors` exists) and map the names in a new `dit.rs` + `vae.rs` next to `vision.rs`.

## 3. Cost and speed (estimates)

- Per step: 6B params × ~4.3k tokens (4096 image + ~200 text) ≈ 2 × 6e9 × 4.3e3 ≈ 52 TFLOP. M4 Max at about 30 TFLOPS bf16 effective is about 2 s/step, so **about 15–20 s per 1024² image** at 8 steps. 512² is about 4× faster.
- On a 3090 (about 70 TFLOPS effective): about 6–8 s per 1024² image.
- So this is not grok-imagine instant. For a fast feel, preview a 512² draft and then upscale/refine the image the user picks, and stream intermediate latents (a cheap linear latent→RGB preview each step).

## 4. tang-llm API

- `POST /v1/images/generations` uses the OpenAI shape: `{model, prompt, size, n, seed, steps}` → `{data:[{b64_json}]}`. It also takes an `x-frog-progress` SSE mode that streams `{step, of, preview_b64}`.
- The image model loads lazily and is listed in `/v1/models` with `"type":"image"`. Under the node design ([2026-10-04](2026-10-04-frog-node-design.md)) it is just another model with a memory footprint, and the free-memory rule applies.
- The text encoder shares weights with a loaded Qwen3-4B chat model when one is resident.

## 5. frog side

- **`Image` tool** (`tools/image.rs`, modeled on `Diagram`) with input `{prompt, size?, seed?, count?}`. The output puts the picture in `Output.images`, which already exists and is used for MCP results, so **no protocol change**. The model sees a short text confirmation plus the image if it has vision.
- **Backends, in order of preference:** `tang/<image-model>`, Apple `ImageCreator` (`frog-apple` sidecar), a remote OpenAI-compatible images endpoint, then a stub (SVG placeholder) for tests.
- **Progress:** tool progress events already exist for long tools. Map the tang SSE steps to them so the lightbox shows the image sharpening.
- **Edits/i2i** come later: Z-Image-Edit or Qwen-Image-Edit, with `Block::Image` from the transcript as the source.

## 6. Phases

| # | where | size | ships |
|---|---|---|---|
| I0 | frog | 2–3 d | `Image` tool, stub + remote backend, lightbox + progress |
| I1 | tang | 3–5 d | Z-Image DiT forward on Metal, checked tensor-for-tensor against diffusers (fp32 CPU reference) at 256² |
| I2 | tang | 3–5 d | VAE decode (im2col v0), scheduler, `/v1/images/generations`; first real image |
| L1 | frog | 1 wk | **closed loop v1**: `Screenshot` tool + `Compare` judge + loop skill (section 7). Can run on the I0 remote backend before I2 lands |
| L2 | frog | 1 wk | asset loop: icons and sprites written into the repo, vectorized to SVG where it fits |
| I3 | tang | 1 wk | speed: fused adaLN, conv kernel, latent previews, 512² draft mode |
| L3 | both | 3–5 d | loop speed: judge and generator stay resident in one tang process, crop-level compares |
| I4 | tang | 1 wk | FLUX.1-schnell on CUDA for mew (T5 encoder is the new part) |
| R1 | tang | 2 wk | cherry: real-time draft mode (section 8) |

## 7. The closed loop

The agent generates a **target**, builds toward it, **looks** at what it built, and iterates until a judge says they match. Both halves run locally in one tang process: the DiT draws and the vision tower (SigLIP, Gemma) sees.

```
prompt ──▶ Image (target.png) ──▶ user picks / approves
                                      │
             ┌────────────────────────▼───────────────┐
             │ edit code ─▶ dev server ─▶ Screenshot   │
             │      ▲                        │         │
             │      └── fix list ◀── Compare(target, shot)
             └──────────── until score ≥ bar or N rounds┘
```

**Pieces:**
- **`Screenshot`.** Renders a URL (the dev-server preview pane from the roadmap) or a file (SVG, HTML, a game frame) to PNG at a fixed viewport. Headless WebKit on the Mac via `frog-apple`. Headless Chromium elsewhere.
- **`Compare`.** Takes `(target, actual)` and returns `{score, diffs:[{region, issue, fix_hint}]}`.
  - The judge is a vision model given both images side by side, plus crops of the regions that differ most.
  - A cheap pixel/SSIM pass on a downscaled pair picks those regions, so the VLM looks where it matters instead of only at a blurry whole.
  - Score from both: the VLM rubric (layout, color, type, spacing, content) and SSIM as a sanity floor.
- **The loop skill.** A harness mode: target, implement, then up to N rounds of screenshot → compare → fix.
  - It stops when the score clears the bar, when the score stalls for two rounds, or after N rounds. It never loops silently: every round's screenshot lands in the transcript as an image, so the user watches it converge.
- **Target ≠ spec.** Generated mocks contain text that isn't real and layouts that can't be built. The judge is told to match *structure and style*, not to copy hallucinated details. The user can annotate the target ("ignore the logo") before the loop starts.

**Uses, in order:**
1. **UI from a picture.** "Make settings look like this." The picture is generated or pasted, the loop is the same.
2. **Assets.** Icons, sprites, illustrations: generate, critique with vision against the brief, regenerate, write the files to the repo (SVG via trace where it fits).
3. **Visual regression.** The approved screenshot becomes the target, so any later change that drifts from it is flagged by the same `Compare`.

**Done when:** a bench task (frog-bench) goes from a generated target to a page that scores ≥ the bar, fully local, unattended, and the rounds are visible in the session log. Images are durable events, storing prompt, seed, model hash and steps, so any round is reproducible and `--fork` can branch from it.

## 8. Cherry on top: real time

Redraw on every keystroke at low resolution, then do a full render on enter.
- **Budget:** 256² is 256 image tokens. A 1–2 step distill of a 6B DiT is about 3 TFLOP, roughly 0.1–0.2 s on the M4 Max. That is interactive.
- **Needs:**
  - a few-step distill (LCM/DMD-style, trained with `tang-train` on mew)
  - text-encoder caching by prompt prefix
  - a tiny latent→RGB decoder instead of the full VAE for drafts
- It plugs into the loop as a faster target picker, nothing more. Ship it only if it holds under 250 ms per frame.

## Open questions

- Is Z-Image's head_dim within `flash_prefill`'s ≤128 limit? Check the config before I1.
- Is the im2col VAE at 1024² (about 128×128×512 channels × 9) too big for memory? Fall back to tiled decode if so.
- Should the agent generate images unprompted (UI mocks, icons), or only when asked? Start with only when asked, with the default permission ask.

## Follow-up: judge-led scoring blocks convergence (2026-10-06)

The autonomous benchmark is deferred, not passed. Re-scoring the six rounds of the Gemma 3 27B run (`frog-unattended-gemma27-repeat-compaction-1`) shows that the judge, not the coder, prevents convergence:
- Judge scores were 55/65/55/65/35/45. The pooled foreground IoU ranked the same rounds 0.53/0.50/0.64/0.64/0.63/0.63, and visual inspection agrees with the IoU ordering.
- `score = min(judge, ssim+20, overlap+20)` lets judge noise set the score.

Proposed next step: for plain-background targets, derive the score from the measured geometry and color, and keep the VLM for the fix list and as a veto on gross content mismatches. This changes what the acceptance bar means, so it needs an explicit decision before it lands.

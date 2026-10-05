# tang image generation: design (2026-10-05)

Roadmap item "Images" (Niceties): one `Image` tool, results in the lightbox. This plan covers the local path: text-to-image inside `tang-llm serve`, on the Mac first and on mew second. Image *input* already works (Gemma's SigLIP tower, `tang-llm/src/vision.rs`) and is not in scope.

Surveyed against `~/Developer/tang-serve` at e4ee81e.

## Decisions

- **A DiT, not a UNet.** Modern open models (Z-Image, FLUX, Qwen-Image) are transformers. They reuse tang's matmul and attention. A UNet (SDXL) would be mostly new conv kernels.
- **Z-Image-Turbo first.** It has 6B params, needs about 8 steps, and is Apache 2.0. Its text encoder is Qwen3-4B, which tang already runs. In bf16 it is about 12 GB plus about 8 GB for the encoder, so it fits the 64 GB Mac with room left for a coding model. FLUX.1-schnell (12B, T5 + CLIP encoders) comes second, for mew. Qwen-Image (20B) only comes later.
- **bf16 weights, no Q4.** Diffusion quality drops off much sooner than LLM quality under quantization. fp8 on CUDA is an option later.
- **The frog side ships first, on a stub backend.** Lock down the tool and the UX while the tang port is in progress.

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
| I3 | tang | 1 wk | speed: fused adaLN, conv kernel, latent previews, 512² draft mode |
| I4 | tang | 1 wk | FLUX.1-schnell on CUDA for mew (T5 encoder is the new part) |

## Open questions

- Is Z-Image's head_dim within `flash_prefill`'s ≤128 limit? Check the config before I1.
- Is the im2col VAE at 1024² (about 128×128×512 channels × 9) too big for memory? Fall back to tiled decode if so.
- Should the agent generate images unprompted (UI mocks, icons), or only when asked? Start with only when asked, with the default permission ask.

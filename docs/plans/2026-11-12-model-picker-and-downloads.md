# One model picker, Settings › Models, and downloads

Status: scoped 2026-11-12. Not started.

## Rules

- What you pick is what runs. No "Automatic", and Frog never moves a turn between local and cloud on its own.
- Every machine is a node running one model. This Mac is a node like any other.
- Colour: local blue, cloud green, from `Color.place` / `placeColor` (frog#290).

## 1. The composer picker (frog: Mac + web)

- One menu replaces the device chip and the map popover. The pill reads `Qwen3-8B · mew`, with a blue or green dot.
- Groups: "Your machines", then "Frog Cloud" (hidden when Settings turns cloud models off).
- Each local row shows the machine and what picking it does: nothing (it's running), "swaps" (the node holds another model), "loads" (the node is idle).
- When two nodes run the same model, the row lists both and the scheduler picks the less busy one.
- Cloud rows show the price per million output tokens.
- Picking a model runs `/models/load` on its node. The pill shows a spinner and "loading" until the node reports ready.
- If the node is busy (409), the row shows "swaps after this turn" and frog retries once the node goes idle. If another session was using that node, that session gets a one-line notice ("mew switched to Qwen3-8B").
- Footer: "Manage…" opens Settings › Models.

## 2. Settings › Models (frog: Mac + web)

- **Machines**: one row per node (hardware, plus the running model and tok/s, or "idle"), then "Pair a machine".
- **Machine page**:
  - status and a memory bar;
  - **Models**: what's on disk, with a radio to swap, Stop for the running one, Delete for the others, and "Download a model";
  - **Node**: "Share with my other machines", Rename, and Unpair (every node except This Mac).
- **Frog Cloud**: account, credit, Add credit, and "Show cloud models in the picker".
- Removed: the device chip, the map popover, and the Devices window. Advanced actions now live on the machine page.

## 3. Download a model

### What tang supports today

| | Today |
|---|---|
| Where it loads from | Only the Hugging Face cache or a folder on that machine |
| Format | Safetensors plus `config.json`, `tokenizer.json`, `tokenizer_config.json` |
| Families (generic path) | Qwen3 dense, Qwen3-VL, Gemma 3, gpt-oss. Needs verifying on mew. |
| Precision | MLX 4-bit loads as stored; others convert when loading |
| GGUF | Only in fixed Flash mode, which can't swap |
| Qwen3 Coder Next, GLM, DeepSeek | Our cloud GPU paths only, never local |
| Fit check | `node::need`: weights + 8k-position KV + 1 GB scratch |
| Listing | `/node` reports `on_disk` |
| Download | None in tang (we build it, from R2). Frog's `setup.rs::download_model` downloads to this Mac only: no resume, no progress to the app. |

### What we build

1. **tang `POST /models/pull {model}`**
   - Moves frog's downloader into tang, writing the HF cache layout.
   - Resumes from `.part` files with HTTP Range requests.
   - One pull at a time per node.
   - `/node` reports `pulling: {model, done_bytes, total_bytes}`.
   - `DELETE /models/pull` cancels a pull; `POST /models/delete` removes a model that isn't running.
   - Hugging Face's API lists file sizes before anything downloads, so the node refuses a pull up front if the model won't fit in its memory or on its disk.
   - Pulls come from our R2 mirror (below), not from Hugging Face. Each file is checked against its sha256 before the snapshot counts as on disk.
2. **Weights on R2**
   - We host the files, so downloads don't depend on Hugging Face uptime, rate limits or a repo being renamed or deleted. R2 doesn't charge for egress.
   - Bucket `frog-weights`, served from `weights.frog.toys`. Same layout as the HF cache: `<org>/<name>/<sha>/<file>`. Range requests work.
   - A mirror script copies a pinned HF revision to R2 and writes each file's sha256 and size into the catalog. It runs on a RunPod pod, not the Mac.
   - Only mirror models whose licences allow redistribution:
     - Qwen3 and gpt-oss are Apache-2.0;
     - Gemma's terms require passing the licence along, so ship its `LICENSE` file with the weights.
   - Hugging Face remains only the mirror script's source.
3. **A curated catalog**
   - A small JSON file shipped with frog, so the list can change without a tang release.
   - Starts with `mlx-community/Qwen3-{0.6B,4B,8B,14B}-4bit` plus whatever the family check passes.
   - Each entry: id, display name, family, and weight bytes.
   - Browse shows only entries whose family the node supports. It labels each one "fits" or "too big" using the same check as `node::need`.
4. **Frog's first-run setup uses the same downloader**, so there's one code path.

### Out of scope for now

- Pasting an arbitrary Hugging Face link (most repos are GGUF or an unsupported family).
- Swapping GGUF models.
- Several models loaded per node.
- Moving a hot session between nodes.

## Order

1. **tang**:
   - verify each family loads on mew and the Mac;
   - set up the `frog-weights` R2 mirror and its script;
   - add `/models/pull` (from R2), its cancel and `/models/delete`;
   - add `pulling` to `/node`;
   - document it all in `docs/node-protocol.md`.
2. **frog** (after frog#290 merges): the picker and Settings › Models, using `on_disk` and `pulling`. "Download a model" stays hidden until tang ships pull.

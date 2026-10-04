# frog node: design (2026-10-04)

Bet 3, "your devices, additive". The first slice proves it on one real setup: the Mac (M4 Max, 64 GB) and mew (RTX 3090, 24 GB) over Tailscale, used together automatically. Install, discovery and pairing stay manual for now (Tailscale names plus an API key, as mew is set up today). Background and principles are in [ROADMAP.md](../ROADMAP.md), "Your devices".

## Decisions

- **The first win is Mac + mew used automatically**, not a nicer single shared GPU and not new-user onboarding.
- **The picker lists models, not machines.** A request for a model goes to any node that has it, or can load it, and would finish first. It never quietly swaps in a different model.
- **The scheduler lives in the frog engine.** Nodes are compute only: no shell, no files. frog owns the transcript, so failover is re-prefilling on another node.
- **Loads only into free memory.** The scheduler may load a model on a node when it fits in free VRAM or RAM. It never evicts another model or another process's memory (mew also runs Frigate, Sunshine and benchmark jobs).
- **Bigger models: speed first, capacity later.** First, cross-node speculative decoding. Later, a pipeline split for models neither machine holds alone.
- **The drafting loop runs tang-to-tang.** It's the one exception to the engine orchestrating, because one round is too tight for extra HTTP hops through the engine. The engine still decides when to draft and with which node.

## 1. Node API (N0, in tang-llm)

Each machine runs `tang-llm serve` as today. It gains these endpoints:

- **`GET /node`, read-only:**
  - node id and version
  - hardware: GPU kind, total and free VRAM or unified memory
  - models loaded and on disk, with size and load time
  - measured prefill and decode tok/s per loaded model, as moving averages over real requests
  - queue: running and waiting requests, with lengths
  - KV: the block hashes held in memory and on disk (a list or a Bloom filter), and each `prompt_cache_key`'s cached length
- **`POST /models/load` and `/models/unload`,** with a fit check against free memory.
- **A priority queue.** `x-frog-priority: interactive | background`. Interactive goes first. Background work (warming, compaction, subagents, benches) yields between prefill chunks.

## 2. Scheduler (frog engine)

- **Config:** a `nodes` list (address and API key). A `tang/<model>` profile names a model; the node set is wherever that model is loaded, or can load into free memory.
- **Polling:** each `/node` about once a second while frog is active, backing off when idle. A node is marked down after two missed polls.
- **Placement:** for each model call, finish = queue wait + uncached prompt ÷ prefill rate + expected output ÷ decode rate + round trip (+ load time). The earliest finish wins.
  - The uncached prompt comes from the node's block hashes, so KV affinity needs no special rule.
  - Expected output is a moving average per step kind: short for tool calls, long for answers and big writes.
- **Ties:** results within about 10% count as a tie, and the node holding the KV wins. That stops conversations flapping between machines on noise.
- **Background work** only goes to nodes whose interactive queue is empty.
- **Warming** (`/v1/prefill`: on open, while typing, after a turn-end prune) targets the node predicted for the next turn.
- **Failover:** a node that drops mid-call means a retry on the next-best node. Never retry after a tool with side effects has run.
- **What the user sees:** each turn is tagged with where it ran ("on mew" or "on Mac"). A Devices pane comes with N2.

## 3. Proof: `frog bench --nodes`

- **Configurations:** Mac only, mew only, both, and both with one node killed mid-task (stopped, or with traffic dropped to simulate a hang). The same suite runs in each, 5 repeats.
- **The suite:** multi-turn scenarios with per-call prefill accounting (from the zero-prefill bench), plus a fan-out task with 3–4 read-only subagents.
- **Three gates:**
  1. No task's median or p95 is worse than the best single node for that task.
  2. Fan-out is at least 1.6× faster on two nodes.
  3. Killing a node still finishes the task with the same answer.
- **Fault-injection shim** in the provider path: adds latency, throughput caps and drops, so CI can run without a second machine.
- **Default:** `nodes.schedule` stays off until all three gates pass on the Mac + mew.

## 4. Cross-node speculative decoding

The big model runs whole on one node (the verifier). Another node runs a small model with the same tokenizer (the drafter, e.g. Qwen3-0.6B for Qwen3).

- **One round:**
  1. The drafter drafts k tokens (about 8) and sends their ids to the verifier.
  2. The verifier checks all k in one forward pass, about 2× the cost of one decode.
  3. It returns how many it kept, plus one corrected token.
  4. While the verifier checks, the drafter keeps drafting ahead.
- **Network cost:** one round trip per round, so LAN or Wi-Fi latency (1–3 ms) is small next to a big model's verify pass.
- **The local suffix drafter goes first,** because it's free and strongest on edits. The remote drafter covers the rest.
- **tang to tang:** the verifier calls the drafter's new `/v1/draft` endpoint directly. Acceptance stats come back in usage.
- **When it's used:** the engine pairs verifier and drafter per request. The finish-time estimate has a "with drafter" variant based on measured acceptance, and drafting is used only when that variant wins.
- **Expected gain:** 1.5–2× decode on long generations. Unmeasured.

## 5. Later

- **Pipeline split.** Layers are divided by memory and speed, over wired LAN only. It's for models in the band too big for the Mac but small enough for both together, about 50–80 GB at 4-bit. Prefill pipelines in chunks; decode pays one hop per token. It ships only for models no single node can run, or if it beats the best single node.
- **N1–N3:** installer, service, GPU detection, Bonjour discovery, pairing (SPAKE2, pinned Ed25519 keys, mutual TLS), and the Devices pane.
- **N5:** pulling models from the Mac.

## Build order

1. **N0** in tang: `/node`, loads, the priority queue.
2. **The scheduler** in the engine.
3. **`frog bench --nodes`** and its gates.
4. **Remote drafting:** tang's `/v1/draft` plus the engine pairing.

Then pipeline split, N1–N3 and N5.

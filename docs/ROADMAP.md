# Roadmap

Ordered by leverage. Each item cites the evidence behind it.

## 1. Protocol hardening: done

- **Separate durable facts from ephemeral deltas.** Text and tool-progress deltas are never persisted. Only completed items are. opencode's database grew to 13GB because 87% of it was `message.updated` snapshots, and its shell progress alone wrote 1.1GB ([opencode#33356](https://github.com/anomalyco/opencode/issues/33356), [#38020](https://github.com/anomalyco/opencode/issues/38020)).
- **Use an envelope `{seq, session, created, event}`** plus `Op::Subscribe { after }` and a `synced` marker, so clients can replay the log and then follow it live ([opencode#35015](https://github.com/anomalyco/opencode/issues/35015)).
- **Give items a lifecycle `started → delta* → completed`,** following the Thread > Turn > Item model in codex-rs's app-server.
- **Report a typed turn-end reason:** `complete | length | overflow | incomplete | cancelled`. Never accept an incomplete stream as done, and never retry after a tool has had side effects ([opencode#48454](https://github.com/anomalyco/opencode/issues/48454)).
- **Use a closed error enum** instead of free-form strings ([opencode#35021](https://github.com/anomalyco/opencode/issues/35021)).
- **Keep the item shapes compatible with ACP v2's patch semantics,** so a `kiln-acp` adapter can map to them without losing anything.

## 2. Event-log sessions: done

Sessions are now an append-only JSONL log: a versioned header, then durable events interleaved with history ops (`push`, `extend`, `reset`).

Shipped:
- resume by folding the history ops back into the message list
- `Op::Subscribe { after }` → `synced` for replay
- `--fork <id>@<turn>` to branch a session
- `--sessions` to list them
- `flock` so only one process writes a session
- torn-tail tolerance and mid-turn crash repair

Still to do:
- a `/fork` command in the TUI
- pruning or compacting old logs
- exporting logs as `kiln bench` datasets

## 3. Context as a budget: done

Shipped:
- a pre-call budget check with a calibrated chars→tokens estimate
- window probing (ollama, llama.cpp, LM Studio, vLLM)
- deterministic pruning: stale reads first, then old output, with hysteresis between 60% and 45%, logged as `Record::Replace`
- LLM compaction only past 80%, at most once per turn, rejecting empty summaries
- the user's messages pinned verbatim through compaction
- no synthetic "continue" turns
- unknown usage reported as unknown instead of zero

Evidence: [2609.20804](https://arxiv.org/abs/2609.20804), [2606.11213](https://arxiv.org/abs/2606.11213), [2606.22528](https://arxiv.org/abs/2606.22528), [2608.22752](https://arxiv.org/abs/2608.22752), [opencode#49965](https://github.com/anomalyco/opencode/issues/49965), [#40908](https://github.com/anomalyco/opencode/issues/40908).

Still to do:
- measure how often pruning fires, and how much it saves, in `kiln bench`
- try evicting whole finished sub-tasks (the episode eviction from 2606.11213) once sub-agents exist

## 4. Adapt the harness to the model: first pass done

The same model's results vary 40–139x in tokens and up to 30 points in score depending on the harness ([2607.22585](https://arxiv.org/abs/2607.22585), [2608.08654](https://arxiv.org/abs/2608.08654), [2609.17394](https://arxiv.org/abs/2609.17394)).

Shipped:
- **Capability probes**, cached per model: native tools, text tools, grammar JSON, and whether the model answers directly when no tool is needed. Run them with `--probe`. Unreachable models fail the probe instead of being cached as incapable.
- **`json` tool mode:** a grammar-constrained `{thought, action}` reply, with one tool branch per tool plus an answer branch ([2609.23742](https://arxiv.org/abs/2609.23742), [2608.13959](https://arxiv.org/abs/2608.13959)).
- **Tiers** (strong, medium, weak) from probe results and parameter count. They drive the `auto` mode choice and the planning guidance in the prompt ([2609.20804](https://arxiv.org/abs/2609.20804)).
- **Fallback during a session** to text mode after two format failures, and the cache is updated.
- **Loop guard:** the 3rd identical call is refused, the 5th ends the turn. Plus a 60-step limit per turn ([opencode#45442](https://github.com/anomalyco/opencode/issues/45442)).

Observed: `qwen2.5:3b` produces perfectly valid JSON-mode output but still picks the wrong tools, as 2609.23742 predicts. The loop guard turned a 5-minute hang into a 26-second `looping` stop.

Still to do:
- **Validate with a capable local model** such as `qwen3-coder:30b` through `kiln bench`. Tier thresholds and prompt guidance are guesses until measured.
- **Choose tools by tier.** Strong models do as well or better with bash alone.
- **Shorter system prompt for the weak tier.** Global `CLAUDE.md` files add a lot of tokens.
- **Stay on JSON for arguments.** Compact formats cost 9–14 points of accuracy ([2605.29676](https://arxiv.org/abs/2605.29676)).

## 5. Standards

| | verdict |
|---|---|
| MCP client (2026-07-28 spec, rmcp 3.x; also accept 2025-11-25 servers) | done |
| ACP adapter (`kiln --acp`, v1) for Zed, JetBrains, and Neovim | done |
| Agent Skills (`SKILL.md`), loaded progressively | done |
| AGENTS.md | done |
| OpenTelemetry GenAI spans (behind a feature flag) | nice |
| A2A, AG-UI | skip |

The MCP-vs-CLI study found that harnesses using only bash were 5–28x cheaper ([2608.08654](https://arxiv.org/abs/2608.08654)), so MCP should stay opt-in and never be required.

## 6. Security

- **Enforce at dispatch, in deterministic code, not in the prompt.** Track where each value came from, and only let values from trusted sources flow into tools with side effects ([2503.18813](https://arxiv.org/abs/2503.18813), [2608.27496](https://arxiv.org/abs/2608.27496), [2607.24625](https://arxiv.org/abs/2607.24625)).
- **Add an OS sandbox,** using seatbelt on macOS and bubblewrap on Linux (the codex-rs approach). Matching command strings is not a security boundary ([opencode#49948](https://github.com/anomalyco/opencode/issues/49948)). macOS is done: Bash is sandboxed by default. It can write only to the project, temp folders and toolchain caches, and credentials are unreadable. Sandboxed commands run without asking, and leaving the sandbox (`unsandboxed: true`) always asks. Linux (bubblewrap) is next.
- **Quarantine suspicious MCP tool descriptions** ([2606.20922](https://arxiv.org/abs/2606.20922)). Done: descriptions that look like injection, or that hide Unicode, are withheld unless the server has `trust = true`.

## 7. Sub-agents for context folding, not role-play

First pass done: `Task` runs a read-only child engine and returns its report. It has a 30-step budget, keeps the loop guard, and interrupting the parent stops the child.
Next:
- Work agents in git worktrees that return a diff for review.
- Forking the tang KV cache so a child starts from the parent's context.
- Routing each kind of subagent to a suitable model.
- Running subagents in parallel.

A sub-agent works in its own branch and returns only a summary to the parent. Context-Folding got a 10x smaller context with equal or better results ([2510.11967](https://arxiv.org/abs/2510.11967)). Sub-agents need an `Op::Cancel{id}`, step and token budgets, and detection of repeated calls. opencode had a sub-agent make 364 identical grep calls ([opencode#45442](https://github.com/anomalyco/opencode/issues/45442)). Multi-agent teams by default are not supported by the evidence ([2503.13657](https://arxiv.org/abs/2503.13657), [2609.13890](https://arxiv.org/abs/2609.13890)).

## 8. `kiln bench`: first pass done (moved up because every other item needs measuring)

Shipped:
- the `kiln-bench` crate, which drives the engine protocol headless
- a suite of 6 tasks, each check verified to fail untouched and to pass with a reference fix
- the matrix: models × modes × repeats
- JSONL results, a summary table, a task grid, and session logs for replay
- per-turn usage totals in the protocol
- the `--sandbox` workspace confinement it needs (macOS seatbelt for Bash; Write/Edit path checks)

Still to do:
- harder, multi-file tasks, plus tasks where the right move is to ask or do nothing
- report idle turns (a model call with no tool call and no progress) as a cost ([2607.22585](https://arxiv.org/abs/2607.22585))
- best-of-N selection using structured trajectory summaries ([2604.16529](https://arxiv.org/abs/2604.16529), [2601.22129](https://arxiv.org/abs/2601.22129))
- a Linux sandbox using bubblewrap

## 9. Our own inference: `tang-llm` sidecar, first pass done

Instead of depending on ollama, kiln can run models itself through `tang-llm serve`, which is built on tang's compute stack (`tang-compute` Metal kernels). `tang/<model>` profiles start it on demand.

Shipped:
- Qwen3 dense models from safetensors, in bf16. Logits match transformers to 3e-4 on 0.6B and 4B.
- flash-decoding attention, a device-resident KV cache, and prefix reuse across turns
- an OpenAI-compatible API: streaming, `reasoning_content`, `tool_calls` parsed from `<tool_call>`, `/props` for the context window
- the model's own Jinja chat template

- 4-bit MLX checkpoints (`mlx-community/*-4bit`) loaded directly, plus `--q4` quantization at load. Logits match mlx-lm.
- fused Q/K/V and gate/up projections, one-dispatch attention prologue (q/k norm, RoPE, KV write), tiled flash attention for prefill

Speed on M4 Max:

| model | decode | 2k-token prefill |
|---|---|---|
| Qwen3-0.6B bf16 | 202 tok/s | |
| Qwen3-4B bf16 | 50 tok/s | |
| Qwen3-4B 4-bit | ~105 tok/s | ~790 tok/s |
| ollama qwen3:4b Q4_K_M | ~128 tok/s | |

A second sidecar, `kiln-apple`, puts Apple's on-device Foundation Model behind the same API. kiln's JSON tool schema runs as guided generation (`DynamicGenerationSchema`), so every reply is a valid action.

Next:
- close the decode gap: fuse the residual add into the down/o GEMVs; f16 KV cache
- bigger prefill tiles (64x64, bf16 in threadgroup memory)
- grammar-constrained decoding in tang-llm for `json` tool mode
- MoE (Qwen3-30B-A3B)

## 10. Diagrams: first pass done

Shipped:
- The `Diagram` tool: typed JSON, validated and laid out in the engine (layered flows, sequences), with Mermaid in and out.
- Native rendering in the Mac app: cards, pop-out windows, exports, and the session tree. Box art in the terminal.

Next:
- ~~Code-derived maps~~: done (`CodeMap`, `kiln --map`, Map Project), with git churn heat. Still to do: callers of a single function, and edge bundling for very dense maps.
- State and ER diagram kinds.
- Diagrams that update in place across turns, pinned as a card.
- Hold weak models to the schema with grammar-constrained generation when they call Diagram.

## Computer use

First pass done: the `kiln-desktop` MCP sidecar.
- It reads windows as Accessibility elements first and uses screenshots as a fallback.
- Actions go to elements in the background.
- Every action returns the refreshed element list and how much changed.

Next:
- A local grounding model (Holo3.1, Apache-2.0, 4B/9B GGUF) so the agent can act in canvas apps that expose no elements.
- Screenshots for vision-capable models.
- Recording successful runs and replaying them.
- LocalLSTC-style subgoal state kept outside the context ([2608.25777](https://arxiv.org/abs/2608.25777)).
- Running computer use as a subagent.
- An optional macOS VM sandbox.

## Ideas backlog (2026-09-23)

Ideas discussed but not built yet. Research behind them is in `docs/research/` ([inference speed](research/inference-speed.md), [inference networks](research/inference-network.md), [knowledge systems](research/knowledge-systems.md)). In progress on 2026-09-23 and not listed: `WebFetch`/`WebSearch`/`Docs`, composer voice input, per-step timing (`scripts/time_split.py`), and the suffix-drafting replay (`scripts/draft_replay.py`).

### Speed
- **Zero-prefill turns.** Multiple KV slots in tang with a session hint (M1), bf16 KV sized on demand (M2), a disk tier with `/v1/prefill` warming on launch and focus (M3), type-ahead prefill from the composer (M4), paged content-addressed blocks (M5). Pruning moves to turn boundaries with a background re-prefill, and prompts stay byte-stable.
- **Agent-aware speculative decoding.** A per-session suffix tree (prompts, outputs, files read), JSON tokens the grammar forces for free, MTP heads when nothing matches. Expected 1.8–3x on CUDA and 1.3–2x on Mac (to be checked with `draft_replay.py`).
- **Streaming and speculative tool execution.** Start read-only tools as soon as their arguments parse, prefetch files the output mentions, encourage parallel tool calls. Expected 15–45% off task time.
- **Kernels.** CUDA graphs, then a decode megakernel on the 3090 (1.3–1.7x). One command buffer per token on Metal, and Metal 4 tensor-API prefill on M5 (3–4x time to first token).
- **tang CUDA follow-ups.** Merge `kiln-llm-cuda` into `kiln-llm`. Stop the buffer pool querying free memory on every allocation. Fuse dequantization into the prefill GEMMs. Tensor-core attention for long prompts.
- **MTP / DFlash drafting** for new text (CUDA first).
- **A faster default local model.** A hybrid-attention A3B MoE coder with int8 KV (2–3x decode ceiling; needs Gated DeltaNet and MoE kernels in tang; won't fit 16 GB Macs).
- **Width instead of length.** Batched decode in tang, so subagents, best-of-n and race attempts run in one engine at about 1x cost per stream.

### Your devices
- **Route to your devices (rung 1).** `kiln node` for Linux, Bonjour discovery, pairing codes and Keychain keys, a Devices section in Settings, "fits in your pool" in the picker. Whole models on whole machines; nothing is split.
- **Splitting a model across devices** (M0 in one process, M1 localhost, M2 Mac↔3090, M3 drafting, M4 discovery). Shelved until the latency experiment says it's worth it. LAN or Thunderbolt only.
- **Pool latency experiment.** A shim in the provider path that fakes a pool's time to first token, tokens/s cap and node failures, run over 10–20 real tasks.
- **Friend pools ("Crews").** Invite-only shared devices and credits.
- **mew.** Use its Tailscale name instead of the LAN IP. Put TLS in front if it's ever reachable beyond the LAN or tailnet.
- **Decided against:** a public "contribute a GPU, get big models free" network. Datacenter prices, the speed of links over home internet, and privacy (nodes can recover prompts) all lose. See [inference networks](research/inference-network.md).

### Business (solo devs, no enterprise)
- **kiln Pro.** Credits for escalating to frontier models (never "unlimited"), reaching your GPU from anywhere through a relay, session sync, approving from your phone, background agents. Local stays free.
- **A gateway with tang behind it.** Sessions pinned to one server with their KV kept hot (logs show about 79% of input is cacheable, about 4.8x less prefill), prompt-lookup drafting (about 1.6x), handing a hot session from local to cloud without re-sending it, a model tuned on kiln traces, privacy you can prove. Pitch cost per finished task, not price per token.
- **Measure the escalation rate** (what fraction of steps needs a frontier model) with `kiln bench`. A waitlist to test demand.

### Knowledge (phase 1 shipped: `/remember`, `/forget`, `/memory`)
- Phase 2: session summaries, a read-only `Recall` tool, path-scoped rules, a ranked repo map for small models.
- Phase 3: memories extracted after a session, going into a review inbox.
- Phase 4: consolidation into a git-tracked folder, and promoting a note into AGENTS.md.
- Phase 5: embeddings, only if the bench shows grep failing on large repos.
- Smaller items: a memory editor in the Mac app, noticing "remember that…" in messages, a `memory.cloud` setting, budgeting instruction files by tier, checking that cited anchors still exist.

### Harness quality (from the bench and the logs)
- Fix contract errors in the harness (editing before reading, `old_string` mismatches) and repeat loops. These, not malformed calls, are most tool failures.
- Count text-mode tool calls that fail to parse; they're invisible in the logs today.
- Investigate why tang had more tool errors than ollama in the bench (1.3 vs 0.4).
- Earlier follow-ups: ACP `loadSession`, a Linux bubblewrap sandbox, worktree subagents that do work, KV fork, parallel subagents, faster Gemma decode in tang (34 tok/s) and fp16 vision encode.

### Models and providers
- More presets: Groq, Cerebras, Together, Fireworks, DeepSeek, Mistral, xAI, Cloudflare. Later Bedrock, Vertex, Azure.
- Per-model overrides in Settings (context, tool mode, vision, extra params).
- Show whether local providers (LM Studio, ollama) are actually running, not just "connected".

### Niceties
- **Images.** SVG first, then Apple's Image Playground (`ImageCreator`) on device, FLUX on mew, and remote image models. One `Image` tool that shows results in the lightbox.
- **Dev-server preview pane** with console logs, which the agent can screenshot and inspect.
- **Global quick-ask hotkey**, plus capture a region and ask.
- **Menu bar extra** for running and waiting agents, with approve and deny.
- **Shortcuts, App Intents and the Services menu** ("Ask kiln about the selection").
- **Share a session** as an HTML page or a gist.
- **Small polish.** The lightbox zooms in from the thumbnail, focus returns to the composer after the lightbox closes, and the title lines up with the sidebar.

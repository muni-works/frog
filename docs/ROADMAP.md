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
| ACP adapter (`kiln-acp`) for Zed, JetBrains, and Neovim | must |
| Agent Skills (`SKILL.md`), loaded progressively | must |
| AGENTS.md | done |
| OpenTelemetry GenAI spans (behind a feature flag) | nice |
| A2A, AG-UI | skip |

The MCP-vs-CLI study found that harnesses using only bash were 5–28x cheaper ([2608.08654](https://arxiv.org/abs/2608.08654)), so MCP should stay opt-in and never be required.

## 6. Security

- **Enforce at dispatch, in deterministic code, not in the prompt.** Track where each value came from, and only let values from trusted sources flow into tools with side effects ([2503.18813](https://arxiv.org/abs/2503.18813), [2608.27496](https://arxiv.org/abs/2608.27496), [2607.24625](https://arxiv.org/abs/2607.24625)).
- **Add an OS sandbox,** using seatbelt on macOS and bubblewrap on Linux (the codex-rs approach). Matching command strings is not a security boundary ([opencode#49948](https://github.com/anomalyco/opencode/issues/49948)).
- **Quarantine suspicious MCP tool descriptions** ([2606.20922](https://arxiv.org/abs/2606.20922)). Done: descriptions that look like injection, or that hide Unicode, are withheld unless the server has `trust = true`.

## 7. Sub-agents for context folding, not role-play

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

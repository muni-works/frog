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

## 3. Context as a budget (next)


- **Staged compaction.** First drop stale tool outputs by rule. Call an LLM summarizer only as a last resort. Allow at most one compaction per run, and reject empty summaries ([2609.20804](https://arxiv.org/abs/2609.20804), [2606.11213](https://arxiv.org/abs/2606.11213), [opencode#27924](https://github.com/anomalyco/opencode/issues/27924)).
- **Pin rules.** Keep the system prompt, AGENTS.md, and permissions outside anything compaction can touch. After a naive compaction, rule-violating tool calls rose from 0% to 30–59%, and pinning brought them back to 0% ([2606.22528](https://arxiv.org/abs/2606.22528), [2608.22752](https://arxiv.org/abs/2608.22752)).
- **No synthetic "continue" user turns.** They make small models stop ([opencode#49965](https://github.com/anomalyco/opencode/issues/49965)).
- **Treat missing usage data as unknown, not zero.** Probe the context window from the server instead of relying on config ([opencode#40908](https://github.com/anomalyco/opencode/issues/40908)).

## 4. Adapt the harness to the model

The same model's results vary 40–139x in tokens and up to 30 points in score depending on the harness ([2607.22585](https://arxiv.org/abs/2607.22585), [2608.08654](https://arxiv.org/abs/2608.08654), [2609.17394](https://arxiv.org/abs/2609.17394)).

- **Profile each model** on first use: whether native tool calls work, whether text-format calls work, and whether constrained output is available.
- **For small models, use grammar-constrained tool calls** (llama.cpp GBNF / ollama `format`), and always include an "answer in text" branch ([2609.23742](https://arxiv.org/abs/2609.23742), [2608.13959](https://arxiv.org/abs/2608.13959)).
- **Match the toolset to the model.** Weak models get structured tools and planning. Strong models do as well or better with bash only, at lower cost ([2609.20804](https://arxiv.org/abs/2609.20804)).
- **Stay on JSON for tool-call arguments.** Compact formats save 18–27% of tokens but cost 9–14 points of accuracy ([2605.29676](https://arxiv.org/abs/2605.29676)).

## 5. Standards

| | verdict |
|---|---|
| MCP client (2026-07-28 spec, rmcp 3.x; also accept 2025-11-25 servers) | must |
| ACP adapter (`kiln-acp`) for Zed, JetBrains, and Neovim | must |
| Agent Skills (`SKILL.md`), loaded progressively | must |
| AGENTS.md | done |
| OpenTelemetry GenAI spans (behind a feature flag) | nice |
| A2A, AG-UI | skip |

The MCP-vs-CLI study found that harnesses using only bash were 5–28x cheaper ([2608.08654](https://arxiv.org/abs/2608.08654)), so MCP should stay opt-in and never be required.

## 6. Security

- **Enforce at dispatch, in deterministic code, not in the prompt.** Track where each value came from, and only let values from trusted sources flow into tools with side effects ([2503.18813](https://arxiv.org/abs/2503.18813), [2608.27496](https://arxiv.org/abs/2608.27496), [2607.24625](https://arxiv.org/abs/2607.24625)).
- **Add an OS sandbox,** using seatbelt on macOS and bubblewrap on Linux (the codex-rs approach). Matching command strings is not a security boundary ([opencode#49948](https://github.com/anomalyco/opencode/issues/49948)).
- **Quarantine suspicious MCP tool descriptions** ([2606.20922](https://arxiv.org/abs/2606.20922)).

## 7. Sub-agents for context folding, not role-play

A sub-agent works in its own branch and returns only a summary to the parent. Context-Folding got a 10x smaller context with equal or better results ([2510.11967](https://arxiv.org/abs/2510.11967)). Sub-agents need an `Op::Cancel{id}`, step and token budgets, and detection of repeated calls. opencode had a sub-agent make 364 identical grep calls ([opencode#45442](https://github.com/anomalyco/opencode/issues/45442)). Multi-agent teams by default are not supported by the evidence ([2503.13657](https://arxiv.org/abs/2503.13657), [2609.13890](https://arxiv.org/abs/2609.13890)).

## 8. `kiln bench` and test-time scaling

Build a fixed task set, run it against any model and harness configuration, and report pass rate, tokens per solved task, and idle turns. Later, add best-of-N selection using structured trajectory summaries ([2604.16529](https://arxiv.org/abs/2604.16529), [2601.22129](https://arxiv.org/abs/2601.22129)).

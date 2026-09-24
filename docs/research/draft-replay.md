# Draft replay: agent-aware speculative decoding on real kiln logs

Written 2026-09-23. Script: `scripts/draft_replay.py` (stdlib only; it reuses gateway_stats.py's parsing helpers). Raw output: `dr_default.txt` and `dr_thinking.txt` in this scratchpad.

```
scripts/draft_replay.py bench=/private/tmp/claude-501/bench-tang-vs-ollama/sessions \
                        interactive=~/.local/share/kiln/sessions [--thinking]
```

**Data.** 96 sessions and about 380 model calls:
- **bench:** 24 sessions. Six coding tasks, each run twice on ollama qwen3:4b and twice on tang Qwen3-4B-4bit.
- **interactive:** 72 sessions, mostly Qwen3-4B / 0.6B / 8B, qwen2.5:3b and Apple on-device.

**Tokens.** A real Qwen3 BPE: a pure-Python port of the tokenizer.json in the HF cache. It matched HF `tokenizers` exactly on 81 real log texts (45,054 tokens).

## Headline

"tok/step" is output tokens per verify pass. Speedup is tokens divided by the summed verify cost under each curve:
- **3090-like:** `1:1,4:1.05,8:1.15,16:1.4,32:2.0`. This is a guess; the research note only says a k-token verify costs "close to one token".
- **Mac-like:** `cost(k) = 1 + 0.085(k-1)`. Derived from the MLX EAGLE-3 prototype: 0.5–1 ms per extra verified token at 8.8 ms per token.

**Answer text + tool calls only (21.4K tokens, no thinking):**

| strategy | tok/step | accept | 3090-like | Mac-like |
|---|---|---|---|---|
| prompt lookup (baseline, 3-gram, 10) | 1.58 | 41% | 1.52x | 1.40x |
| suffix, prompt only | 1.78 | 50% | 1.72x | 1.57x |
| suffix, + session outputs | 1.78 | 49% | 1.72x | 1.57x |
| suffix, + earlier sessions (global) | 2.23 | 44% | 2.09x | 1.79x |
| suffix tree drafts, global | 2.24 | 44% | 2.10x | 1.80x |
| grammar-forced only | 1.25 | 100% | 1.24x | 1.22x |
| **suffix global + grammar** | **2.33** | 51% | **2.20x** | **1.90x** |
| bound: copyable (≥4 tokens) from context | 2.06 | – | 2.00x | 1.89x |
| bound: copyable from any source | 3.11 | – | 2.92x | 2.63x |
| bound: copyable any source + grammar | 3.15 | – | 2.95x | 2.65x |

**Including thinking (290.5K tokens, which is what the GPU actually decodes):**

| strategy | tok/step | accept | 3090-like | Mac-like |
|---|---|---|---|---|
| prompt lookup | 1.41 | 20% | 1.34x | 1.20x |
| suffix, prompt only | 1.59 | 34% | 1.54x | 1.39x |
| suffix, + session outputs | 1.74 | 33% | 1.67x | 1.46x |
| suffix, + global | 1.99 | 29% | 1.86x | 1.54x |
| suffix tree drafts, global | 2.02 | 30% | 1.89x | 1.57x |
| grammar-forced only | 1.02 | 100% | 1.02x | 1.02x |
| suffix global + grammar | 1.99 | 29% | 1.86x | 1.55x |
| bound: copyable from context | 2.00 | – | 1.94x | 1.84x |
| bound: copyable from any source | 5.21 | – | 4.61x | 3.84x |

**Accepted draft tokens per step** (suffix global + grammar, no thinking): 0 → 65%, 1 → 16%, 2 → 5%, 3 → 3%, 4–7 → 6%, 8–15 → 3%, 16–31 → 1.2%, 32+ → 0.4%. Prompt lookup: 88% of steps accept nothing and 4% accept 8–15.

## What it says

1. **Suffix decoding beats naive prompt lookup by about 1.4x.** Without thinking it reaches about 2.2x on a 3090 and about 1.9x on a Mac, against 1.5x / 1.4x for lookup. Most of the gain comes from the global tree (earlier sessions' outputs), not the per-request tree.
   - A suffix tree over the prompt alone adds about 13%.
   - Adding earlier outputs from the same session adds nothing when thinking is excluded, because they are already in the prompt. It adds about 9% with thinking, since earlier thinking is dropped from later prompts but kept in the tree.
2. **Thinking is 93% of decoded tokens,** so it sets the real speedup. On thinking-heavy output, suffix/global gives about 1.9x on a 3090 and about 1.55x on a Mac. That is inside the research note's bet #1 range (1.8–3x on a 3090, 1.3–2x on a Mac), at the low end.
   - Shortening or disabling thinking would likely matter more than drafting: 14x fewer tokens.
3. **Grammar-forced tokens are 21% of answer/tool-call tokens.** Alone they give 1.24x, and on top of suffix drafting about +5%. They are 1.7% of tokens once thinking is counted, so they are nearly irrelevant there. They are cheap to add because every forced draft token is accepted, which also makes them safe on a Mac.
4. **Tree drafts barely help (+0.5–1.5%)** at these settings. Tree attention in tang isn't worth building for this alone.
5. **The Mac discount is real but not fatal.** Acceptance is 30–50%, so drafts cost verify width on a steep curve. Longer drafts hurt: `--alpha 2` drops the Mac speedup from 1.54x to 1.40x. The defaults (α=1, min-prob 0.1, cap 32) sit near the best of a small sweep. Mac speedup mostly follows high-confidence copies.
6. **Headroom.** An oracle copying every ≥4-token match from any source gets 3.1 tok/step without thinking and 5.2 with it, against 2.0–2.3 achieved.
   - The gap is candidate choice: the right continuation exists but isn't the most frequent one.
   - Bench tasks repeat, which inflates this bound.
   - A better scorer (recency, or preferring the prompt over global) is the next thing to try offline.
7. **Per model** (no thinking, suffix global + grammar, 3090-like / Mac-like):
   - tang Qwen3-4B-4bit bench: 2.41x / 2.02x
   - ollama qwen3:4b bench: 2.79x / 2.28x
   - interactive qwen3:4b: about 2.2x / 1.8x
   - tang Qwen3-4B interactive: 1.36x / 1.25x
   - qwen2.5:3b: 3.8x / 3.1x
   - apple/on-device: 5.0x / 3.7x (short, repetitive outputs)

## Caveats

- **Small sample.** 21K answer tokens, and 290K with thinking, most of which are 4B models on a handful of tasks. Per-model rows with fewer than about 1K tokens are noise.
- **The global tree is flattered by repetition.** Bench runs each task 4 times: bench suffix/global is 2.43 tok/step against 2.10 for interactive alone. A real user's history repeats less than a benchmark, though more than zero. Cross-model sharing is also optimistic.
- **Small models.** Qwen3-4B-class outputs are short and template-like. Larger models write more novel text, so acceptance likely drops.
- **Verify-cost curves are assumed, not measured.** The 3090 curve is a placeholder, and the Mac curve extrapolates one MLX prototype (8B, M3 Ultra) linearly. Bet #1's step 2 (time a forward pass at k=1..32 at 2K and 20K context on both backends) is still needed. Drafting CPU time is assumed free.
- **Tokenization.** The Qwen3 BPE is exact on real text, though the pre-tokenizer uses Python `re` approximations of \p{L} and \p{N}. Non-Qwen models (Gemma, Apple, qwen2.5) are scored with Qwen3 tokens and Qwen3's tool-call format. The approximate word split gives higher numbers across the board: lookup 1.77, suffix/G+gram 3.10 tok/step.
- **Rendering.** Tool calls are serialized as Qwen3 generates them (`<tool_call>\n{"name": "X", "arguments": {...}}\n</tool_call>`, json.dumps spacing). Kiln's text-mode history uses compact JSON, and native mode goes through the server's template.
- **Context is incomplete.** The system prompt and tool schemas aren't logged, so they're missing from the context. That understates matches on tool names and keys.
- **Grammar forcing is deliberately conservative.**
  - Never forced: the first token of names and keys, values, `,` vs `}`, nested JSON, and tools without a known schema.
  - A token counts as forced only if every character in it is forced.
  - Key order is assumed free.
- **Interactive logs are live.** The interactive folder changes as kiln runs, so call counts drift slightly between runs.

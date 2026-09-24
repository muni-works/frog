# Knowledge systems for coding agents, and what kiln should build

Research date: 2026-09-23. The sources are primary where I could get them: vendor docs, engineering blogs, source code and arXiv. Anything that comes only from a vendor's own claim, or only from third-party write-ups, is marked **[vendor claim]** or **[unverified]**.

---

## TL;DR

- The field has converged on **markdown files plus progressive disclosure plus agentic grep**. It has moved away from vector-RAG memory and knowledge graphs for coding.
  - Claude Code dropped its local vector DB.
  - Sourcegraph, Continue and Cursor retired embeddings-only context or memories.
  - Codex, Letta and Claude Code all store memory as plain markdown, with a small index that is always loaded and details that are loaded on demand.
- What helps measurably:
  - short, human-written, non-obvious instructions
  - **compressed, verified experience** (fix statements of about 200 tokens, not transcripts)
  - memory facts with **code citations checked just in time**
  - for large repos, semantic search used *alongside* grep
- What hurts measurably:
  - LLM-generated context files
  - raw transcript memory
  - retrieved memory that is irrelevant or only loosely related
  - anything that grows the always-loaded prefix
- Small models are hit twice. They have less effective context and weaker agentic search. So kiln should do more of the knowledge work **in deterministic harness code** (budgets, ranking, verification, redaction) and **offline with the strongest available model** (extraction, consolidation), and less in the 4B model's turn loop.
- Recommendation for kiln, in short:
  - **Instructions**: exists today; add a tier budget.
  - **Memory notes**: markdown with frontmatter, a budgeted index, provenance and citations, stored locally outside the repo.
  - **Episodic recall**: session summaries plus a keyword/file recall tool.
  - **Code knowledge**: CodeMap, plus a ranked symbol map for the weak tier; embeddings only if `kiln bench` shows a gain.
  - **Procedures**: skills, with consolidation *proposing* new ones.
  - Automatic learning goes through a **review inbox**, not straight into the prompt.

---

## 1. How current harnesses do it

### 1.1 Comparison table

Legend for **Retrieval**:
- **A**: always in the prompt
- **P**: progressive (catalog or index in the prompt, body loaded on demand)
- **T**: on-demand tool
- **S**: similarity search
- **G**: agentic grep/read

Legend for **Writer**: U = user, Ag = agent during the session, Bg = background or offline process.

| System | What's stored | Representation | Scope | Writer | Retrieval | Verification / decay | Known failure modes |
|---|---|---|---|---|---|---|---|
| **Claude Code**: CLAUDE.md, rules, auto memory, skills, compaction | Instructions. Four memory types: `user`, `feedback`, `project`, `reference`. Skills. | Markdown. `MEMORY.md` index plus topic files. Rule files have a `paths:` glob. | Managed/org, user, project, local, subdirectory. Memory is per repo, shared across worktrees, machine-local. | U (CLAUDE.md, rules); Ag (auto memory); Bg ("Auto Dream", **[unverified]**) | A: CLAUDE.md files and the first **200 lines / 25KB** of MEMORY.md. P: topic files, path-scoped rules on matching file reads, skills. G: code. | Told to skip anything derivable from code/git. Consolidation reportedly prunes contradictions. No citation check. | Rules can contradict each other ("Claude may pick one arbitrarily"). Adherence drops above about 200 lines. Memory is not enforcement: use hooks for that. |
| **OpenAI Codex**: AGENTS.md plus Memories | AGENTS.md. Generated `memory_summary.md`, `MEMORY.md` handbook, `rollout_summaries/`, `skills/` | Markdown in `~/.codex/memories`, git-baselined | User-global (memories), project (AGENTS.md) | U (AGENTS.md; explicit "remember" goes to `ad_hoc/notes`). Bg: Phase 1 extraction per rollout, Phase 2 consolidation sub-agent. | A: `memory_summary.md`, truncated to **2,500 tokens**. G: the agent greps `MEMORY.md` and reads rollout summaries when needed. No vectors. | Secret redaction at extraction. Usage-ranked selection. Unused memories age out (`max_unused_days`, reportedly 30 days). Citations of memory use. Read prompt: "Memory is not proof of current behavior." | Token cost (a maintainer warned early that it "would consume all your tokens"). Runs only on idle sessions, so learning lags. |
| **Cursor**: rules, memories (removed), index | `.cursor/rules/*.mdc`, AGENTS.md. Memories (June 2025 to 2.1). Codebase index. | Markdown rules. Custom embedding model plus a server-side vector index (Merkle-tree sync). | Project, user | U (rules); Ag (memories, removed in 2.1, **[unverified: forum reports]**) | A/P: rules (always, glob, agent-requested). S+G: semantic search *plus* grep. | Index resync. Memories were never verified. | Memories removed or migrated to rules. The index needs a cloud upload (paths obfuscated). |
| **Windsurf / Devin Cascade**: memories, rules | Auto-memories. Rules in `.windsurf/rules` or `.devin/rules`, AGENTS.md. | Local files in `~/.codeium/windsurf/memories/` | Workspace | Ag (`create_memory` is invoked automatically); U (rules) | A (retrieved when relevant; the mechanism is opaque) | None documented | **SpAIware**: an indirect prompt injection persisted through `create_memory` and exfiltrated data in later sessions (Rehberger, 2025). |
| **GitHub Copilot**: agentic memory | Facts: `{subject, fact, citations, reason}` | Server-side store | Repository, shared across coding agent, CLI and review | Ag (a `store_memory` tool) | A: recent memories injected at start, then **verified against cited code** before use | Just-in-time citation check. Contradictions get rewritten. **28-day expiry.** | Needs cloud storage. Poisoning is mitigated by the citation check, not eliminated. |
| **Cline / Roo**: memory bank, index | 6 markdown files: `projectbrief`, `productContext`, `systemPatterns`, `techContext`, `activeContext`, `progress` | Markdown in the repo | Project | Ag, driven by a custom-instructions prompt; U triggers "update memory bank" | A: "must read ALL memory bank files at the start of every task". Roo adds S: tree-sitter chunks, embeddings, Qdrant `codebase_search`. | Manual | Token-heavy and grows without bound. It is a convention, not an engine feature. Needs a strong model to maintain. |
| **Aider**: repo map | Nothing persistent beyond conventions files. A computed map. | Tree-sitter tags, file graph ranked with PageRank | Repo | Computed | A: map in the prompt, `--map-tokens` default **1k**, grows when no files are in the chat | Recomputed every turn | Can crowd out the window on big repos. No learning across sessions. |
| **OpenCode** | AGENTS.md (falls back to CLAUDE.md), `instructions` globs | Markdown | Global, project, subtree | U; `/init` generates | A | none | Community plugins add Letta-style memory blocks. No core memory. |
| **Continue** | `.continue/rules`, MCP | Markdown | Project | U | A plus tools. `@Codebase` embeddings **deprecated** in favor of agent tools. | n/a | n/a |
| **Sourcegraph Cody / Amp** | Cody: code-search context. Amp: AGENTS.md plus server-side threads. | Search index (Cody dropped embeddings in Feb 2024). Threads. | Org/repo; threads per user or team | U; threads are automatic | G/T: Amp `find_thread` searches past threads by keyword *or by file touched* | n/a | Threads live on the server. |
| **Devin**: knowledge | Knowledge items: tip plus **trigger description**. Auto-generated "Repo Knowledge". | Server-side notes | Org / repo | U, and Ag *suggests* items that the user edits or approves | S: pulled when the current work matches the trigger semantically | Manual review | Opaque retrieval. Knowledge goes stale. |
| **Letta / MemGPT**: Letta Code, MemFS | Core memory blocks, archival memory. Now "context repositories". | Git-backed markdown ("MemFS") edited with bash and file tools | Agent-scoped, portable | Ag, plus Bg "dreaming" (sleep-time subagents) | A: blocks pinned in the prompt. G/T: files. | Git history. Concurrent writers in worktrees merge through git. | Designed for a strong model that curates its own memory. |
| **Zep / Graphiti** | Temporal knowledge graph: entities, edges with validity intervals | Graph DB (Neo4j), plus embeddings and BM25 | User/session | Bg: LLM extraction on ingest | S plus graph traversal | Bi-temporal edges invalidate superseded facts | Heavy infrastructure. Many LLM calls on ingest. Built for chat and business data, not code. |
| **mem0** | Extracted atomic facts (optionally a graph) | Vector DB (plus graph) | User/agent/session | Bg: extract, then ADD/UPDATE/DELETE/NOOP | S | LLM-decided updates | Its LoCoMo results are disputed (see §3). One-shot similarity retrieval. |
| **Anthropic memory tool** (API) | Whatever Claude writes under `/memories` | Client-side files | App-defined | Ag | T | App-defined | Path traversal is on the implementer. Otherwise it is a raw primitive. |

Sources:
- Claude Code: [memory docs](https://code.claude.com/docs/en/memory) (current, Sept 2026). The "Auto Dream" trigger of 24 hours and 5 or more sessions is reported only by third parties, e.g. [claudefa.st](https://claudefa.st/blog/guide/mechanics/auto-dream), [antoniocortes.com, 2026-03-30](https://antoniocortes.com/en/2026/03/30/auto-memory-and-auto-dream-how-claude-code-learns-and-consolidates-its-memory/), and is **not in the official memory docs**.
- Agentic search: [Boris Cherny on X, 2026](https://x.com/bcherny/status/2017824286489383315): "Early versions of Claude Code used RAG + a local vector db, but … agentic search generally works better."
- Codex: source, [codex-rs/memories/README.md](https://github.com/openai/codex/blob/main/codex-rs/memories/README.md). The read-path prompt is `ext/memories/templates/memories/read_path_v2.md`. The consolidation prompt is `memories/write/templates/memories/consolidation.md`. `MEMORY_TOOL_DEVELOPER_INSTRUCTIONS_SUMMARY_TOKEN_LIMIT = 2_500` is in `ext/memories/src/lib.rs`. Also [Discussion #12567](https://github.com/openai/codex/discussions/12567) and [mem0's write-up](https://mem0.ai/blog/how-memory-works-in-codex-cli), where the 30-day figure is **[secondary]**.
- Cursor: [semsearch blog, 2025-11-06](https://cursor.com/blog/semsearch), [secure indexing](https://cursor.com/blog/secure-codebase-indexing), [forum: memories gone in 2.1](https://forum.cursor.com/t/custom-modes-and-memories-gone-in-2-1/143744).
- Windsurf: [Cascade memories docs](https://docs.windsurf.com/windsurf/cascade/memories), [Embrace The Red: Windsurf SpAIware, 2025](https://embracethered.com/blog/posts/2025/windsurf-spaiware-exploit-persistent-prompt-injection/).
- Copilot: [GitHub blog, 2026-01-15](https://github.blog/ai-and-ml/github-copilot/building-an-agentic-memory-system-for-github-copilot/), [docs](https://docs.github.com/en/copilot/concepts/agents/copilot-memory).
- Cline: [Memory Bank docs](https://docs.cline.bot/best-practices/memory-bank). Roo: [codebase indexing](https://docs.roocode.com/features/codebase-indexing).
- Aider: [repo map docs](https://aider.chat/docs/repomap.html) (design post from Oct 2023).
- OpenCode: [rules docs](https://opencode.ai/docs/rules/). Continue: [@Codebase deprecated](https://docs.continue.dev/reference/deprecated-codebase).
- Cody: [How Cody understands your codebase, 2024-02-15](https://sourcegraph.com/blog/how-cody-understands-your-codebase). Amp: [find threads](https://ampcode.com/news/find-threads).
- Devin: [Knowledge docs](https://docs.devin.ai/product-guides/knowledge).
- Letta: [Context Repositories](https://www.letta.com/blog/context-repositories/), [MemFS docs](https://docs.letta.com/concepts/memfs).
- Zep: [arXiv 2501.13956, Jan 2025](https://arxiv.org/abs/2501.13956). mem0: [arXiv 2504.19413, Apr 2025](https://arxiv.org/abs/2504.19413).
- Anthropic memory tool: [docs](https://platform.claude.com/docs/en/agents-and-tools/tool-use/memory-tool) (released 2025-09-29).

### 1.2 Notable details worth copying

- **Codex writes in two phases.**
  - Phase 1 runs a per-session extraction with a strict schema (`raw_memory`, `rollout_summary`, `slug`) on *idle* sessions only, with **secret redaction before disk**.
  - Phase 2 is one global-lock consolidation sub-agent. It runs with no approvals, no network and local writes only, and works on a **git-diffed workspace**, so every change to memory is a reviewable diff.
  - Explicit "remember" or "forget" requests are appended as small notes that consolidation applies later. The live agent is told *not* to edit generated memory directly.
  - Recall is a 2.5k-token summary plus grep. No vectors.
- **Claude Code's auto-memory taxonomy** (`user`, `feedback`, `project`, `reference`) comes with an explicit rule: "Claude skips anything it can derive from the codebase, such as architecture, file paths, or debugging fixes." This is the most important content rule in the whole space, and the AGENTS.md study below backs it up.
- **Copilot's citations plus just-in-time verification** is the only production answer to staleness that has published A/B numbers.
- **Amp's search by "file touched"** is a cheap, high-precision way to recall past sessions for code. It works like `git blame` for conversations.
- **Devin's trigger descriptions**: each knowledge item carries *when* it applies, not just *what* it says. This matches SKILL.md `description` semantics.

---

## 2. The design space

### 2.1 Axes

| Axis | Options | Notes |
|---|---|---|
| **Origin** | explicit (user-authored) · proposed (agent suggests, user approves) · implicit (agent writes) | Implicit writes are where both poisoning and "form degradation" come from (§3, §4). |
| **Scope** | org/managed · user-global · project/repo · directory/path glob · session · subagent | Directory and path scoping is the cheapest way to cut always-loaded tokens. |
| **Content type** | instructions/rules · preferences (user) · corrections (feedback) · project facts/decisions · references (external) · procedures (skills) · episodes (session logs) · code structure | Mixing these in one file is the main source of bloat. |
| **Representation** | markdown files · structured facts (JSON/YAML frontmatter) · knowledge graph · embeddings/vector store · code graph/index (tree-sitter, LSP, SCIP) · episodic logs | Markdown wins on inspectability, diffing, portability and on models already being trained to use files. |
| **Retrieval** | always loaded · progressive disclosure (catalog/index, then load) · path-triggered · semantic similarity · graph traversal · agentic grep/read · harness-pushed ranked map | Push (harness selects) vs pull (model searches) is the key choice for weak models. |
| **Write path** | explicit `/remember` · in-loop tool (`store_memory`) · post-session extraction · periodic consolidation/reflection ("dreaming") · promotion to a durable tier | Offline extraction decouples memory quality from the model that is running now. |
| **Maintenance** | none · usage-ranked selection · TTL/decay · contradiction resolution · bi-temporal invalidation · git history | Codex uses usage plus decay, Copilot a 28-day expiry plus verification, Zep temporal edges. |
| **Verification** | none · provenance (session/turn/source) · code citations checked just in time · human review | Citations turn "memory" into "hypothesis plus a pointer to evidence". |
| **Trust** | memory treated as instructions · memory treated as data · provenance-gated | Every harness that treats agent-written memory as instructions has had a persistence exploit. |
| **Portability** | AGENTS.md (AAIF/Linux Foundation, Dec 2025) · SKILL.md (agentskills.io) · CLAUDE.md · vendor-private stores | Instructions and procedures are standardized. *Learned memory has no standard*: every vendor's store is private. |

### 2.2 Taxonomy of architectures

**A. Static instruction files** (AGENTS.md, CLAUDE.md, KILN.md, rules; always loaded; human-written)
- Pros:
  - zero infrastructure
  - portable and reviewable in PRs
  - deterministic
  - cache-friendly, because the prefix is stable
- Cons:
  - every token is paid on every turn
  - they go stale
  - contradictions are silent
  - LLM-generated versions *hurt*
- Where it breaks: large files; small context windows; monorepos with many nested files; weak models that follow the last instruction they read.

**B. Scoped and progressive instructions** (path-glob rules, skills catalogs, nested AGENTS.md)
- Pros:
  - pays for context only when it is relevant
  - works on 8k windows if the catalog is budgeted
- Cons:
  - relies on the model choosing to load a skill, which is weak for 4B models
  - path triggers only fire on file reads
- Where it breaks: skill *selection* by small models; too many similar descriptions.

**C. Self-curated memory files** (Claude Code auto memory, Letta blocks/MemFS, Cline memory bank)
- Pros:
  - learns preferences and corrections without user effort
  - inspectable and editable
- Cons:
  - quality depends on the model *writing* the memory
  - bloat
  - duplicates and contradictions
  - persistent injection
- Where it breaks: weak models write noise or transcript fragments (VibeMemBench's "form degradation"); a memory bank that must be read in full every task blows small windows.

**D. Background extraction plus consolidation** (Codex Phases 1 and 2, Claude "dream", Letta sleep-time, mem0 ADD/UPDATE/DELETE)
- Pros:
  - memory quality is decoupled from the model in the current turn
  - batched and cheap when idle
  - diffable when git-backed
- Cons:
  - lag of hours or sessions
  - costs tokens
  - opaque unless the diffs are surfaced
  - still exposed to poisoning, because extraction reads tool output
- Where it breaks: only a local 4B model is available to extract; no idle time; the user never reviews.

**E. Structured fact stores with similarity retrieval** (mem0, Cursor memories, Devin knowledge)
- Pros:
  - small atomic facts
  - top-k keeps the prompt bounded
- Cons:
  - one-shot similarity misses multi-hop queries
  - retrieving irrelevant facts actively hurts (SWE-ContextBench)
  - needs an embedding model and a store
  - facts lose their evidence
- Where it breaks: code, where exact identifiers matter and paraphrase-level similarity is the wrong signal. Cursor removed its memories.

**F. Temporal knowledge graphs** (Zep/Graphiti)
- Pros:
  - handles changing facts over time
  - multi-hop over entities
- Cons:
  - heavy (graph DB, many LLM calls on ingest)
  - opaque
  - the ingest LLM must be strong
  - no coding-specific evidence
- Where it breaks: local-first and solo developers; small models as the extractor.

**G. Code indexes** (Aider PageRank repo map, kiln CodeMap, Cursor/Roo embeddings, Sourcegraph/SCIP/LSP)
- Pros:
  - derived from code, so never stale if recomputed
  - no trust issue
  - a repo map pushes structure to weak models cheaply
- Cons:
  - embeddings need index builds; Cursor reports hours for huge repos before its reuse trick
  - privacy if the index is cloud-hosted
  - one-shot retrieval has low precision
- Where it breaks: a map that is too big for an 8k window; embeddings over rapidly changing code.

**H. Agentic search over raw artifacts** (grep/glob/read over code, memory files and session logs; Codex "grep MEMORY.md"; Amp `find_thread`)
- Pros:
  - no index, no staleness
  - strongest evidence for capable models
  - simple
- Cons:
  - costs tokens and turns ("trades time for intelligence")
  - needs a model that can plan searches
- Where it breaks: 4B models that loop or pick the wrong tools. kiln's own bench saw `qwen2.5:3b` 0/18, and the ROADMAP notes it "picks the wrong tools".

**I. Episodic memory** (session logs, summaries, experience replay)
- Pros:
  - it is the ground truth
  - 200-token fix summaries measurably help (SWE-ContextBench)
- Cons:
  - raw transcripts measurably hurt
  - retrieval must be precise
- Where it breaks: being auto-injected rather than pulled on demand.

The architectures are **layers, not alternatives**. Every serious harness combines A+B with at least one of C/D and one of G/H.

---

## 3. What the evidence says

### 3.1 Instruction files

**[Gloaguen et al., "Evaluating AGENTS.md", arXiv 2602.11988, Feb 2026](https://arxiv.org/abs/2602.11988)** (ETH SRI Lab):
- LLM-generated context files **cut task success by about 3%** and **raised inference cost by more than 20%**.
- Developer-written files gave **about +4%** success but still up to **+19% cost**.
- Agents given context files explore more and run more tests and repo-specific tooling. For example, repo-specific tool calls went from 0.05 to 2.5 per instance.
- The paper concludes that context files should contain only what *isn't already discoverable from the code*.
- The Claude Code docs agree independently: aim for under 200 lines, contradictions get resolved arbitrarily, and adherence falls with length.

**Implication for kiln:**
- Never auto-generate AGENTS.md content into the always-loaded prefix.
- Budget the instruction block per model tier. The ROADMAP already notes that global CLAUDE.md files "add a lot of tokens" for the weak tier.

### 3.2 Learned memory for coding agents

**[VibeMemBench, arXiv 2609.23570, Sept 2026](https://arxiv.org/html/2609.23570)**
- Setup: 111 targets, 90 SWE-rebench V2 repos, and four memory systems (Mem0, SimpleMem, MemoryOS, A-MEM).
- **11 of 12 solver–system pairings failed to beat the memory-off baseline.**
- Frozen *verified* experience helped 4 of 5 solvers by **+1.1 to +4.5 points**, but the confidence intervals crossed zero.
- **69.3% of failures were "form degradation"**: instruction pollution (40%) and overgeneralized fix patterns (18.1%). The harm tracked *transcript volume*.
- A record that helped weaker solvers *hurt* stronger ones that were near ceiling.
- The authors' recommendations:
  - gate injection on the solver's headroom
  - compress to fix statements
  - keep the constraints that anchor each fix to its target

**[SWE-ContextBench, arXiv 2602.08316, Feb 2026](https://arxiv.org/html/2602.08316v3)** (1,476 tasks):
- Oracle-selected **summaries (about 217 tokens) raised resolve rate from 26.3% to 34.3%**.
- Oracle *full trajectories* (about 25.6k tokens) reached only **27.3%**.
- When the agent chose its own summaries, it scored **12 points below** the oracle selection.
- "Free" context learning was the most expensive condition, at $0.98 per task.
- Conclusion: **compression and selection matter more than having memory at all.** Bad retrieval is worse than none.

**[GitHub Copilot agentic memory, 2026-01-15](https://github.blog/ai-and-ml/github-copilot/building-an-agentic-memory-system-for-github-copilot/)** **[vendor claim, internal A/B]**:
- PR merge rate rose from **83% to 90%** for the coding agent.
- Code-review positive feedback rose from **75% to 77%**.
- p < 0.00001.
- In adversarial tests seeded with contradictory memories, agents checked the citations and corrected the memories.
- This is the strongest production evidence *for* agent-written memory, and it hinges on **citations plus just-in-time verification**.

**Anthropic memory tool plus context editing** **[vendor claim, internal eval, Sept 2025]**: +39% on an agentic-search eval over baseline, versus +29% for context editing alone.

### 3.3 Conversational memory benchmarks (LoCoMo, LongMemEval): read with caution

- **[Letta, "Is a filesystem all you need?", 2025](https://www.letta.com/blog/benchmarking-ai-agent-memory/)**: an agent that stores history in files and searches them with file tools scores **74.0% on LoCoMo** with GPT-4o-mini. That beats Mem0's reported best of **68.5%** (graph variant) **[vendor vs vendor]**.
- **[Mem0 paper](https://arxiv.org/abs/2504.19413)**:
  - more than 90% token savings and 91% lower p95 latency against full context
  - search p95 of 0.20s; total p95 of 1.44s against 17.1s for full context
  - but its *own* full-context baseline scored about 73% against Mem0's about 68% ([Zep's critique](https://blog.getzep.com/lies-damn-lies-statistics-is-mem0-really-sota-in-agent-memory/))
- **LoCoMo quality problems**:
  - an audit found 6.4% of answer keys wrong
  - the LLM judge accepted up to 63% of deliberately wrong answers ([Penfield audit, dev.to](https://dev.to/penfieldlabs/we-audited-locomo-64-of-the-answer-key-is-wrong-and-the-judge-accepts-up-to-63-of-intentionally-33lg), **[unverified third party]**)
  - conversations are about 16–26k tokens, which fits in a modern context window
- **[Zep](https://arxiv.org/abs/2501.13956)**: DMR 94.8% against MemGPT's 93.4%. On LongMemEval (about 115k-token histories) it claims up to +18.5% accuracy and −90% latency **[vendor claim]**.
- **[Sen, "Is Grep All You Need?", arXiv 2605.15184, May 2026](https://arxiv.org/abs/2605.15184)** (LongMemEval-S, 116 questions):
  - GPT-5.4 in the Codex harness: **inline grep 93.1% against inline vector 75.9%**
  - but *file-based* delivery reversed it: 55.2% against 67.2%
  - Takeaway: **how results reach the model matters as much as grep vs vectors.**

Takeaway: chat-memory benchmarks mostly measure QA recall over one long conversation. They say little about coding knowledge. The consistent signal is that **simple files plus agentic search are competitive with specialized memory stores**, and full context wins whenever it fits.

### 3.4 Code retrieval: grep vs embeddings vs repo maps

**[Cursor, 2025-11-06](https://cursor.com/blog/semsearch)** **[vendor, but with methodology]**:
- Semantic search *in addition to grep* gave **+12.5% average QA accuracy (6.5–23.5% by model)**.
- Code retention **+0.3%**, rising to **+2.6% on repos of 1,000 files or more**.
- 2.2% more dissatisfied follow-ups without it.
- Cursor states that "the combination of these two leads to the best outcomes."

**Claude Code, Sourcegraph and Continue** all moved *away* from embeddings, citing:
- simplicity
- staleness
- security and privacy
- reliability ([Cherny](https://x.com/bcherny/status/2017824286489383315))

The Claude Code evidence is **practitioner reports, not a published ablation**.

**[Deep Agentic Search vs semantic search, arXiv 2608.01507, Aug 2026](https://arxiv.org/html/2608.01507v1)**, on read-only repo QA:
- Semantic search scored **65.2% against 46.2%** for deep agentic search, across 4 models.
- Agentic search cost **about 2.3x more per correct answer**. On Qwen3-235B it used about 761k tokens per question against 34k.
- 41.8% of agentic failures were silent orchestrator–sub-agent breakdowns.
- The gap was *smaller* for weaker models: 5.6 points on Gemini 2.5 Flash.
- Caveat: this is QA, not editing, and the "deep" agent used a multi-agent orchestrator.

**[Agent Retrieval Bench, arXiv 2607.24882, Jul 2026](https://arxiv.org/abs/2607.24882)** (427 samples, 25 repos):
- **No single method wins.**
- Qwen3-Embedding-4B/8B led recall.
- **RepoMap was best for context efficiency at an 8K-token budget**, which is exactly kiln's weak-tier regime.
- Better retrieved context meant less exploratory searching.

**[SWE-Explore, arXiv 2606.07297, 2026](https://arxiv.org/html/2606.07297v1)**: one-shot BM25 and light dense retrievers are "close to random" on exploration metrics, and agentic explorers do much better.

Net:
- For strong models on editing tasks, **grep-first agentic search is the right default**.
- **Embeddings help at scale and for concept queries, as a complement.**
- For **budgeted, weak-model contexts**, a **ranked repo map** is the most token-efficient push.

### 3.5 Small models and small windows

- **[RULER, arXiv 2404.06654, 2024](https://arxiv.org/abs/2404.06654)**: effective context is often **at most half the claimed length**. Only about half of the models that claim 32k or more pass at 32k. For Qwen3-4B or Gemma-3-4B at 8–32k, assume roughly 4–16k of *useful* context.
- **[Chroma, "Context Rot", Jul 2025](https://www.trychroma.com/research/context-rot)**: all 18 models tested degraded as input grew, even on simple tasks.
- **VibeMemBench** found memory utility depends on the solver's competence. Weak solvers gain more from *good* experience, but they are also least able to *filter* bad memory or write good memory.
- **kiln's own data** (memory file, 2026-09-22):
  - qwen3:4b native scored 5/6
  - qwen2.5:3b scored 0/18
  - the ROADMAP notes weak models "still pick the wrong tools"
  - Anything that relies on a 4B model choosing to call `Recall` or `Skill` will under-deliver.
- Cost framing for a 4B model on tang, where the prefix cache matters: a stable, always-loaded memory block is cheap *after the first turn* because it is cached. Mutating it mid-session invalidates the cache (kiln's context.rs already reasons this way about pruning).

### 3.6 What is hype

- "Knowledge graphs for coding-agent memory": no coding-specific evidence that they beat files plus grep. The benchmarks are chat QA with flawed judges.
- "Self-improving memory" with no verification or review: VibeMemBench's 11/12 null or negative result is the best current evidence.
- Vendor LoCoMo leaderboards: the benchmark fits in context and the judge is lenient.
- "Just index everything with embeddings": Cursor's own gain comes from combining it with grep, and needed a custom embedding model trained on agent traces.

---

## 4. Security and privacy

**Threats:**
1. **Persistent prompt injection ("SpAIware")**: an injected instruction in a web page, README, issue or tool output causes a memory write, which then fires in every future session.
   - Demonstrated against ChatGPT memory (2024) and Windsurf's automatically invoked `create_memory` ([Rehberger, 2025](https://embracethered.com/blog/posts/2025/windsurf-spaiware-exploit-persistent-prompt-injection/)).
   - Formalized as the "promptware kill chain" ([arXiv 2601.09625](https://arxiv.org/html/2601.09625v2)).
2. **Query-only poisoning**: **[MINJA, arXiv 2503.03704](https://arxiv.org/abs/2503.03704)** reached **98.2% injection success** and a **76.8% attack success rate** through normal queries alone.
   - [A follow-up, arXiv 2601.05504, Jan 2026](https://arxiv.org/html/2601.05504v2) found that pre-existing legitimate memories cut injection success to about 25%.
   - Its trust-scored sanitization defense worked on GPT-4o-mini but **accepted 65.9% malicious entries with Gemini-2.0-Flash**. LLM-judged defenses are model-dependent.
3. **Secrets in memory**: extraction from transcripts captures tokens, `.env` contents and keys. Codex redacts at Phase 1 and again in the consolidation prompt ("never store tokens/keys/passwords; replace with [REDACTED_SECRET]").
4. **Supply chain through committed files**: a cloned repo's AGENTS.md or CLAUDE.md, or `.claude/skills`, is attacker-controlled input. Claude Code asks for approval before loading *external* `@imports` from project files.
5. **Privacy leakage to cloud providers**: local memory still goes to OpenRouter or Anthropic when a cloud model is selected.
6. **Stale-but-trusted facts** cause wrong edits. This is an integrity problem, not a confidentiality one.

**Mitigations used in practice:**
- provenance on every entry
- memory framed as *data* ("Memory is not proof of current behavior", Codex)
- citation verification (Copilot)
- human approval (Devin suggestions)
- git history for rollback (Codex, Letta)
- redaction
- machine-local storage (Claude Code, Windsurf)
- enforcement in hooks or dispatch rather than prompts (Claude Code docs; kiln ROADMAP §6)

---

## 5. Recommendation for kiln

### 5.1 Design principles

1. **Files, not databases.** Use markdown with YAML frontmatter, which matches SKILL.md, Claude Code memory and Codex. It is inspectable, diffable, greppable and portable.
2. **Push for weak models, pull for strong ones.** The harness picks and budgets what goes into the prompt. The model gets tools to go deeper only if its tier handles tools well.
3. **The harness does the thinking that doesn't need an LLM**: budgets, ranking, dedupe, secret redaction, citation checks, decay.
4. **Extraction and consolidation run offline, on the best available model**: a cloud model if configured, otherwise the local model with a grammar-constrained schema (kiln already has JSON-grammar mode).
5. **Nothing agent-written reaches the always-loaded prefix without provenance, and nothing derived from tool output does so without user approval.**
6. **Don't store what the code can tell you.** No architecture, file lists or fixes, which CodeMap and grep already provide.
7. **Freeze the prompt prefix for the whole session** to protect tang's prefix cache. Memory writes land on disk and show up next session.

### 5.2 Architecture (five layers)

```
                         always loaded (budgeted per tier)          on demand
L0 Instructions   KILN.md / AGENTS.md / CLAUDE.md (+ path rules)   path-scoped rules on file read
L1 Memory         memory/INDEX.md  (one line per entry)              memory/*.md bodies (Read/Recall)
L2 Episodes       —                                                  sessions/*.jsonl + summaries (Recall)
L3 Code           CodeMap/ranked repo map (weak tier only, ≤~800 tok) CodeMap tool, grep, [embeddings later]
L4 Procedures     skills catalog (existing, 6k-char budget)          Skill tool / /skill-name
```

**L0: Instructions** (exists in `prompt.rs::memory_files`)
- Keep the AGENTS.md → KILN.md → CLAUDE.md walk.
- Add a **per-tier instruction budget**:
  - weak: about 1.5k tokens
  - medium: about 4k
  - strong: unlimited up to the window guard
- The rule for applying the budget:
  - Project files beat global ones.
  - Nearer files beat farther ones.
  - Truncate with a visible note: "N lines of ~/.claude/CLAUDE.md omitted for this model".
- Later: `.kiln/rules/*.md` with `paths:` frontmatter (Claude Code-compatible, and also read from `.claude/rules/`), injected as a message when a matching file is first read. That is cheap, deterministic and cache-safe.

**L1: Memory notes** (new)
- Location, local-only and outside the repo:
  - `~/.local/share/kiln/projects/<repo-id>/memory/` per project. `<repo-id>` is the git root's hashed path, shared across worktrees, like Claude Code.
  - `~/.config/kiln/memory/` for the user.
- One file per entry, `memory/<slug>.md`:
  ```markdown
  ---
  type: feedback            # user | feedback | project | reference   (Claude Code's taxonomy)
  scope: project            # user | project | path:<glob>
  summary: "Use npm, not pnpm; lockfile is package-lock.json"   # the index line
  source: user              # user | agent-proposed | imported:<claude|codex>
  session: 2026-09-23T…-abc  turn: 14
  created: 2026-09-23  last_used: 2026-09-23  uses: 3
  cites: ["package.json#packageManager", "package-lock.json"]   # optional; verified JIT
  status: active            # active | stale | archived
  ---
  Why: user corrected pnpm → npm twice (session abc t14, def t3).
  ```
- `INDEX.md` is **generated by the harness** from the frontmatter, not written by the model. That avoids Claude Code's "rewrite your index" loop.
- Index line format: `- [feedback] Use npm, not pnpm (memory/npm.md)`.
- Budget, ranked by `type` priority (feedback > user > project > reference), then `uses`, then recency:

  | tier | what's included | budget |
  |---|---|---|
  | weak (4B, 8–16k) | `user` + `feedback` only, top N | about 400 tokens |
  | medium | all types | about 1k tokens |
  | strong / cloud | all types | about 2.5k tokens (Codex's limit) |

- Framing in the prompt (a data frame, after the BASE and L0 instructions):
  `# Notes from earlier sessions (may be outdated; verify against the code before relying on them)`
- Citation check at session start. It is deterministic, costs a few milliseconds, and needs no LLM:
  - does the cited file exist?
  - does the cited anchor (symbol or string) still grep?
  - Failures render as `(unverified)` in the index. After 2 consecutive failures the entry becomes `stale`.

**L2: Episodes** (builds on `session.rs`)
- At session end, write a **summary of at most 250 tokens** (SWE-ContextBench's sweet spot) into the session header or a sidecar: goal, outcome, files touched, the fix statement, and open questions.
- Generation: use the extraction model offline. For weak-only setups, fall back to a *deterministic* summary: first user message, files edited from tool records, final assistant message truncated.
- A **`Recall` tool** (medium and strong tiers), read-only. It searches memory bodies and session summaries by keyword **and by file path touched** (Amp's `find_thread`), and returns at most 5 hits with short excerpts **inline**. The grep paper shows inline delivery matters.
- Also exposed as `/recall <query>` so the *user* can push results in for weak models.
- Never auto-inject episodes.

**L3: Code knowledge** (builds on `codemap.rs`)
- CodeMap already builds a file graph with churn heat.
- Add a **ranked text repo map**: personalized PageRank over the existing `Graph`, seeded by files mentioned in the prompt, git-dirty files and recent churn. Emit top symbols and signatures within a token budget, like Aider (default 1k).
- Weak tier: inject it once at session start, capped at about 600–800 tokens. This is the one piece of code knowledge worth pushing, because RepoMap was the most budget-efficient method at 8K in Agent Retrieval Bench.
- Strong tier: leave it as a tool.
- **Defer embeddings.** If `kiln bench` shows grep plus map failing on large repos:
  - add a local index built with tang, e.g. a small Qwen3-Embedding, using tree-sitter chunks
  - store it in a single file under the data dir, updated incrementally by mtime and hash
  - expose it as a `SemanticSearch` tool *alongside* grep, never instead of it (Cursor's result)

**L4: Procedures** (skills, which exist)
- Consolidation may **propose** a new skill when the same multi-step procedure recurs in 3 or more session summaries.
- Proposed skills are written to `memory/proposed-skills/`, not to `.kiln/skills`, until the user accepts them.

### 5.3 Write and consolidation path

1. **Explicit (phase 1)**
   - `/remember <text>`, `/forget <slug>`, `/memory` (open or list), and "remember that…" detected in user input.
   - The harness writes the file with `source: user`, applying secret redaction and no LLM.
   - For strong tiers only: a `Remember` tool that *appends a proposal* (Codex's ad-hoc-notes pattern). It never edits the index directly.
2. **Proposed (phase 3), by offline extraction** after a session goes idle, or on `/learn`:
   - Input: *user messages plus the agent's final answers plus edited file paths*. Tool outputs go in only as file-path metadata, not content. This is the main anti-injection filter.
   - Output: a strict JSON schema, grammar-constrained on local models: `[{type, summary, why, cites[]}]`, or empty (a no-op is the preferred result, as in Codex).
   - Filters:
     - drop anything derivable from code (a heuristic: does the claim mention only paths or symbols that grep finds? then skip)
     - drop anything containing URLs, shell commands or imperative "always/never run…" aimed at tools, unless `source: user`
     - drop anything matching secret patterns
     - dedupe against existing entries
   - Results land in an **inbox** (`memory/inbox/`). The TUI and the Mac app show "3 things kiln learned. Keep, edit or discard?" at the next session start. Items from `user` corrections can be set to auto-accept by config; items from agent behavior never are.
3. **Consolidation (phase 4)**:
   - runs weekly, or when the index exceeds its budget, or on `/consolidate`
   - uses the memory directory as a **git repo** (Codex and Letta pattern) and presents the diff for approval
   - merges duplicates, resolves contradictions (newest `source: user` wins), archives entries unused for 60 days (the `uses` and `last_used` counters are bumped when an entry is cited in an answer or read via Recall), and converts relative dates to absolute ones
4. **Promotion**: `/memory promote <slug>` moves an entry into the project's AGENTS.md (or a `.kiln/rules` file). That makes it a team-visible, committed instruction, and is the durable, portable tier.

### 5.4 Interop

- **Read**:
  - AGENTS.md, KILN.md, CLAUDE.md (exists)
  - `.claude/rules` and `.cursor/rules` with `paths:` (phase 2)
  - SKILL.md (exists)
- **Import, one-way and on request only** (`kiln memory import claude|codex`):
  - Claude Code: `~/.claude/projects/<proj>/memory/*.md`, whose frontmatter `type` already matches
  - Codex: `~/.codex/memories/MEMORY.md`
  - Imported entries get `source: imported:*` and go through the inbox.
- **Write**: only to kiln's own directories, plus AGENTS.md on explicit promotion. Never write CLAUDE.md or another tool's store.
- Keep the memory file format a strict superset of the Claude Code auto-memory frontmatter (`type`), so a user can symlink or share by hand.

### 5.5 Small-model specifics

| | weak (4B, 8–16k) | medium (16–32k, capable tools) | strong/cloud |
|---|---|---|---|
| L0 instructions | ≤1.5k tok, project-first truncation | ≤4k | full |
| L1 memory index | ≤400 tok, `user` + `feedback` only | ≤1k, all types | ≤2.5k |
| L3 repo map pushed | yes, ≤800 tok | tool only | tool only |
| Recall tool | no (user `/recall` only) | yes | yes |
| Remember tool | no | no | proposal-only |
| Extraction model | best configured provider; else local with JSON grammar and deterministic filters | same | self |

- Total always-loaded knowledge for the weak tier is about 2.7k tokens, and all of it is cached by tang after the first turn.
- Measure it in `kiln bench` with an A/B for each layer, following VibeMemBench's advice to gate on headroom.
- Add a bench fixture of repeat tasks on one repo to measure the memory-on vs memory-off delta per tier.

### 5.6 Phased plan

**Phase 1: explicit memory plus budgets** (the smallest valuable step; about 1–2 days)
- `memory/` directory, frontmatter format, generated INDEX, and tier budgets in `prompt.rs::system_prompt`
- `/remember`, `/forget`, `/memory`
- secret redaction: reuse or port gitleaks-style regexes
- file mode 0600 and a local-only path
- tier-budgeted L0 truncation, which also fixes the ROADMAP note on global CLAUDE.md bloat
- the framing line "may be outdated; verify"
- Protocol: `Op::Remember`, `Op::Forget`, `Event::MemoryChanged`, so the Mac app can show and edit memories

**Phase 2: episodes and scoped rules** (days)
- session-end summaries: deterministic fallback plus an LLM-generated version
- a `Recall` tool over summaries and memory by keyword and file touched
- path-scoped rules (`.kiln/rules`, read `.claude/rules`)
- the ranked text repo map from CodeMap's graph, pushed for the weak tier

**Phase 3: learned memory with guardrails** (a week)
- offline extraction into the inbox, with review UI in the TUI and Mac app
- citations plus a deterministic just-in-time check
- usage tracking, and memory citation in answers (the Codex `oai-mem-citation` idea, simplified to `(memory: npm.md)`)

**Phase 4: consolidation and promotion**
- git-backed memory directory, `/consolidate` with a diff for review
- promotion to AGENTS.md or rules
- skill proposals

**Phase 5: evidence-gated extras**
- local embeddings via tang, only if the bench shows grep plus map failing on 1,000+ file repos
- a cross-project user profile only if user-scope entries prove valuable

### 5.7 Key risks and mitigations

| Risk | Mitigation |
|---|---|
| **Persistent injection** (SpAIware, MINJA) | Extraction never sees raw tool output. The inbox needs approval for non-user-sourced items. Provenance goes on every entry. Memory is framed as data. Reuse the MCP quarantine heuristics (injection phrases, hidden Unicode) on memory text. Memory can never change permissions, because enforcement stays at dispatch (ROADMAP §6). |
| **Secrets in memory** | Regex redaction at every write (explicit, extracted, consolidated). Refuse to save if a secret is detected in `source: user` input, and tell the user. Keep 0600 files outside the repo. The sandbox already blocks credential reads. |
| **Memory sent to cloud providers** | A config flag, `memory.cloud = "all" | "user-only" | "none"`. Show an indicator when memory is included in a cloud request. |
| **Stale facts** | Citations with deterministic just-in-time checks. `(unverified)` markers. Usage-based archiving. The "don't store derivable facts" rule. |
| **Bloat and "form degradation"** | Harness-generated index with hard token budgets. Summaries capped at 250 tokens. No transcripts in memory. No-op is the preferred extraction result. |
| **Weak models ignoring or misusing memory tools** | Push instead of pull on the weak tier. No write tool below the strong tier. User-invoked `/recall`. |
| **Prefix-cache invalidation** | Memory is snapshotted at session start and never mutated mid-session. Compaction keeps the memory block as-is (it's in the system prompt, not in history). |
| **Contradictions with AGENTS.md** | The memory framing line says instruction files win when a note conflicts with them. Consolidation flags memory that conflicts with L0 text. Promotion removes the memory entry. |
| **Over-engineering** | Phases 1–2 need no model calls beyond the existing compaction path. Measure every later layer in `kiln bench` before making it a default. |

---

## 6. Source list (with dates)

- Claude Code memory docs: https://code.claude.com/docs/en/memory (accessed 2026-09-23)
- Boris Cherny on RAG vs agentic search (X, 2026): https://x.com/bcherny/status/2017824286489383315
- Codex memories source: https://github.com/openai/codex/tree/main/codex-rs/memories (accessed 2026-09-23); discussion: https://github.com/openai/codex/discussions/12567
- Cursor semantic search (2025-11-06): https://cursor.com/blog/semsearch; memories removal (forum, late 2025): https://forum.cursor.com/t/custom-modes-and-memories-gone-in-2-1/143744
- GitHub Copilot memory (2026-01-15): https://github.blog/ai-and-ml/github-copilot/building-an-agentic-memory-system-for-github-copilot/
- Windsurf memories: https://docs.windsurf.com/windsurf/cascade/memories; SpAIware (2025): https://embracethered.com/blog/posts/2025/windsurf-spaiware-exploit-persistent-prompt-injection/
- Cline Memory Bank: https://docs.cline.bot/best-practices/memory-bank; Roo indexing: https://docs.roocode.com/features/codebase-indexing
- Aider repo map: https://aider.chat/docs/repomap.html
- OpenCode rules: https://opencode.ai/docs/rules/; Continue @Codebase deprecation: https://docs.continue.dev/reference/deprecated-codebase
- Sourcegraph Cody (2024-02-15): https://sourcegraph.com/blog/how-cody-understands-your-codebase; Amp find threads: https://ampcode.com/news/find-threads
- Devin Knowledge: https://docs.devin.ai/product-guides/knowledge
- Letta context repositories: https://www.letta.com/blog/context-repositories/; filesystem benchmark: https://www.letta.com/blog/benchmarking-ai-agent-memory/
- Zep (Jan 2025): https://arxiv.org/abs/2501.13956; Mem0 (Apr 2025): https://arxiv.org/abs/2504.19413; Zep critique of Mem0: https://blog.getzep.com/lies-damn-lies-statistics-is-mem0-really-sota-in-agent-memory/
- Anthropic memory tool (2025-09-29): https://platform.claude.com/docs/en/agents-and-tools/tool-use/memory-tool
- AAIF / AGENTS.md (Dec 2025): https://www.linuxfoundation.org/press/linux-foundation-announces-the-formation-of-the-agentic-ai-foundation
- Evaluating AGENTS.md (Feb 2026): https://arxiv.org/abs/2602.11988
- SWE-ContextBench (Feb 2026): https://arxiv.org/abs/2602.08316
- VibeMemBench (Sept 2026): https://arxiv.org/abs/2609.23570
- Is Grep All You Need? (May 2026): https://arxiv.org/abs/2605.15184
- Deep Agentic Search empirical study (Aug 2026): https://arxiv.org/abs/2608.01507
- Agent Retrieval Bench (Jul 2026): https://arxiv.org/abs/2607.24882
- SWE-Explore (2026): https://arxiv.org/abs/2606.07297
- RULER (2024): https://arxiv.org/abs/2404.06654; Chroma Context Rot (Jul 2025): https://www.trychroma.com/research/context-rot
- MINJA (2025): https://arxiv.org/abs/2503.03704; Memory poisoning defense (Jan 2026): https://arxiv.org/abs/2601.05504; Promptware kill chain (Jan 2026): https://arxiv.org/abs/2601.09625
- LoCoMo audit (third party, unverified): https://dev.to/penfieldlabs/we-audited-locomo-64-of-the-answer-key-is-wrong-and-the-judge-accepts-up-to-63-of-intentionally-33lg

Kiln code read for grounding:
- `crates/kiln-engine/src/prompt.rs`: the `memory_files` walk and `system_prompt`
- `skills.rs`: the 6k-char catalog budget and project-first discovery
- `codemap.rs`: the file graph with churn heat
- `session.rs`: JSONL sessions under `~/.local/share/kiln/sessions`
- `context.rs`: staged pruning and compaction with cache-aware hysteresis
- `docs/ROADMAP.md` §3–6

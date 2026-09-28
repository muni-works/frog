# Local code review: what 4B–32B models can do, and what frog should build

Written 2026-09-24. Scope: reviewing a diff (the agent's own changes, the working tree, or a branch) with open models running on Apple Silicon or a single RTX 3090, and what frog should ship. Claims from vendors are marked **[vendor]**; numbers I saw only in search snippets or secondary write-ups are marked **[unverified]**; my own arithmetic is marked **[calc]**. I did not run any models for this report.

---

## TL;DR

- **Bug-finding review is hard even for frontier models.** On real PRs, frontier models find only 15–31% of the issues humans flagged when given just the diff (SWE-PRBench, 2026). One 2026 study measured F1 of **0.85 on synthetic injected bugs but 0.066 on real bug-fix PRs**, and found F1 fell about 15x from small diffs to large ones (arXiv 2606.15689). Nobody has published precision/recall for a 4B–8B open model doing open-ended review on real diffs. The indirect evidence (SWR-Bench: a 14B reasoning Qwen at about 16% F1) says **an 8B model asked to "review this PR" is a net-negative reviewer**: most of what it says will be wrong or trivial.
- **What does work, including for weak models, is narrow and checkable.** Run deterministic tools first. Give the model one hunk at a time with retrieved context and one narrow question. Force JSON output. Require a concrete failure scenario. Then verify each finding with a *different* mechanism: a failing test, a tool, a second model, or a larger model for just that hunk. Self-verification by the same small model is weak (Zhang et al., ACL 2024; Stechly/Kambhampati 2024).
- **Cursor Bugbot's lessons carry over:** focus only on bugs, run several passes with the diff in different orders and keep findings that a majority agree on, and measure by *resolution rate* (the share of findings that get fixed before merge). Bugbot reports going from 52% to about 76–80% **[vendor]**.
- **Recommendation.** Ship `frog review` as a **gate, not an oracle**:
  1. Tools run first (build, lint, typecheck, tests, secrets).
  2. The local model **explains tool failures** and does **spec-vs-diff** and **per-hunk regression** checks with narrow checklists, using JSON-constrained output via the auto.rs judge pattern.
  3. A finding is reported only if it survives verification, and the default report shows **at most 3 findings**.
  4. The 32B/strong tier, or one cloud call per hunk if the user opts in, confirms high-severity findings.
- **First version (about 1 week):** tool pass, plus spec-vs-diff, plus per-hunk "what could this break" with majority vote over 3 orderings, shown at turn end and in the Changes inspector. Measure it on a new `bench/review` set of injected bugs **and clean diffs**. The target is ≥70% precision; recall is secondary.

---

## 1. Evidence on review quality at small scale

### 1.1 Benchmarks

| Source (date) | Setup | Result | Relevance |
|---|---|---|---|
| [SWE-PRBench](https://www.researchgate.net/publication/403262187_SWE-PRBench_Benchmarking_AI_Code_Review_Quality_Against_Pull_Request_Feedback) (2026) | 350 real PRs, human-flagged issues, LLM judge (κ=0.75), 3 context configs | 8 frontier models detect **15–31%** of human issues diff-only | Upper bound: frontier recall is low |
| [Bigger Isn't Always Better, arXiv 2606.15689](https://arxiv.org/abs/2606.15689) (Apr 2026) | 100 mutation-injected + 50 real bug-fix PRs; Sonnet 4.6, Haiku 4.5, GPT-5.4 mini, MiniMax M2.7, GLM-5 Turbo | Best F1 0.365 (Haiku). **Synthetic F1 0.847 vs real 0.066.** F1 drops 15x from small to large diffs. Near-zero recall on performance bugs (N+1, unbounded queries) | Injected-bug benchmarks flatter models, and diff size kills quality, so chunk small |
| [SWR-Bench, arXiv 2509.01494](https://arxiv.org/abs/2509.01494) (Sep 2025) | Real review comment generation | Qwen-2.5-R1-14B about **16% F1** on change-actions. Reasoning training helps noticeably **[snippet]** | Closest data point for mid-size open models |
| [ContextCRBench, arXiv 2511.07017](https://arxiv.org/html/2511.07017) (Nov 2025) | 9 languages, file-level context | **Textual context (issue/PR description) helps more than surrounding code** | Supports spec-vs-diff: give the model the intent |
| [AACR-Bench, arXiv 2601.19494](https://arxiv.org/html/2601.19494) (Jan 2026) | Repo-level context | Cross-file defects need repo context | Supports per-hunk retrieval of callers |
| [CodeFuse-CR-Bench, arXiv 2509.14856](https://arxiv.org/html/2509.14856v1) (Sep 2025) | End-to-end Python review | Frontier models lead; no small-model win reported **[not read in full]** | — |
| [Greptile benchmarks](https://www.greptile.com/benchmarks) (2025) | 50 injected-bug PRs, vendor-run | Greptile 82% catch rate, Copilot mid-50s, CodeRabbit 44% **[vendor, self-run]** | Recall on synthetic bugs only, no precision |

Scaling from 4B to 8B to 32B to frontier: **I found no study that sweeps open-model size on a review task with precision reported.** An 8B model reaches 11–13/18 on frog-bench *fix* tasks, where a test tells it when it is right. Review has no such signal, and that is the core problem. Treat any "Qwen3 does well on review" claim with suspicion. For example, one search snippet credits Gemma 3 and Qwen 3 with "0.86–0.88 F1", but that is on *text-centric subtasks* (comment classification), not on finding bugs **[unverified, source unclear]**.

### 1.2 Field acceptance data

| Source | Number | Notes |
|---|---|---|
| [Cursor, "Building a better Bugbot"](https://cursor.com/blog/building-bugbot) (2025–26) | Resolution rate 52% → 76%, later "nearing 80%" | **[vendor]**. Bugs only; parallel passes + majority vote over shuffled diff orderings; went agentic in fall 2025 |
| ["Go Home Copilot, You're Drunk", arXiv 2607.21997](https://arxiv.org/html/2607.21997v1) (Jul 2026) | Resolution varies by agent; Codex lowest. The top reasons comments go unresolved are "intentional design decision" and "incorrect suggestion" | Missing project context is the main false-positive source |
| [Reviewer bots on agentic PRs, arXiv 2604.24450](https://arxiv.org/pdf/2604.24450) (Apr 2026) | Core devs resolve design comments; defect comments are handled by peripheral devs **[snippet]** | — |
| [morphllm comparison](https://www.morphllm.com/comparisons/coderabbit-vs-copilot) (2026) | CodeRabbit F1 51.5% vs Copilot 44.5% **[unverified, secondary]** | — |

**Honest read:** well-built frontier tools get roughly 50–80% of findings acted on, and they do it by *suppressing* most candidates. A small model without that suppression layer would be turned off within a day.

### 1.3 Self-verification

- [Small LMs Need Strong Verifiers to Self-Correct, arXiv 2404.17140](https://arxiv.org/abs/2404.17140) (ACL 2024): models of 13B and under do not self-correct reliably without a strong verifier.
- [Stechly/Kambhampati, arXiv 2402.08115](https://arxiv.org/pdf/2402.08115) (2024): self-critique loops can be *worse* than answering once.
- [Fragment-level cross-model verification (OpenReview)](https://openreview.net/forum?id=U19s6I8Q0u): verifiers from a different model family beat self-verification, and same-family verifiers fall in between **[abstract only]**.

**Implication:** "ask the same 8B to refute its finding" is cheap and may filter a few confabulations, but it cannot be the gate. Real gates are, in order: execution (a test that fails), a tool, a bigger or different model, and a vote across diverse prompts. Diverse prompting is measured to help for Bugbot **[vendor]**.

---

## 2. Techniques ranked by evidence

| Technique | Evidence | Use in frog |
|---|---|---|
| Small chunks (per hunk) | Measured: 15x F1 drop on large diffs (2606.15689) | Yes. One hunk plus context per call |
| Intent/spec text in context | Measured: ContextCRBench | Yes. Commit message, user request, or turn prompt |
| Repo context (callers, tests) | Measured: AACR-Bench, SWE-PRBench configs B/C | Yes. Use codemap.rs to find callers of changed symbols, capped at about 2K tokens |
| Majority vote over shuffled passes | Measured in production **[vendor, Bugbot]** | Yes. 3 passes; tang prefix caching makes the shared prefix cheap |
| Reasoning/thinking | Measured: SWR-Bench (reasoning training helps) | Yes for the verify stage, with a budget (thinking.rs); no for the first pass |
| JSON-constrained findings | Anecdotal for quality, solid for parseability | Yes. Schema forces `line`, `scenario`, `severity`, `confidence` |
| Required concrete failure scenario | Claude Code /code-review design; anecdotal | Yes. No scenario means the finding is dropped |
| Write a failing test for the finding | Execution is the strongest verifier (2404.17140 logic) | Yes for 32B/strong tier; 8B test-writing is shaky |
| Self-refutation, same model | Weak/negative (above) | Only as a cheap pre-filter |
| Cross-model / larger-model verify | Measured cross-family > self | Yes. Escalate per finding |
| Explain tool failures rather than hunt bugs cold | Not directly benchmarked; matches frog-bench (models do well when a check exists) | Yes, highest-value model task |
| Chain-of-verification | General LLM result (2023); not code-review specific | Folded into the verify prompt |
| Style review | Low value; linters own it | No |

---

## 3. Deterministic tools first

Most "findings" people actually act on for local changes are compile errors, type errors, lint errors, failing tests, and leaked secrets. These are free, and they are never wrong in the way a model is wrong.

| Language/area | Tool | Covers |
|---|---|---|
| Rust | `cargo check`, `cargo clippy -- -D warnings`, `cargo test` | Types, borrow errors, about 700 lints, tests |
| TS/JS | `tsc --noEmit`, `eslint`, `npm test` | Types, lints |
| Python | `ruff`, `mypy`/`pyright`, `pytest` | Lints, types, tests |
| Swift | `swift build`, SwiftLint | — |
| Any | `semgrep --config auto` (only on changed files) | Security patterns |
| Secrets | `gitleaks protect --staged` | Keys/tokens |
| Deps | `cargo audit`, `npm audit` | Known CVEs, when lockfiles change |
| Coverage | `cargo llvm-cov` / `coverage.py` diff | Flags "changed lines with no test". A good cheap signal for the model to target |

**Routing rule:** tools run on changed files and their results attach to hunks by line. The model is only asked about (a) tool failures, which it explains and proposes a fix for, and (b) things tools can't see: intent mismatch, logic and edge cases, error handling, and broken callers. Only tools that are installed get run. frog should detect them the way `bash.rs` already runs commands, with no new dependencies.

---

## 4. Precedents

| Tool | Design | Lesson |
|---|---|---|
| [Cursor Bugbot](https://cursor.com/blog/building-bugbot) | Bugs only, parallel passes, majority vote, later agentic; tracks resolution rate; [Autofix](https://cursor.com/blog/bugbot-autofix) | Narrow scope + voting + the right metric |
| PR-Agent / Qodo (open source) | One-shot `/review`, `/improve` with a YAML-structured output; works with any LiteLLM model including Ollama | Structured output works; community reports that small local models give generic output **[anecdotal]** |
| Reviewdog / Danger | Pipe linter output into inline PR comments; rule-based | The deterministic half of the pipeline, already solved |
| Sourcery, Ellipsis, Greptile, CodeRabbit | Hosted, frontier models, codebase index, learnings from dismissed comments | Suppression and learning from "dismiss" matter |
| aider / OpenCode / Continue | Review exists as a prompt or slash command, not a pipeline | No precedent for a *verified* local reviewer. I found no local-LLM review project with published usage or precision |
| Claude Code /code-review | Parallel dimensions, adversarial verification, severity + scenario, inline comments, `--fix` | The target shape. frog needs tools and escalation in place of raw model strength |

---

## 5. Design for frog

### 5.1 Pipeline

```
diff source: turn checkpoint (checkpoint.rs) | working tree | branch..HEAD
  │
  ├─ 0. split: hunks grouped by function (codemap), ≤ ~150 changed lines/chunk
  ├─ 1. tools (parallel, changed files only): build/typecheck, lint, tests, gitleaks, semgrep
  │      → tool findings are FACTS; attach to hunks
  ├─ 2. model pass A — spec vs diff (1 call, whole diff summary + intent):
  │      "list requested behaviours not implemented; list changes not requested"
  ├─ 3. model pass B — per hunk × 3 shuffled/reframed prompts (prefix-cached):
  │      checklist: {null/None/unwrap, off-by-one/bounds, error path swallowed,
  │      changed signature vs callers (callers retrieved), state/concurrency,
  │      removed behaviour}; JSON: [{line, category, scenario, severity, confidence}]
  │      tool failures on this hunk → "explain + minimal fix" instead
  ├─ 4. merge: cluster by (file, line±3, category); keep if ≥2/3 votes
  ├─ 5. verify (per surviving finding, thinking on, budget ~1K):
  │      a) same-model refute prompt (cheap filter)
  │      b) strong tier: write a failing test → run it (execution = confirmed)
  │      c) else escalate hunk to larger/cloud model if the user allows
  ├─ 6. rank: tool-failure > test-confirmed > model-verified; cap default view at 3
  └─ 7. output: JSON report → TUI list, Mac Changes inspector inline, exit code for hooks
```

### 5.2 Reusing frog pieces

- **auto.rs judge pattern.** A grammar-constrained call with a timeout, where any failure means "no finding". It has the same shape as the per-hunk reviewer. Fail closed toward silence, not noise.
- **subagent.rs.** Runs the verify stage and test-writing in a disposable worktree (`checkpoint::create_attempts`) so the user's tree is never touched.
- **thinking.rs.** Thinking off for pass B, budgeted on for verify. That matches the `budget()` doubling policy for "planning".
- **harness.rs tiers.** Choose the pipeline by `Tier` (below).
- **checkpoint.rs.** A per-turn diff is the natural unit for "review the agent's own changes at turn end".
- **codemap.rs.** Caller retrieval for changed symbols.
- **tang-llm.** Prefix caching (system prompt + checklist + file context shared across the 3 votes), `format` JSON grammar, and suffix drafting (the JSON is copy-heavy: file paths and quoted lines).
- **Mac app.** Findings render as gutter markers in `ChangesInspector.swift`, with a severity badge on the turn in the timeline rail, and "Fix" sends the finding back as a prompt.

### 5.3 Model tiering

| Tier | Trust it with | Don't trust it with |
|---|---|---|
| 4B (Weak) | Explaining a compiler/test error; summarizing the diff; spec-vs-diff *checklist ticking* | Any free-form bug claim. Findings are suppressed unless a tool backs them |
| 8B (Medium) | Per-hunk checklist with 3-way vote; refute filter; explaining failures + fix proposal | Test-writing as a verifier (unreliable); cross-file reasoning; performance bugs |
| 14–32B / 30B-A3B MoE (Strong local) | Everything above + writing a failing test in a worktree; caller-impact analysis | Performance/security depth (frontier also near zero on perf) |
| Cloud (opt-in, per hunk) | Confirming a high-severity finding the local model couldn't verify | — (only the hunk + retrieved context is sent, and that is shown to the user first) |

The escalation rule is to send a hunk to cloud only when severity is high **and** no tool or test confirmed it. That is a handful of calls per review, not the whole diff.

### 5.4 Latency budget [calc]

The inputs come from inference-speed.md: Qwen3-8B 4-bit, about 90 tok/s decode on the 3090 in tang; 3090 prefill about 2K tok/s; M4 Max prefill 0.5–1K tok/s and decode about 60–100 tok/s. The assumptions per hunk call are about 3K prompt tokens (of which about 1.5K is a cached shared prefix) and about 250 output tokens without thinking.

| Step | 3090 (8B) | M4 Max (8B) |
|---|---|---|
| One hunk vote (1.5K uncached prefill + 250 decode) | ~0.8 + 2.8 ≈ 3.5 s | ~2 + 3 ≈ 5 s |
| 3 votes, shared prefix cached | ~8 s | ~12 s |
| 10-hunk diff, pass B | ~80 s (serial) | ~2 min |
| Verify 3 findings, 1K thinking each | ~35 s | ~50 s |
| **Total, typical turn diff** | **~2 min** | **~3 min** |

At these numbers, per-hunk review is **too slow to block every turn** on a Mac. Instead:

- at turn end, run tools + spec-vs-diff by default (about 10–20 s)
- run pass B in the background and surface its results when done
- run the full pipeline on `/review`, before commit, and pre-push

A 32B dense model is about 4x slower per token. Keep it for verify only, or use a 30B-A3B MoE, whose decode is close to 8B speed.

### 5.5 Keeping false positives low

- The default view is **≤3 findings, bugs only**. Style never appears. Everything else goes behind "show N suppressed".
- A finding without a scenario, a line anchor, or a vote majority is dropped silently.
- Dismissals ("intentional", "wrong") are recorded in memory.rs as project notes and fed back as "known intentional patterns". The unresolved-comment study says project context is the main failure.
- Track resolution rate locally (shown vs fixed within the session) and auto-tighten thresholds when it falls below about 50%.

### 5.6 UX

- `/review [target]` and `frog review --staged|--branch|--turn` output human text or `--json`.
- **Turn end:** a quiet one-line status ("tests pass · spec: 1 unaddressed item · 0 findings"), with details in the Changes inspector.
- **Before commit:** the TUI offers review when the user asks the agent to commit.
- **Pre-push hook:** `frog review --branch @{u}.. --fail-on high` blocks only on tool failures and test-confirmed findings.
- **Fix mode:** a finding becomes an agent prompt applied through the normal checkpointed turn.

### 5.7 Measurement: `bench/review`

- Build it from frog's own bench tasks and repo history:
  - (a) **injected bugs**: mutations such as a flipped comparison, a removed error check, an off-by-one, or a changed signature with a stale caller, applied to the reference solution diffs
  - (b) **real bugs**: frog commits that were later fixed, mined from `git log`
  - (c) **clean diffs**, which are needed to measure false positives
- Aim for about 60 cases to start, roughly 40% clean.
- Metrics:
  - precision
  - recall
  - false findings per clean diff
  - wall time per backend
- Report injected and real separately, because the 2606.15689 gap (0.85 vs 0.07) says the synthetic number alone lies.
- **Targets for shipping pass B by default:**
  - precision ≥70%
  - ≤0.2 false findings per clean diff
  - recall ≥30% on injected bugs

  If 8B can't hit these, pass B stays opt-in and only tools + spec-vs-diff ship.

### 5.8 Phased plan

| Phase | Scope | Effort |
|---|---|---|
| 1 | Tool runner on changed files; spec-vs-diff call; JSON schema; turn-end status line; `/review` in TUI | ~1 week |
| 2 | `bench/review` (injected + clean + mined), precision/recall report in frog-bench | ~3–4 days |
| 3 | Per-hunk pass B with codemap caller retrieval, 3-vote merge, refute filter; tune on bench | ~1 week |
| 4 | Changes inspector gutter findings, fix button, dismiss→memory | ~1 week |
| 5 | Strong-tier failing-test verifier in worktree; opt-in cloud escalation per hunk; pre-push hook | ~1–2 weeks |

---

## Gaps and unverified items

- No published precision/recall for Qwen3 4B/8B/32B, Gemma 3, Devstral, or GLM on real-diff bug finding. frog's bench would be among the first.
- Bugbot, Greptile, and CodeRabbit numbers are vendor-run or secondary.
- The SWR-Bench and SWE-PRBench numbers came from abstracts and search snippets; I did not parse the PDFs.
- The latency table uses 3090/M4 Max numbers that are themselves partly calculated in inference-speed.md. JSON-output speedup from suffix drafting is not counted.
- I did not find usage data for any "local LLM code review" project, or published designs for Ellipsis, Sourcery, or Continue's review feature.

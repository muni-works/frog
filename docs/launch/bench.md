# Bench page (structure + rules), published at frog.toys/bench

Status: STRUCTURE. Numbers get filled as results land this week. Every number on the page has a
date, hardware, model build, command and raw log link. A number with no receipt doesn't go up.

Reference points: Artificial Analysis-style provider pages (single-stream output tok/s after the
first token, TTFT, a dated reading) are what readers will compare us to, so we report in that shape
and say plainly where ours differs (engine vs API, our box vs their probes).

## Rules

1. **API numbers first, engine numbers labeled "engine".** Users get the API number, which runs
   through the edge (about −4.5% tok/s and +0.2 s TTFT on Oct 21).
2. **Every row has a date, hardware, quant, prompt set, n and a raw-log link.** Medians, with the range.
3. **Correctness before speed.** A tree speed number only appears next to "ids match the CPU oracle
   (n/n)" from the same build. A faster kernel that fails the harness doesn't get a row.
4. **Targets are never results.** The trajectory section shows measured points only. A planned
   step is drawn as a gap, not a dotted line to a number.
5. **Competitor numbers are quoted, dated and linked**, never re-derived. Our own same-day h2h
   gets its own section, run against both APIs from the same client.
6. **When a number gets worse, it goes up too.** The changelog keeps old rows.

## What we will NOT claim (on Oct 30)

- "#1", "fastest" or "fastest provider". That needs (a) a same-day h2h vs Novita from the same
  client (needs Cam's Novita key) and (b) an independent listing (AA outreach on hold). Until then
  the strongest phrasing is "the numbers we measured, with the method".
- The tree's 1,000+ tok/s, or any tree speed not measured on the published build. "100-300 by
  Friday" is an estimate and stays in internal docs.
- Quality or pass@1 for Coder-Next on frog cloud. We haven't run the 20-task pass@1. Quality is the
  model's (link Qwen's card), and our job is to show we don't degrade it (KL, top-1 agreement).
- Engine numbers presented as what users see.
- The 245 tok/s figure. It's in internal notes, and the writeup's maximum is 234.4 (engine).
  Reconcile it or drop it.
- Cost-per-task claims (the plan's ~$0.06/task on an H200 at 30% busy is a model, not a measurement).
- Anything about FP4, Qwen3 Coder Next or B300 serving.
- "Adding a machine never slows you down." Both no-caps runs (below) had a task whose median got
  slower with the second machine. The additivity bench is a target, not a result.

## Page layout

### 0. Header
One line on what this page is, the date of the last update, and the build (frog sha, tang sha,
edge deploy id). Link the method doc and the raw-log bucket.

**Host: `site/bench/index.html` in the frog repo** (the site deploys from `site/`, and the energy
card already reads a `data/` export, so this follows the same pattern). Static HTML + a
`site/data/bench-v2.json` export per update; the post links to `frog.toys/bench` only after this
page is deployed — a link to a 404 is a self-own. Build it Oct 29 against the filled numbers; if
numbers are still landing at the go/no-go, publish the page with the sections that have receipts
and mark the rest "measuring now".

### 1. frog cloud: Qwen3-Coder-Next (what users get)

#### Current engine (2026-11-05)

Qwen3-Coder-Next on tang, engine-level (not through api.frog.toys).

| metric | tok/s |
|---|---|
| single stream, plain decode | 234 |
| single stream, MTP drafts on | up to 402 |
| batch B=64, aggregate decode | 1,817 |
| serve, C=64 concurrent, decode-heavy | 1,078 |
| prefill | 6.6k–7.6k |

API-level numbers (through api.frog.toys: per-stream decode at 1.2k and 10k prompts, cold and
cached TTFT, 8/16-stream load curve, production 24 h p50s) have no measurement since Oct 21.
Publish that table only once it's re-measured on the deployed build; until then the page says
"measuring now" for it.

Load-test method (frog cloud manager, Oct 28-29): signed direct-to-router sweep against the
2-node fleet, 8 streams/node plus queue pressure; exports p50 TTFT, per-stream and aggregate
tok/s, error/reject rate, queue depth. Historical baselines, superseded (Oct 21, 1 node, 4 streams): 447 tok/s
aggregate, 137/stream, TTFT ≤ 1.2 s; 8 streams: 588 aggregate. Publish the load curve honestly,
not just the single-stream peak.

Footnote, engine-level (labeled): single-stream 4-bit 234 (2026-11-05; Oct 21: 234.4). 8-bit Q8_0
was 222.2 on Oct 21 (historical, not re-measured). Quant quality: Q4 vs Q8_0 KL median 0.0005, top-1 agreement
96.8-97.0%.

Hardware: these numbers were measured on 1 H200 141 GB node carrying
qwen3-coder-next 131072 ctx + qwen3-8b + qwen3-vl-8b. Frog Cloud's serving hardware has changed since; confirm from `/status` and re-date before publishing. Weights:
unsloth UD-Q4_K_XL GGUF. Method: 3 coding prompts (explain/refactor/write) from tang
`docs/bench/qwen3next-aa/make_prompts.py`, 512 output tokens, greedy, drafts off, tok/s after the
first token.

<!-- HISTORICAL (superseded by the 2026-11-05 table above). Oct 21 reference values (re-measure Oct 29 on the deployed build, after any FA2 swap):
API 224.7 (sampler fix) / ~215 via api.frog.toys; 10k 190; TTFT cold 1.8-2.2 s, cached 18-95 ms;
8 streams 72.5/498 (no MTP). Prod Oct 25 metrics showed 86 tok/s per stream under real load:
publish the load curve honestly, not just the single-stream peak. -->

### 1b. No caps: your machines, one agent

`frog-bench swarm`: N agents in parallel on hardware you own, fixed wall time, each run in its own
worktree of one seeded repo, every model call placed by the node scheduler. Method and the full
table: [docs/no-caps-bench.md](../no-caps-bench.md) (muni-works/frog#281, #285). Raw results:
`bench/results/swarm-2026-11-11-mac-mew/` and `bench/results/swarm-2026-11-11-mac-mew-8b/`
(`swarm.json`, `report.html`).

Hardware: this Mac (M4 Max) + mew (RTX 3090). 6 agents, 15 minutes per phase, all 9 tasks.
Baseline is mew only, then the pool.

| model | mew only: passed / runs | Mac + mew: passed / runs | aggregate tok/s | stalls | 429 / 5xx |
|---|---|---|---|---|---|
| Qwen3-8B-4bit | 21 / 42 | 41 / 64 | 86 → 128 | 72 → 31 | 0 |
| Qwen3-0.6B-4bit | 0 / 68 | 1 / 86 | 321 → 504 | 44 → 28 | 0 |

The honest part, from `swarm.json` → `additivity` (median seconds per task, mew only → Mac + mew):

- **Qwen3-8B:** one of 9 tasks got slower: edit-json-config 101 → 120 s.
- **Qwen3-0.6B:** three of 9 tasks got slower, all short ones: add-function 11 → 20 s,
  edit-json-config 34 → 37 s, present-next-steps 20 → 31 s. The 0.6B model passes almost nothing,
  so read that run for throughput and placement, not for quality.
- The additivity check (no task median more than 5% worse) **fails on both runs.**
- The mew-only baseline isn't pure: a pinned node that drops out briefly falls back, so a few
  percent of baseline calls ran on the Mac. That flatters the baseline.
- Stalls are queueing: 6 agents on two nodes that each serve one request at a time.

What it supports: with the 8B model, adding the Mac roughly doubled passed runs in the same 15
minutes (21 → 41) with zero rate-limit errors. What it doesn't: that every task gets faster, or
anything about a 24-hour run (not run yet; the procedure is in no-caps-bench.md).

### 2. Market context (quoted, not ours)

| provider | single-stream tok/s | source | read on |
|---|---|---|---|
| Novita (FP8) | 174 (Oct 20; re-read before publishing) | AA provider page, linked | Oct 20 |
| others listed by AA for Qwen3-Coder-Next | | AA | |

One sentence: these are AA's measurements of other APIs over the internet; ours above are our
client against our API. Different probes, so not a ranking.

### 3. Same-day head-to-head (only if run)
Same client, same prompts, same hour: frog api vs Novita, speed n=3 + 20-task pass@1. If it hasn't
run by publish time, this section reads "not yet run" and nothing else.

### 4. tang: GLM-5.3-Flash, correctness first

| build | hardware | ids vs CPU oracle | prefill (20 tok) | decode tok/s | notes |
|---|---|---|---|---|---|
| naive kernels (4 bugs fixed) | 1× B300, all-GPU | **8/8** `785 1196 6801 264 6386 38038 911 279` | 22.9 s | 0.52 | correctness build, naive by design |
| + grouped MoE | | | | | |
| + CUDA graphs | | | | | |
| + fused mHC | | | | | |
| + KDA split-K prefill | | | | | |

Each row: tang sha, the `TANG_KERNEL_VERIFY` result for the new kernel (windows checked / failed),
and the raw log. A row whose ids don't match isn't published as a speed number. It's listed as
"regressed, not merged".

**Trajectory chart:** measured decode tok/s per merged kernel step, log y-axis, with a single
labeled horizontal line for speed of light (≈2,300 tok/s at ~3.5 GB read per token on 8 TB/s).
That line frames every point as a % of SOL, the honest way to show headroom. No projected points.

### 5. Kernel verification
- the planted-bug transcript (from docs/kernel-verify.md), with a link to the script
- for each step in §4, the verify summary line

### 6. Method, reproduction, raw logs
Copy-pasteable commands for each table (build flags, model download, prompts, the run), and the
raw logs per row (zest `bench/<date>/`, tang `docs/bench/`).

### 7. Changelog
Dated entries, newest first, including regressions.

## Fill schedule

| number | owner | from |
|---|---|---|
| API/engine Coder-Next rows | zest | re-run on the deployed build, Oct 29 |
| production 24 h | zest | Grafana frog-cloud dashboard export |
| Novita/AA reading | release | AA page, read on publish morning |
| tree rows | tang | each merged kernel step, with its verify summary |
| harness coverage | tang | `kernel_test!` count vs kernel count |

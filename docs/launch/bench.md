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
- Anything about FP4, dart or B300 serving.

## Page layout

### 0. Header
One line on what this page is, the date of the last update, and the build (frog sha, tang sha,
edge deploy id). Link the method doc and the raw-log bucket.

### 1. frog cloud: Qwen3-Coder-Next (what users get)

| metric (through api.frog.toys) | value | range | n | date |
|---|---|---|---|---|
| decode tok/s, 1 stream, ~1.2k prompt | {{API_1STREAM}} | | 3×3 | |
| decode tok/s, 1 stream, ~10k agent prompt | {{API_10K}} | | 3 | |
| TTFT, 1.2k prompt, cold | {{TTFT_COLD}} | | | |
| TTFT, cached prefix | {{TTFT_CACHED}} | | | |
| 8 streams: per-stream / total tok/s | {{API_8S}} | | | |
| production, last 24 h: p50 TTFT, p50 per-stream tok/s, error rate | {{PROD_24H}} | | Prometheus | |

Footnote, engine-level (labeled): single-stream 4-bit {{ENGINE_Q4}} (Oct 21: 234.4), 8-bit Q8_0
{{ENGINE_Q8}} (Oct 21: 222.2). Quant quality: Q4 vs Q8_0 KL median 0.0005, top-1 agreement
96.8-97.0%.

Hardware: 1× H200 141 GB per node, {{NODES}} nodes. Weights: unsloth UD-Q4_K_XL GGUF. Method: 3
coding prompts (explain/refactor/write) from tang `docs/bench/qwen3next-aa/make_prompts.py`, 512
output tokens, greedy, drafts off, tok/s after the first token.

<!-- Oct 21 reference values (re-measure Oct 29 on the deployed build, after any FA2 swap):
API 224.7 (sampler fix) / ~215 via api.frog.toys; 10k 190; TTFT cold 1.8-2.2 s, cached 18-95 ms;
8 streams 72.5/498 (no MTP). Prod Oct 25 metrics showed 86 tok/s per stream under real load:
publish the load curve honestly, not just the single-stream peak. -->

### 2. Market context (quoted, not ours)

| provider | single-stream tok/s | source | read on |
|---|---|---|---|
| Novita (FP8) | {{NOVITA_AA}} (Oct 20: 174) | AA provider page, linked | {{DATE}} |
| others listed by AA for Qwen3-Coder-Next | | AA | |

One sentence: these are AA's measurements of other APIs over the internet; ours above are our
client against our API. Different probes, so not a ranking.

### 3. Same-day head-to-head (only if run)
Same client, same prompts, same hour: frog api vs Novita, speed n=3 + 20-task pass@1. If it hasn't
run by publish time, this section reads "not yet run" and nothing else.

### 4. tang: GLM-5.3-Flash ("tree"), correctness first

| build | hardware | ids vs CPU oracle | prefill (20 tok) | decode tok/s | notes |
|---|---|---|---|---|---|
| naive kernels (4 bugs fixed) | 1× B300, all-GPU | **8/8** `785 1196 6801 264 6386 38038 911 279` | 22.9 s | 0.52 | correctness build, naive by design |
| + q8 gemv8 | {{HW}} | {{n/n}} | | {{}} | |
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
- harness coverage: kernels with a `kernel_test!` / total GPU kernels in tang-llm ({{COVERAGE}})
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

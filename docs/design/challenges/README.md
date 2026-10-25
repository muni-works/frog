# challenges: agent speedrun (A) + cad/physics trial (C)

status: draft spec. cam picked A + C from the brainstorm. one spine, two challenges.

## 0. the spine

both challenges are one machine with two judges. split into speedrun.md / cad-trial.md: not needed, this file stays under ~4 pages.

1. **task set.** versioned, generated or harvested. an **open set** (published, practice + phase 1) and a **live set** (hidden: new PRs merged after open for A, fresh seeds for C; phase 2).
2. **entry = provenance + artifact.** a frog session's share bundle plus what it produced (a diff for A, loon source for C). no bundle, no entry.
3. **judge re-runs from source.** our worker rebuilds the artifact from source in a clean container and runs the verifier. the judge's JSON is the only score. anything the contestant reports is display-only.
4. **every entry mints `frog.toys/s/<token>`** (pr-viral §2.2). every board row links its replay. the replay is the demo.
5. **boards are views.** one `entries` table, static pages over it.
6. **prize ladder ends in hardware.** credits → pro year → cortex head → lymb. C adds: the winning part, printed and shipped.
7. **two phases.** phase 1 is free on the open set. phase 2 is on the live set and needs a paid plan (decision 7).
8. **honest losses.** house baselines go up first, including rows where frog or tang loses. results posts list what nobody solved and every judge bug found.

entry record (one row, both challenges):

```
challenge  task_set@version  task_id  division  model  provider  hardware
bundle_token  artifact_sha  judge{verdict, metrics, judge_version, at}  account?
```

## 1. challenge A — agent speedrun

**tasks.** the blaze gym's PR replay: a merged PR gets reverted, and the agent gets the issue and the pre-PR tree (`gym/pr-replay/materialize.sh`). harvest: 737 clean tasks (frog 34, tang 104, vcad 577, zest 22).
- zest is proprietary, so it's out. only repos that are public at open count, so **≤715**.
- **caveat: "clean" means merge CI was green, not fail-to-pass.** if the reverted tree also passes the suite, a do-nothing diff scores. we need a fail-to-pass filter: keep a PR only if it touched tests that fail on the reverted tree and pass on the merge. yield is unknown. guess 30–50%, so ~200–350 tasks.
- the judge puts the merge commit's test files back before running. contestant test edits are discarded ("do not edit tests" is already in task.md).

**sets.** `sprint-20`: 20 fixed fail-to-pass tasks, mixed across repos, each test run under 5 min, CPU only (no tang GPU tests). this is the launch category. `full`: the whole open set (marathon, later). `live`: PRs merged after open (phase 2; nothing to memorize).

**board 1: wall-clock on frog cloud.** any `cloud/*` model. rank by tasks passed, then by total wall-clock (from session start to the final edit, timed by the gateway). free-tier credits cover about 3 sprint-20 attempts per account, so anyone can enter. tool time on the contestant's machine counts: it's a run on your rig. hosted runners are decision 4.

**board 2: tok/s on your own GPU.** `local/*` models, in tiers: **0.6B**, **4B**, **open** (any OSS weights, size listed). rank by median decode tok/s over the tasks you passed. an entry ranks only if it clears the tier's pass gate (half the house baseline for that tier, posted first). passes break ties. each entry gets a **score card** PNG: model, hardware, tok/s, passes/20, tok/J where frog's energy meter has a reading, and the replay link. that's the benchmark card people share.

**flow.** `frog challenge speedrun --set sprint-20 -m local/qwen3-4b` (new): for each task it materializes the tree, runs one session in auto mode under the challenge network profile, uploads the bundle and submits the diff. the judge returns verdicts and the board updates. the engine already records `tokens_per_sec`, `decode_ms`, `tool_ms` and `user_ms` per turn (crates/frog-engine/src/engine.rs:1441, protocol.rs:1032).

## 2. challenge C — cad/physics trial

design to spec in loon, judged exactly. the judge is a physics engine, and that is the pitch: it markets loon → vcad → phyz, with tang behind the agent.

**seed.** blaze `gym/cad-part`: 4 families (flange, spacer, plate, collar), 50 tasks from `gen_tasks.py`. ground truth is analytic. `verify.py` takes loon → STL (blaze-veval) and checks volume ±2% and bbox. on the smoke flange, volume came out 0.001% off exact.

**tiers** (each tier is a set of procedural families; the families are public, the round's parameters are seeded at open):

| tier | the job | judge | state |
|---|---|---|---|
| T1 geometry | match a spec: volume, bbox, mass ±2% | verify.py (exists) | runs today |
| T2 fit + print | mate with given parts (a collar on a given shaft, a bracket onto a hole pattern) with no interference, and pass the FDM DFM pack (min wall, overhang, hole edge distance) | vcad-kernel-dfm `rules/fdm`, vcad-kernel-tolerance, interference | kernel exists, task generators are new |
| T3 load | carry N newtons at a point with safety factor ≥ k; lowest mass wins | vcad-kernel-fea (von mises, displacement, SF) | kernel exists, families are new |
| T4 sim | the part does a job in a phyz world: a gripper finger holds a 200 g cylinder through a shake, or a snap hook seats. it has to pass N of N seeded runs | phyz-rigid / phyz-contact | engine exists, worlds and criteria are new |

T1–T2 are pass/fail. T3–T4 are pass/fail on the constraints, then ranked on an objective (mass, then material volume). that's what makes it a leaderboard and not a quiz. house baselines include vcad-kernel-topopt on T3, so if topopt beats every human that's an honest loss we publish.

**scoring.** the output is a vcad-receipt `DesignReceipt`: every claim with its oracle, the oracle version, predicted vs measured and units. the judge evaluates the loon source only. uploaded meshes are ignored.

**divisions** (decision 6). **agent**: a frog session, replay required. **hand**: loon written by a person, source published when the round closes.

**prize.** the T3/T4 winners per round get their part printed in house (vcad-slicer-bambu → 3MF → our bambu) and shipped with a printed receipt card. then the ladder (§0.6). stretch: load the T3 winner on a rig and post the photo.

**audience.** mech engineers, CAD people, robotics students (FRC/FTC alumni, uni clubs), hardware twitter, r/3Dprinting.

## 3. anti-cheat (both)

the rule: **provenance required, and the judge's output is the only score.** everything below enforces those two.

**both**
- the judge rebuilds from source in a clean container. contestant-reported numbers are never scored.
- one account per person (github sign-in via better auth). house runs are labeled and can't win prizes.
- judge bugs get bounties, not scores. if you find an exploit, report it for credits. exploiting it is a DQ. every fix goes in the results post.
- caps: 60 s eval timeout and a mesh/size limit (C), a per-task wall cap (A). nobody gets to DoS the judge.

**A, speedrun**
- **no hand-patching.** every changed line has to trace to a model tool call in the replay (Edit/Write args, or a Bash command that writes the file). an untraceable hunk is a DQ.
- **one user message per task**: the task prompt. an extra `TurnStarted` or `user_ms > 0` marks the entry assisted, and assisted entries don't rank.
- **cloud board: model outputs can't be forged.** the gateway logs a hash of every response for each session. the bundle's assistant text and tool-call args have to match those hashes. this is the strongest board, so the bigger prizes go here.
- **local board: self-timed, so it gets checked.** a roofline plausibility check: decode tok/s must be ≤ memory bandwidth ÷ active weight bytes (times the spec-decode factor, if declared). anything over that is flagged automatically. the top 10 per tier redo a short live-set run before prizes, recorded or on our hardware (a mac, mew's 3090).
- **network:** the challenge profile allows only the model endpoint and package registries. the fix is public on github, so any fetch of the upstream repo or PR in the replay is a DQ. the live set covers memorization.

**C, cad trial**
- the kernel is deterministic, so the judge reproduces each entry exactly from its loon source.
- sources and receipts go public when the round closes. near-duplicates are caught by source diff, and the earlier timestamp wins.
- agent division: same replay rules as A (one prompt, no hand edits to the loon).

## 4. build vs exists

| piece | state | work left |
|---|---|---|
| PR-replay harvest (737), materialize.sh, per-task verify | **exists** (blaze/gym) | fail-to-pass filter, public-repo filter, sprint-20 pick |
| per-task test containers with warm cargo caches | new | image per repo@base, built once |
| cad-part T1 (4 families, gen_tasks.py, verify.py, blaze-veval) | **exists** | none for T1 |
| vcad fea / dfm / tolerance / receipt / slicer-bambu | **exists** (kernel crates) | judge glue, T2–T3 generators |
| phyz rigid/contact | **exists** (engine) | T4 worlds + success criteria |
| share endpoint `frog.toys/s/<token>`, bundle, redaction | **specced** (pr-viral §2.2, owned by zest) | a `challenge` block in the bundle (task, set, timings) |
| per-turn tok/s, decode/tool/user ms, energy meter | **exists** (engine) | carry it in the bundle |
| gateway response hashes per session | new (zest) | write-only log + lookup |
| accounts, credits | **specced** (better auth, neon, durable objects) | a "challenge credit" grant type |
| `frog challenge` CLI | new | wraps materialize + session + upload |
| judge queue + workers | new | CPU only, one queue for both challenges |
| boards, score card PNG | new | static pages over `entries`, svg→png on a worker |
| prize fulfillment | new (ops) | printing, shipping, hardware allocation |

reused: tasks, verifiers, kernels, the share format, accounts. new: the judge service, the CLI, the boards, response hashes, and task generators T2–T4.

## 5. timeline

dates are launch beats only. the rest is ordered steps.

| beat | A speedrun | C cad trial |
|---|---|---|
| beat 1, oct 30 (tang IR, #1 speed, frog OSS) | tease only: a line in the post, "the gym opens at beat 2" | — |
| **beat 2, nov 3** (cram + H200) | **opens.** sprint-20 on both boards. the H200 is the board 1 story | tease: T1 practice set public, with house receipts |
| **beat 3, ~nov 17** (app + voice + cortex GA, paid) | phase 1 results and prizes (a cortex head is the prize, launched that day). phase 2 opens on the live set | **opens** T1–T3 inside the vcad app (the GA shell is the workbench). T4 joins once its worlds are ready |
| after beat 3 | weekly board posts | round 1 closes, then winning parts get printed and shipped |

the lymb prize is "one unit when the first lymb ships". it's a promise of a unit, not a date.

**must exist before A opens at beat 2, in order:**
1. fail-to-pass filter and the sprint-20 pick
2. judge workers and test containers
3. `frog challenge` CLI
4. the share endpoint, live (zest)
5. entries table and one static page per board
6. the house baseline rows

if the share endpoint isn't live, A slips: the replay is the entry. gateway hashes can follow in week 1. until they land, cloud prizes wait on them.

## 6. infra cost

these are estimates. the prize budget is cam's money: this section sizes it and commits none of it. turnout is the unknown, so each row has a 500-entrant and a 2,000-entrant number, with 3 sprint-20 attempts per account.

| line | basis | 500 | 2,000 |
|---|---|---|---|
| A inference (free credits) | plan: a frog task is ~800k in / 30k out, ~$0.06 on tang H200 at 30% busy ($0.21 at frog api list). 60 tasks per account | ~$1.8k | ~$7.2k |
| C inference | blaze cad baseline: 22–45k prompt tokens per task, ~99% cached. pennies | <$100 | <$300 |
| judge (CPU, no GPU) | 2–5 min per verification on warm caches. 2–3 dedicated 16-core boxes (~$100/mo each) cover ~120k verifications in 2 weeks. FEA/sims run in seconds to minutes on the same boxes | ~$200 | ~$400 |
| hosting | workers + R2 + neon. bundles are 50–200 KB, ≤2 GB total | <$25/mo | <$50/mo |
| prizes, A per phase | 1 lymb (~$2,000 materials, $5,000 list), 2 mini heads ($999 list; materials from rose), 10 pro years ($240 list, a compute cost to us), credits | ~$3–4k materials | same |
| prizes, C per round | ~10 printed parts ($5–20 filament, $20–60 shipping) + 1 head for the top tier | ~$1–1.5k | same |

**ballpark, both challenges, first round: ~$6–13k.** about half is turnout-driven inference and about half is prize materials. control: a hard cap on the challenge credit pool (e.g. $2k, then a waitlist), kept separate from zest's $45/day GPU cap. no judge GPU is needed: tang tests that need a GPU stay out of sprint-20, and if a later set needs one it runs on mew.

## 7. marketing beat

**the replay button is the demo.** every board row has a ▶ that opens `frog.toys/s/<token>`: the session plays back in time, every edit, test and timing, ending on the judge's verdict. no screenshots needed: every claim is a link.

- **A launch post (beat 2).** "the gym is open: 20 real merged PRs, judged by their own tests. beat our time." the H200 number up top, the house replay right under it, then both boards. house rows include our losses (a frontier model beating tang on passes, if it does).
- **show HN.** "frog speedrun: real PRs, real tests as the judge, replay or it didn't happen." link the board, not the blog. HN rewards real tasks over synthetic benchmarks, and it rewards honest baselines.
- **local board → r/LocalLLaMA and hardware twitter.** the score card PNG: "qwen3-4b · M3 Max · 87 tok/s · 7/20". per-tier rankings give 0.6B a race of its own.
- **C launch post (beat 3).** "the judge is a physics engine." one T3 bracket from start to finish: spec → loon → FEA heatmap (vcad-render) → receipt → the printed part on a desk. sent straight to uni robotics clubs, CAD twitter and r/3Dprinting.
- **cadence.** a weekly board post, a replay of the week, and a results post per phase covering unsolved tasks, judge bugs found and who won what.

## 8. decisions for cam

_tbd_

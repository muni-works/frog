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

_tbd_

## 4. build vs exists

_tbd_

## 5. timeline

_tbd_

## 6. infra cost

_tbd_

## 7. marketing beat

_tbd_

## 8. decisions for cam

_tbd_

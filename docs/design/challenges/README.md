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

_tbd_

## 2. challenge C — cad/physics trial

_tbd_

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

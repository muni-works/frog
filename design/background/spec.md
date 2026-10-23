# background work in frog

one model, one ledger, one place to look. for the human and for the agents.
mockups: `index.html` (7 screens, light and dark). shots: `shots/`.

## 0. what's true today (frog @ type-to-focus, read-only survey)

- `background.rs` keeps tasks, jobs, monitors and timers in a **memory-only** `BTreeMap` (background.rs:86-96). ids are `task-N`, `job-N`, `mon-N` (timers share `mon-`). on engine exit, interrupt or clear, `stop_all()` kills everything (engine.rs:708, 509, 518, 1490; background.rs:228-241). job logs survive on disk under `<store>/<session>.jobs/`, but nothing reattaches them.
- the stale-handle error is ``no background task, job or monitor `X`. Known: …`` (background.rs:607-614). after a restart the agent's ids are simply gone.
- the engine emits `BackgroundStarted/Progress/Done` (protocol.rs:542-561), but the mac app's `Event` enum has no cases for them, so **they decode to `.unknown` and nothing shows them** (FrogKit/Core/Protocol.swift:600-651). no menu bar item exists. the dock badge counts pending answers (Notifier.swift:76-106).
- wakes are injected as plain text (`<job-done>`, `<monitor-done>`, `<wakeup id after_s>`), and they're dropped if the engine restarts first. a timer's wake carries `after_s`, not measured time. monitors give up one interval early (`elapsed + interval > timeout`, background.rs:542). the "woke early, 12s" report was most likely a different wake read as the timer: the text didn't say which timer or how long it really waited.
- compaction and resume inject nothing about live background work (engine.rs:202-212, 1162-1168).
- session states come from the app broker: `dead` = `!engineAlive`, plus waiting, running and idle (SessionBroker.swift:54-61). a child that dies has no effect on its parent or on its pods.
- terminal panes are force-closed on resume (engine.rs:1008-1012).
- pods, PRs, CI and `nohup … & disown` scripts are invisible to frog.

## 1. the model: one thing called a job

Everything that keeps going after the turn ends is a **job**. A job has a kind, an owner, a state, a cap and a ledger entry on disk.

| kind | id | examples | what "done" means |
|---|---|---|---|
| shell | `j31` | Bash `run_in_background`, merge queues, log tails | exit code |
| watch | `m7` | Monitor with `until_regex` / `until_exit` | matched, or cap reached |
| timer | `m8` | Monitor `after_s` | due time reached (wall clock) |
| agent | `t2` | Task with `background: true` | report returned |
| session | `s3` | StartSession children, workers in worktrees | went idle with a report |
| pod / pr / ci | `p1` `r81` | GPU pods, PRs, CI runs, tracked with `Track` | a probe says so |
| approval / ask | `a9` | permission cards, Ask questions | Cam answered |

Ids are short, per session, **never reused and stable across restarts**. Old `job-3` / `mon-2` ids resolve as aliases.

**States.** One machine for every kind:

```
queued ──▶ running ──▶ done (exit 0, matched, reported)
              │  ▲  └─▶ failed (exit ≠ 0, timed out, probe error)
              ▼  │  └─▶ stopped (someone ended it; says who)
        waiting-on-you            (blocked on an approval or ask)
running|waiting ──▶ dead      (process or engine gone, no exit recorded)
running|waiting ──▶ orphaned  (job alive, owner dead)
orphaned ──▶ running (owner back, or adopted) | stopped | done
```

`dead` and `orphaned` are the two that hurt today. They are different on purpose. **dead**: the work is gone and the output is kept. **orphaned**: the work is still going (and maybe billing) with nobody listening.

**Sessions get the same vocabulary**, decided by signals the user never has to interpret:

| state | signal |
|---|---|
| running | engine heartbeat ok, a turn or live job |
| idle | heartbeat ok, 0 live, 0 cards |
| waiting on you | heartbeat ok, ≥1 card open |
| dead | no heartbeat for 30s, or pid gone without a clean exit |

**Ownership.** The session that started a job owns it. When an owner dies, its live jobs are **orphaned and move up to its parent** (worker → manager → chief → Cam). The parent gets one wake that says so. Caps keep applying. When the owner comes back, it reads its ledger and takes its jobs back. A root session with no parent hands orphans to Cam's inbox.

**Caps.** Every job has a time cap. Anything that costs money has a cost cap and an action at the cap (stop, pause, or ask). Defaults: shell 30m, watch 2h, agent $1, session $5, pod: required at `Track` time. A standing approval (frog-cloud-10's always-on) is a cap of `standing`, shown as such.

## 2. the human UI

**Sidebar.** Two rows at the top: **waiting on you** (orange count) and **activity** (`11 live`). Session rows get one status glyph that can't be confused: spinner (running), hollow ring (idle), orange dot (waiting), red flatline (dead), dashed red ring (orphaned work). The detail line says why: `stopped 12m · pod billing $10.58/hr`. The footer shows the burn rate (`$15.87/hr · 2 pods`) and today's spend against the daily cap.

**Activity (⌘0).** The one global view. Rows are grouped by owner, as a tree, with each group's session state in the header. Columns: what (name, id, command), state, waiting for, elapsed with a **rail** (elapsed against the cap, one tick per check, a hollow mark for the next check), cost and cap, next. Filters: live, needs you, ended today, all. The inspector shows the owner chain, history, last output, and actions: **Stop, Pause, Extend, Run again, Full log**. Keyboard: j/k, ⏎, ⌫, e. The existing ActivityViewer pill opens this view.

**Waiting on you (⌘⇧0).** One inbox for everything blocked on Cam across all sessions. It's grouped by what the wait costs: **costing money**, then **blocking work**, then **decisions**. Each card says who, what, why (the agent's reason), what it touches, what it blocks, how long it's waited, and the recommendation as the first button. Answer inline. ⌘⏎ takes the first choice. Answered cards collapse to one line with Undo for 4s. Effects of one cause fold into one card (a dead manager is one card, not three). Finished jobs and child reports never land here.

**Inline transcript rows.** One row type (components.md §3) per job, updated in place: lead glyph, id, headline, chips, elapsed, state. Starting a job adds a row. Its wake adds a quiet `woke on j29` line, and the row turns done. A restart adds one notice: `app restarted at 14:23 · 4 jobs picked up · 1 lost`. A floating **live bar** above the composer shows `5 running · 1 needs you · next wake 0:12`.

**Dead manager.** Opening a dead session shows a banner first: the sad gray face, when the engine stopped and why, what it still owns (pods and their burn), what was lost, and the actions **Restart engine**, Stop pod, Hand to chief. The transcript stays readable behind it.

**Pods.** A pod is a job with a cost meter. Cost so far against the cap and time against the cap (both with an 80% mark), "which cap hits first", the probe and when it next runs, the at-cap and when-idle rules, and the ownership history. Actions: Extend 1h, Raise cap, Pause (keep the volume), Stop pod.

**Menu bar and dock.** A menu bar face whose mood is the aggregate state (working, waiting, sad), with the needs-you count. Its menu lists needs-you items, then running sessions, then spend. The dock badge is the needs-you count and nothing else.

**Notifications.** *Send when:* something has waited on you 60s and you aren't looking at it; an engine dies while it owns live work or money; a cap hits 80% and again when it acts; you asked to hear ("tell me when"). *Stay quiet when:* a job ends normally (its owner hears); a watch checks; a child reports to its parent; the row is on screen; the same cause alerted in the last 10m. More than 3 at once fold into one. "Pause alerts for 1 hour" lives in the menu.

## 3. the agent UX

**The background block.** Appended to every turn's context, and always after compaction and after a restart. It's at most 30 lines: live jobs with id, kind, state, what each waits for, elapsed, cap and next check; children one line each (with liveness); anything held for a dead child; events since the last turn. Seen ended items drop out. It ends with the rule: *ids are stable; don't poll; every live item wakes you.* (Text in `index.html`, the agent context screen.)

**Tools.**
- `Jobs {filter, children}`: one list for every kind. `JobOutput`, `JobStop` and `TaskOutput` keep working and accept any id.
- `JobExtend {id, minutes|dollars}`: within the agent's own budget only. Raising past it becomes an approval.
- `Track {kind: pod|pr|ci, ref, probe, cap, at_cap}`: registers an outside resource. Pods require a cost cap.
- `Jobs rerun <id>`, and `Adopt <id>` for a parent taking a dead child's work.
- `ListSessions` gains `liveness` (heartbeat age, exit cause) and `jobs`.

**Errors and wakes that say what happened.** A stale id returns its fate: `j12 ended 14:27 (exit 0, 48s) while the engine restarted. output is kept`. A lost job says `lost at 14:21: its engine died … no exit code`. Wakes carry `started`, `fired` and the measured elapsed time, so a wake can't be mistaken for another. Timers use wall-clock due times and never fire early. A duplicate Monitor returns the existing id. Polling a running job more than twice a minute gets "nothing new; you'll get a wake" and no output. A Bash command that detaches (`nohup`, `disown`, trailing `&`) runs as a job instead, unless the agent passes `--detach`.

**A parent sees its children** through its block and `ListSessions`: one line per child, expanded only when it needs the parent (dead, holding money, waiting on Cam).

## 4. survival

- **Ledger:** `<store>/<session>.jobs/ledger.jsonl`, append-only. It records every job's spec, owner, state changes, caps, pid plus start time, and log path, plus a wake outbox. The engine replays it on start.
- **Shell jobs run under a wrapper** (`frog-run`, setsid) that writes the exit code and end time next to the log. They outlive the engine. On restart the engine checks pid plus start time: alive means reattach; exit file present means done (and a wake is queued); neither means `lost`.
- **Watches and timers** persist their schedule (`next_at`, `due_at`) and resume. Their elapsed time is counted from `created_at`.
- **Subagents** can't outlive their engine. On restart they're `lost`, with their partial report kept.
- **Child sessions** already persist. The broker's parent map moves into the ledger so the engine knows its children.
- **Pods, PRs and CI** are probes, so they resume on their own. Their cost is computed from the provider's start time, not from frog's uptime.
- **Undelivered wakes** stay in the outbox until a turn consumes them.
- **Terminal panes** keep their scrollback and cwd. They reopen as "ended at restart · Reopen" (a live PTY that survives restarts is a later step).
- **Orphan, as shown:** dashed red ring, `orphaned · held by <parent>`, burn rate, the cap still counting, and actions Restart owner, Stop, Adopt.

## 5. metrics

Where it's practical, frog computes these from the ledger and shows them in activity:
- time from engine death to someone knowing (target < 60s; today: until the chief checks)
- orphaned spend (target $0 over the cap; today: $10.58/hr, unseen)
- stale-handle errors per day (target 0)
- duplicate polls per job (target < 1)
- untracked detached processes (target 0)
- median wait on Cam, and the oldest open card
- alerts per hour, and how many were dismissed without action (a noise signal)
- early or duplicate wakes (target 0)

## 6. build order (no dates; launches only)

**Before Beat 1 (Oct 30), the floor:**
1. ledger with durable ids plus `frog-run`. Reattach on restart. Stale-handle errors that state the job's fate.
2. wall-clock timers, measured-time wakes, the monitor-timeout fix, and a wake outbox.
3. the background block in context after every turn, compaction and resume.
4. decode `Background*` in FrogKit: inline rows, the restart notice, the live bar.
5. heartbeat liveness: dead vs idle vs waiting in the sidebar, and the dead-session banner.

**Beat 2 (Nov 3):**
6. activity view and the waiting-on-you inbox (ListApprovals becomes the data source).
7. `Track` for pods with caps and at-cap actions. Orphans move up to the parent.
8. notification rules, and the dock badge as the needs-you count.

**Beat 3 (~Nov 17):**
9. menu bar face, pause, extend, rerun and adopt. Detached-command capture.
10. PR and CI probes, persistent panes, and the metrics panel.

## 7. decisions for Cam

1. **what to call it**
   1. "jobs" (recommended): matches the existing tool names, and kinds go in a column
   2. "background": one word everyone already uses, but it's an adjective as a noun
   3. "errands": warm, but new vocabulary
2. **where shell jobs live**
   1. a detached `frog-run` wrapper plus the ledger (recommended): jobs outlive the engine and nothing needs installing
   2. a resident `frogd` supervisor: stronger guarantees, but one more process and launchd setup
   3. the engine only, plus the ledger: simplest, but every engine crash still kills jobs
3. **when an owner dies, its paid resources**
   1. move up to the parent and keep running until the cap, with one alert (recommended)
   2. stop at once
   3. keep running quietly
4. **caps on pods**
   1. required on `Track`, defaulting to 4h and $50 (recommended)
   2. optional, with a warning only
5. **Beat 1 scope**
   1. items 1–5 above (recommended)
   2. items 1–3 only: engine-side, no UI
   3. items 1–8

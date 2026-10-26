# Stale timers

Monitor timers (`Monitor { after_s }`) and polled monitors kept waking the chief of staff long
after what they watched stopped mattering: 15+ stale wakeups overnight, each one a turn, context
and a look from Cam. This doc checks the four suspected causes against the code and the chief's
log, then lists the fixes, smallest first.

## What the chief's log shows

`~/.local/share/frog/sessions/20261022-104528-3288.jsonl`, Oct 25 18:00 to Oct 26 11:30:

- 391 turns. 113 started on a `<wakeup>`. **195 armed a new timer, and 122 of those were not
  wakeup turns** (session messages, Cam's messages). Every turn ended with "set the next
  sweep", while the previous sweep was still pending.
- So timers **stacked**: up to **22 live at once**, 13 live at 11:33 (mon-100 … mon-114), every
  one a 25–30 min "sweep: tree verdict …" with a slightly different note. With N stacked
  1,800 s timers, one fires every 1800/N s. At N=13 that's a wakeup every ~2 min. Between
  11:03 and 11:08, 7 fired.
- 10:32: 19 timers ended `stopped` at once. That was an interrupt (`Op::Interrupt` stops
  everything). Within 3 minutes the stack was rebuilding.
- 2 compactions (10-23, 10-25), both with **0** timers live. 49 `context_pruned` events.

The pathology is "re-arm without knowing a timer is already pending", not "a timer outlives
its condition". One-shot timers can't outlive anything. The model arms another because it
can't see the ones it has.

## The four root causes, verified

| # | Suspected cause | Verdict | Evidence |
|---|---|---|---|
| 1 | No way to cancel a timer | **Half real.** `JobStop {id}` already stops a timer or monitor (`background::run` → `Registry::stop`). But the timer's tool result never says so (the monitor's does), nothing lists what's pending, and an id the model forgot after pruning can't be cancelled. | background.rs:565, :643, :737 |
| 2 | Wakeups carry no context | **Real.** `<wakeup id=mon-87 after_s=1800>note</wakeup>`. Nothing says what the timer is about beyond free text, or that 12 more are pending. Arming says nothing about the others either. | background.rs:562 |
| 3 | Timers re-armed after compaction or restart | **False as stated. Two real neighbours.** Nothing re-arms: the Registry lives in memory and is never rebuilt from the log. Timers "survive compaction" because compaction doesn't touch the Registry (same process), which is correct. What's lost is the model's knowledge: compaction and pruning (49×) drop the `Timer mon-N set` results, so it re-arms. On an engine restart the opposite happens: live timers die silently. The log keeps their `background_started` with no `background_done`, so the app shows them running forever, and the new engine reuses `mon-1…` ids that collide with the old ones. | engine.rs:5679 (compaction), :1370 (resume), background.rs:102 |
| 4 | Monitors in cancelled turns keep firing | **False.** `Op::Interrupt` and `Op::Shutdown` call `stop_all` in the router (engine.rs:579, :641), engine exit stops all too (:940), and `Op::Clear` stops all and drops notices (:2064). A stop also holds parked wakes for the next message (`wake_hold`). The 10:32 mass stop is this path working. | `background_work_stops_when_the_session_ends` |

## Fixes, smallest first

**a. Cancel by id or subject.** `Monitor { cancel: "<id | subject | all>" }` stops matching
timers and monitors and says what it stopped. No new tool (the model already knows Monitor).
Each timer's start message now names `Monitor {cancel}` and `JobStop`. `all` is the one-call
reset for a session that has lost track.

**b. Subjects, replace-on-re-arm, and the pending list.** `Monitor` takes an optional
`subject` (`b300-retry`, `sweep`), normalized to one token (lowercase, `[a-z0-9._-]`, ≤40).
- A new timer or monitor with a subject that's already pending **replaces** the old one: it
  ends with status `replaced`, no notice. Five re-arms of one watch leave one timer, not five.
- The wakeup and monitor-done notices carry it: `<wakeup id=mon-9 subject=sweep after_s=1800>`.
- Arming, and every wakeup, lists the **other** pending watches in one line:
  `Also pending: mon-3 sweep (in 12m), mon-5 b300-retry (in 4m)`. A model that wakes or
  re-arms sees what's already set, with no derivation and no tool call.
- **Cap: 5 pending timers** (subject replacement doesn't count toward it). The 6th is refused
  with the list and the two ways out (re-arm with a subject, or cancel). This is the ≤-5-cards
  rule applied to wakeups. Command monitors keep their own timeout and aren't capped.

**c. Death on turn end: not built.** Timers exist to fire after the turn that set them ends,
so scoping them to it would break every one. The case the brief worried about (a cancelled or
interrupted turn) already kills everything (verdict 4). A regression test pins it:
interrupt → no wakeup.

**d. Compaction and restart.**
- Compaction appends one `Pending background:` block to the summary message: each live timer
  or monitor with its id, subject or label, and the time left. It's state, not a notice. No
  wake, no turn.
- Resume: every `background_started` in the log with no `background_done` gets a durable
  `background_done {status: "lost"}` (the app stops showing it as running). One line is parked
  for the next turn and starts none: `2 timers from before the restart were dropped, not
  re-armed: mon-3 (sweep), mon-7 (b300-retry). Re-arm any that still matter.` Fail toward
  silence. The engine never re-arms on its own, because it can't know the condition still
  holds.
- The resumed Registry's id counter starts past the log's highest `mon-`/`job-`/`task-` id,
  so ids never collide.

**e. App: "Dismiss all" on the pending strip.** One button on the strip above the composer
sends a new `Op::DismissWakes`. The engine drops every parked wake and stops every pending
timer and monitor. Jobs and Tasks are real work, so they keep running. This is the chief's
manual "stale, ignore" ×15, as one click.

## Failure modes

| Failure | Before | After |
|---|---|---|
| Re-arm the same watch every turn | N stacked timers, a wakeup every 1800/N s | with a subject: 1 timer. Without one: the list on every arm and wake, capped at 5 |
| Model forgets ids after pruning or compaction | can't cancel; re-arms | `cancel: all` or `cancel: <subject>`; compaction keeps the pending list |
| Condition went moot | wakes, re-derives, dismisses | one `cancel`, or Cam's one Dismiss all |
| Engine restart with timers live | silently lost; app shows them running; ids collide | `lost` recorded, one line parked, no wake, ids continue |
| Interrupt or cancelled turn | all stopped (already) | unchanged, now tested |
| Cap reached by real, distinct needs | — | refused with the list; use subjects or a single sweep timer (the cap is a constant, easy to raise) |
| Dismiss all mid-turn | — | parked wakes dropped, watches stopped; the running turn is untouched |

**Principle.** A wakeup costs a turn and maybe Cam's attention, the same as an approval card.
Cam's rule for cards is about five a day, so wakeups get the same budget: replace instead of
stack, cap what can be pending, and when unsure, drop and say so once instead of waking.

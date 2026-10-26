# App hangs, duplicates, CPU and the rail: 2026-10-22 → 25

A session run from outside the app (Claude Code, helping the chief), on Cam's machine against
the installed Frog.app. What broke, why, what changed, and what's still open. Everything below
is on `main`.

## Bugs

| Symptom | Cause | Fix |
|---|---|---|
| Bash hangs forever, engine at 100% CPU, Stop does nothing | `tools::bash::adapt_swiftpm` never advanced on `)` `}` or a lone `\|`/`&`: any command with `grep -E 'a (b\|c)'` spun before bash spawned. Sync loop, no await point, so cancellation can't reach it. Not git or worktrees. | `14e69df` (#74), with regression tests. |
| Every turn shown 2–3+ times, growing as it streamed | The #104 merge kept main's whole-turn `TurnView.body`, so each transcript row (head, each segment, tail) drew the entire turn. The session log was fine. | `bcdfa04`: `body` switches on `part` again; `head` keeps the wake/session-message openers. |
| (Latent) a re-sent `turn_started` appended a copy | The matcher only merged into an unnumbered local turn. | `cc576fe`, test in `ReopenTests`. |

## CPU (profiled with `sample` and Instruments' SwiftUI template)

| Hot spot | Cause | Fix |
|---|---|---|
| ~63% of main: `TimelineRail` → `Chapter.of` | `chapters` was computed and read per chapter in the draw loop: chapters × turns string scans per redraw. | `a719929`, then memoized (`Chapter.cached`). |
| ~1 core in a child process | The session watcher asked `Library.refresh()` every second while anything streamed; each `frog --sessions --all` costs ~1s CPU over ~1,200 sessions. | `f7fafd7`: at most one per 3s; unchanged lists aren't written. |
| SwiftUI churn: 1.09M graph updates per 6s | Every token a separate write to `Conversation.turns`; `status` rewritten unchanged (not Equatable); `progress = nil` on every delta. An `@Observable` setter invalidates readers whatever the value. | `8c93000`: live deltas batched per 1/30s (other events flush first); no-op writes skipped. → 397k. |
| Smaller | `sessionChanges` refolded every turn per read; hidden 30fps frogs in every finished message; git/sessions rewritten unchanged. | `f7fafd7`, `3d2498d`. |

Result: ~100% → roughly 15–55% while sessions stream (noisy; depends on load).

**Still open:** most remaining updates are Liquid Glass (`PlatformGlassInteractionState`,
~1.4k/s). Suspect: the activity pill, a glass capsule around three animations (30fps frog,
60fps `WorkingLine`, elapsed timer). Unconfirmed; next step is an A/B with the playful frog off
and the sweep removed, counted properly (the export dedups strings by `ref`, so `grep -c` lies).

## Dock

The spinner ring (full icon redrawn at 12fps whenever a turn ran) is gone. The tile is the
plain icon; while any session is `.waiting` on Cam (approval, question), the frog comes alive,
head tilted, at 30fps, driven by `Library.live`. Cam's call: frog is nearly always working, so
the Dock is for attention only.

## Rail

- One vocabulary: hairline, soft thumb over the turns on screen, a dot per chapter (solid
  prompt, hollow autonomous run, gap at a compaction), color only for failed/stopped/running.
- Laid out by chapter (each gets an equal slot), height by chapter count, capped at 360pt;
  crowded dots thin to landmarks; the current chapter always shows.
- Only Cam's own messages start prompt chapters; session messages, wakeups and `<resumed…>`
  belong to the stretch they land in.
- Named chapters (`0da1b24`): heuristic names from the prompt's first clause, shown in the
  gutter right of the 820pt column when it's ≥90pt, and on hover.

## Next

- **Model-written chapter titles** (asked for, not started): the engine titles a chapter with a
  cheap model when the next prompt closes it, logs a `chapter_titled {turn, title}` event, and
  the app prefers it over the heuristic. There is no general "title this text" helper today
  (`title.rs` is the `SetTitle` tool and a fallback cleaner).
- Glass churn above.
- `TranscriptSwitchBenchmarkTests/testScrollUpFillsOlderRowsInOrder` is flaky on plain `main`
  (2 of 3 failed).
- Remaining ideas from the session: Dock-menu quick approve, a hop on done and a droop on error;
  the frog reacting to events rather than a timer; per-chapter cost heat on the rail; a peek
  card while scrubbing.

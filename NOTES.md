# stale-timers — notes

Branch frog/stale-timers, base 4f246b3 (main). Commit per piece (`git commit -s`), never push.
Edit tool only for Rust/Swift source. Targets: CARGO_TARGET_DIR=/private/tmp/tm-target,
-derivedDataPath /private/tmp/tm-dd; delete both at the end (disk is tight).

## Brief
Monitor/Timer wakeups keep firing after their condition went moot (chief: B300 retry timer,
15+ stale wakeups overnight). Root-cause candidates: (1) no cancel/stale API, (2) wakeups carry
no context, (3) timers re-armed after compaction/restart, (4) monitors in cancelled turns keep
firing. Design doc first (docs/design/timers.md), then fixes a–e smallest first.

## Findings (chief log 20261022-104528-3288, Oct 25 18:00 → Oct 26 11:30)
391 turns, 113 wakeup turns; 195 armed a timer, 122 of those NOT wakeup turns → timers stacked,
up to 22 live (13 at 11:33), one firing every 1800/N s. Compactions had 0 live timers; 49 prunes.
Verdicts: (1) half — JobStop already stopped timers, undiscoverable; (2) real; (3) false as stated
(nothing re-arms; Registry is in-memory) — real neighbours: compaction/prune forget, restart loses
silently + id collisions; (4) false — Interrupt/Shutdown/Clear stop_all.

## Progress
- e1aa8e7 checkpoint 0 · 7994fdb design (docs/design/timers.md)
- 81b9729 a: Monitor {cancel: id|all}
- 381751d b: subject (replace on re-arm, subject= in notices, "Also pending" on arm+wake, cap 5 timers)
- 17433cb c: not built by design (timers must outlive their turn); regression test interrupt → no wake
- 3c01139 d: compaction keeps "Pending background" block; resume → `lost` + one parked line, ids continue
- b4f6fec e: Op::DismissWakes + strip "Dismiss all"
Suites: engine 478/1 (a_replys_read_only_calls_run_concurrently — timing flake, passes alone);
app 341/1 skipping TranscriptSwitchBenchmark (TranscriptStreamBenchmark anchoring, unrelated).
Target dirs deleted.

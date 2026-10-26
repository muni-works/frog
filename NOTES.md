# stale-timers — notes

Branch frog/stale-timers, base 4f246b3 (main). Commit per piece (`git commit -s`), never push.
Edit tool only for Rust/Swift source. Targets: CARGO_TARGET_DIR=/private/tmp/tm-target,
-derivedDataPath /private/tmp/tm-dd; delete both at the end (disk is tight).

## Brief
Monitor/Timer wakeups keep firing after their condition went moot (chief: B300 retry timer,
15+ stale wakeups overnight). Root-cause candidates: (1) no cancel/stale API, (2) wakeups carry
no context, (3) timers re-armed after compaction/restart, (4) monitors in cancelled turns keep
firing. Design doc first (docs/design/timers.md), then fixes a–e smallest first.

## Progress
- checkpoint 0

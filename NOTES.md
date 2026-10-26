# ci-green — notes

Branch frog/ci-green, base a3f1f8f (main). Commit per fix (`git commit -s`), push + PR to main
(PR #108 Beat 1 waits on green CI). Targets: CARGO_TARGET_DIR=/private/tmp/cig-target,
-derivedDataPath /private/tmp/cig-dd; delete both at the end.

## Brief (CI run 40375001059 on bd211fd)
1. macos-app: GitIndex.swift:342:43 "failed to produce diagnostic" — split the expression.
2. both: bash.rs timeout_still_ends_a_stuck_command — machine-wide `pgrep -f "sleep 30"`.
3. ubuntu: engine.rs auto_mode_writes_its_own_fresh_temp_scratch_without_a_card — /private/tmp.

## Progress
- checkpoint 0

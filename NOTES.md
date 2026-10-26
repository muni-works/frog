# ci-green — notes

Branch frog/ci-green, base a3f1f8f (main). Commit per fix (`git commit -s`), push + PR to main
(PR #108 Beat 1 waits on green CI). Targets: CARGO_TARGET_DIR=/private/tmp/cig-target,
-derivedDataPath /private/tmp/cig-dd; delete both at the end.

## Brief (CI run 40375001059 on bd211fd)
1. macos-app: GitIndex.swift:342:43 "failed to produce diagnostic" — split the expression.
2. both: bash.rs timeout_still_ends_a_stuck_command — machine-wide `pgrep -f "sleep 30"`.
3. ubuntu: engine.rs auto_mode_writes_its_own_fresh_temp_scratch_without_a_card — /private/tmp.

## Progress
- 5ac067e checkpoint 0 · 5ed1f59 GitIndex.swift: local `created` used in its own initializer
  (self-shadowing → CI Xcode "failed to produce diagnostic"); renamed to madeAt, Self.created,
  typed intermediates.
- da298f3 bash tests: sleeper() records the child's own pid in ws/pid; sleeper_gone() polls that
  exact pid (zombie = gone), replacing machine-wide `pgrep -f "sleep N"` in 4 tests.
- 0b0e6f2 engine scratch test: std::env::temp_dir() (the rules key on it; /private/tmp is
  macOS-only).
- d207539 bash tests: until_sleeping() polls the pid file while polling run — the 300ms fixed
  sleeps raced the spawn (ws/pid missing → panic). Found by the local run itself.
- 9eb7538 engine scratch test: project rooted AT the temp dir made scratch in-project, never
  asked. Project now in its own dir under temp_dir (the case the rule exists for).
- Verified locally: 5 targeted tests green (2 runs), `** BUILD SUCCEEDED **` for the macOS app
  (xcodegen + xcodebuild, deleted). Decoy-sleep stress run was denied by the user.
- Pushed frog/ci-green → PR #109 (ecto/frog, base main). Targets /private/tmp/{cig-target,cig-dd}
  deleted.

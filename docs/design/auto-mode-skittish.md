# auto mode asks too often — the data (2026-10-23)

Source: today's session logs (`~/.local/share/frog/sessions/20261023-*.jsonl`, 16 sessions),
1324 `permission_decision` events, replayed the way `examples/replay_asks.rs` replays #72's set.

## Where every decision went (before)

| Layer / outcome | Count | Note |
|---|---|---|
| sandbox allow | 649 | sandboxed commands run free |
| rule allow (read-only parser) | 414 | |
| session allow (earlier this session / prefix) | 84 | 3 prefix |
| classifier allow | 0 | never once said allow |
| **ask** | **49** | what the user saw |
| unmatched/id-less rows | 87 | bookkeeping, not asks |

Plus 88 user-resolved approval cards (`allow`/`allow_always`/`deny`) across the day's sessions.

## The 49 asks, classified

| Category | Count | Examples |
|---|---|---|
| **SKITTISH — builds/tests writing their OWN /private/tmp dirs** | 42 | `xcodebuild test -derivedDataPath /private/tmp/…` (×22), `CARGO_TARGET_DIR=/private/tmp/… cargo test` (×15), `xcodebuild build … /private/tmp/…` (×5) |
| **SKITTISH — read-only commands the parser missed** | 4 | `ps -eo … \| grep … \| cut … \| head`, `sample <pid> 1 -mayDie …`, `ls /Applications/Xcode.app/...`, `grep -rln '…' worktrees` |
| NECESSARY — leaves the sandbox for real work | 2 | running a test binary with a timeout harness under /private/tmp, killing hung xctest PIDs (`kill 58930 …`) |
| NECESSARY — project edits via Bash | 1 | `sed -i ''` inside the worktree (Auto mode lets Edit do this, but sed isn't parsed) |

No ask in the sample was necessary for credential protection or outside-project writes:
the 29 "leaves the sandbox" asks were almost all builds/tests that only touch `/private/tmp/<task>-*`.

## Top asked command patterns

| # | Pattern | Count |
|---|---|---|
| 1 | `cd <worktree>/apps/macos && xcodebuild test …` | 16 |
| 2 | `export CARGO_TARGET_DIR=/private/tmp/<task>-target && cargo test …` | 5 |
| 3 | `cd <worktree> && CARGO_TARGET_DIR=/private/tmp/… cargo test` | 5 |
| 4 | `xcodebuild build/test … -derivedDataPath /private/tmp/<task>-dd` | 12 |
| 5 | `xcodebuild test-without-building …` | 3 |
| 6 | `cargo test -p frog-engine --lib <filter>` (target in /private/tmp) | 9 |
| 7 | read-only pipelines: `ps | grep | cut | head`, `sample`, `ls` | 4 |
| 8 | `xcodegen generate` (writes project.yml from project.json, in-tree) | 3 |
| 9 | `sed -i` in-tree edits | 2 |
| 10 | `cat > /private/tmp/<task>-…` heredoc writes to its own tmp | 2 |

## Why the classifier said ask (12 of the 49)

Every classifier ask was the same shape: `xcodebuild test` / `cargo test` "may write outside
the project" — because the derived-data / target path is under `/private/tmp`, which the
classifier (correctly per its prompt) reads as "outside the project". The classifier never
approved anything in the whole sample; every allowed call came from layer 1/2/sandbox.

## The fix (step 2)

1. **Provenance-aware writes**: writes into paths this session created (the `self.created`
   set from #72's approval cards) or into the session's own `/private/tmp/<task>-*` dirs
   count as in-project. Anything else outside stays asking.
2. **Classifier prompt**: routine builds/tests with `-derivedDataPath`/`CARGO_TARGET_DIR`
   under `/private/tmp` or inside the project are named as routine; credentials, pushes,
   destructive and outside-project writes stay always-ask.
3. **Read-only parser**: add `ps`, `sample`, `xcrun simctl list`-style lookups, `xcodegen --help`-style
   reads and other misses found above.
4. **Nothing in `auto::hard_rule` changes**: sudo, pushes, publishes, destructive deletes
   outside the project, credential paths — untouched.

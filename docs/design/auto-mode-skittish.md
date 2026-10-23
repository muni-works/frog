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

(First pass, from the truncated `item_started` args of the 16 sessions present at the
time. The step-3 replay below uses full inputs on more sessions and is the one to trust.)

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

1. **Provenance layer (auto mode only)**, `engine::permit` after the prefix layer. A Bash
   command runs without the classifier when *all* hold: no credential mention, no hard rule,
   `approval::routine` (every segment is a known build/test step such as `cargo
   build|test|check|clippy|fmt|run`, `xcodebuild build|test|test-without-building`,
   `swift build|test`, `xcodegen generate`, `npm test|run`, a plain file op, in-project
   `sed -i` whose script passes the read-only sed checks, or a parser-proven read; no `$(`,
   backticks, heredocs, newlines or URLs), and `approval::own_scope` (every path it names
   is in the project, or created by this session, or *fresh* under the temp dir; `rm`/`mv`/
   `dd`/`truncate` need provenance everywhere, the project included). Write/Edit outside the
   checkout passes only into session-created paths or fresh temp files.
2. **Classifier prompt** names CARGO_TARGET_DIR / -derivedDataPath / target dirs under
   `/private/tmp` or in the project as routine. The always-ask list is unchanged.
3. **Read-only parser**: `ps`, `pgrep`, `sample` (pids and flags only, no `-file`),
   `xcrun xcresulttool get`, `xcrun simctl list`; `grep`/`rg` now accept absolute paths,
   the same as `cat`/`head` (credential paths are still rejected first).
4. **`auto::hard_rule` is byte-for-byte unchanged.** An `rm -rf /abs/path` still asks even when
   this session created the path. Provenance never overrides a hard rule.

## Result (step 3)

`examples/replay_scope.rs` replays every call that asked: today's 134 (deduped per call,
full `tool_use` input, session cwd as root) plus #72's 116. It drops the 12 that main's
layer 1 already allows, so 238 remain. Provenance is simulated: a temp dir belongs to the
session that first named it, as of calls before this one.

| Category | Before | After |
|---|---|---|
| SKITTISH: build/test writing own dirs | 79 | 10 |
| SKITTISH: read-only the parser missed | 4 | 0 |
| SKITTISH: own tmp write (Write/Edit) | 2 | 0 |
| NECESSARY: outside project | 50 | 50 |
| NECESSARY: destructive/system | 14 | 14 |
| NECESSARY: credentials | 6 | 6 |
| GRAY: unknown program (deploys, `git fetch`/`ls-remote`/`stash`, loops, heredocs, own test binaries) | 43 | 43 |
| MODE: in-project edits in non-auto sessions (asks by design) | 22 | 22 |
| OTHER: non-shell tools (MCP, Screenshot, Terminal) | 18 | 18 |
| **Total** | **238** | **163 (-31%)** |

- Skittish asks: **85 → 10 (-88%)**. Skittish plus gray (everything a rule could touch): 128 → 53 (-59%).
  The total misses -50% because 70 asks are necessary and must stay, and 40 come from
  non-auto modes or non-shell tools.
- **Newly allowed: 75, all skittish. Zero NECESSARY or GRAY asks changed category.** None of
  the user's denials (3 today, those in #72's set) would now run unasked.
- The 10 left are builds into a `/private/tmp` dir another session made (`interrupt2-target`).
  By the rule, someone else's scratch still asks.

## What got weaker

1. Auto mode only: routine build/test/file-op commands in the project or the session's own
   scratch (session-created, or fresh under the temp dir) skip the classifier, unsandboxed
   included. `cargo test` / `xcodebuild test` run project code, the same as before an
   "allow".
2. Auto mode only: Write/Edit into session-created paths or fresh temp files.
3. All modes, layer 1: `grep`/`rg` read absolute paths (as `cat` already did), and `ps`/
   `pgrep`/`sample`/`xcrun xcresulttool get`/`xcrun simctl list` count as read-only.

Unchanged: `hard_rule` (sudo, push, publish, history rewrites, rm outside the project,
system settings, kill), credential detection, other checkouts, the sandbox.

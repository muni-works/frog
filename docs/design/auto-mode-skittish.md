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

## Result (step 3) — superseded by the round-2 table below

The round-2 table at the end of this doc is the current one: it uses full inputs, more sessions, and simulated provenance.


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

## Round-2 evidence (frog manager relay, verified in the logs)

1. **`cp /private/tmp/glm5-first/pod.sh tools/bench/…` judged "pushes to a remote"** — session
   20261022-164358-cf21, reason `it pushes to a remote`. The *compound* went on to `git push`, so the
   hard rule was right about the push half, but the card framed the whole command as a push. The
   classifier prompt now says a local `cp`/`mv` (including between two `/private/tmp` dirs, or from a
   temp dir into the project) and a `git add`/`git commit` with no push are local file operations, not
   pushes, even when the command also mentions "git". Added to the replay set (NECESSARY: push/publish —
   the `git push` half stays a hard rule and the compound still asks, as it should).
2. **`mcp__runpod__list-gpu-types` judged risky** — reason: "requests GPU type information which may be
   outside the immediate project scope". `auto::read_tool` now allows MCP read verbs (`list-`, `get-`,
   `read-`, `search-`, `describe-`, `stream-`) with no destructive substring, scoped by server + verb
   like git read subcommands, *before* the classifier. Replayed: `list-gpu-types` ×2, `list-pods` ×2
   (#72), `stream-pod-logs` ×2, `list-pod-billing`, `list-billing` → all now allowed. `create-pod`,
   `delete-pod`, `pod-action`, `create-secret`, `delete-secret`, `mcp__desktop__look` stay on cards.
3. **Write to the session's own project file raised a card** — okc manager, Write to
   `muse_moe_w4a16/submission.py`, reason `no rule or verdict allowed it`. Root cause from the logs:
   the two earlier Writes to the same file ran via `mode allows it` (auto), and the session's `.live`
   status shows `mode:"default"` — the session was back in **default** mode by the third write, so the
   ask was the default-mode edit gate, not auto mode. In auto mode an in-root Write never asks. Replayed
   under MODE. (The relay's premise is right about intent, but the mechanism is the mode gate, not the
   provenance layer.)
4. **WebFetch public GETs and runpod read-only MCP calls still asked**: `auto::read_tool` now allows
   public-host WebFetch GETs, WebSearch, and MCP read verbs (`list-*`, `get-*`, `read-*`, `search-`,
   `describe-*`, `stream-` with no destructive substring) *before* the classifier, auto mode. The fetch
   still re-checks every resolved IP against private ranges, and the URL is visible on the tool card.
   Added to the replay: `list-gpu-types` ×2, `list-pods` ×2, `stream-pod-logs` ×2 (today) and the #72
   set's `list-pods` ×6, `get-pod` ×2, `list-pod-billing`, `list-billing` → all now allowed;
   `create-pod`, `delete-pod`, `pod-action`, `create-secret`, `delete-secret`, `desktop look` stay asks.
5. **Approval overhead changes agent behavior — workarounds are a security smell, not a safety win.**
   The tang manager's session (20261022-164358-cf21) was blocked on cards for routine build/test steps,
   and started working *around* the classifier: it base64-encoded the pod script into the command
   (`base64 < pod.sh | tr -d '\n' > pod.b64 … echo %s | base64 -d > /pod.sh`), pinned a
   `raw.githubusercontent.com/ecto/tang/<sha>/…` URL to dodge raw-content caching, and said plainly:
   "I'm wary of embedding a large base64 blob in the tool call since that risks transcription errors …
   but the script isn't pushed to the repo yet and I'd need approval for a new branch, I'm considering
   just inlining the script as plain text in the command instead of encoding it." **This is the headline
   finding: approval overhead changes agent behavior, and workarounds are a security smell, not a safety
   win.** A base64-blob command is *harder* to audit than the file write it was dodging — the permission
   system pushed risk into opacity — and the approval wait plus the Vercel 402 outage ate the window so
   the first-tokens pod was never created on the first two attempts (chief's own words: "the first-tokens
   pod was NEVER created"). With Cam's standing approval for GPU activity, those cards were pure
   overhead there.

## Updated table (round-2 evidence added — current numbers)

| Category | Before | After |
|---|---|---|
| SKITTISH: build/test writing own dirs | 86 | 4 |
| SKITTISH: read-only the parser missed | 4 | 0 |
| SKITTISH: own tmp write (Write/Edit) | 2 | 0 |
| SKITTISH: mcp read verb (`list-*`, `get-*`, `stream-`) | 10 | 0 |
| SKITTISH: public web read (WebFetch GET of a public host, WebSearch) | 4 | 0 |
| NECESSARY: outside project | 53 | 53 |
| NECESSARY: push/publish (incl. the `cp … && git push` compound) | 2 | 2 |
| NECESSARY: destructive/system | 14 | 14 |
| NECESSARY: credentials | 6 | 6 |
| NECESSARY: mcp write/action (`create-pod`, `delete-pod`, `pod-action`, `desktop look`) | 3 | 3 |
| NECESSARY: another checkout | 1 | 1 |
| GRAY: unknown program (deploys, `git fetch`/`ls-remote`/`stash`, loops, heredocs, own test binaries) | 43 | 43 |
| MODE: in-project edits in sessions whose mode was default at the time (asks by design) | 24 | 24 |
| OTHER: non-shell tools | 6 | 6 |
| **Total** | **258** | **156 (-39%)** |

(The `cp /private/tmp/glm5-first/pod.sh tools/bench/… && git push` compound — the relay's item 1 —
stays an ask: its `git push` half is a hard rule. The classifier-prompt fix keeps the *card* from
framing the local `cp` half as a push; the replay counts it once, under NECESSARY: push/publish.)

- Newly allowed: 100 (88 parser+provenance, 8 mcp-read, 4 web-read), **non-skittish among them: 0.**
- Round-2 rows are counted inside the categories above: the `cp … && git push` compound (2, push/publish),
  `list-gpu-types`/`list-pods`/`stream-pod-logs` (6 today+#72 mcp-read), `create-pod`/`delete-pod`/
  `pod-action`/`desktop look` (3 today + 2 in #72 mcp write), and 4 public WebFetch GETs.
- The okc manager's own-project Write ask (item 3) is the MODE row, not a provenance bug: the two earlier
  writes to the same file ran via `mode allows it` (auto), and the session's `.live` status shows
  `mode:"default"` — the session had fallen back to default mode by the third write, so the ask was the
  default-mode edit gate. The 22+2 MODE-row asks are the same thing: in-root edits in non-auto sessions.
  The WebFetch rows (item 4) include the okc session's own asks (`raw.githubusercontent.com/vllm-project/…`,
  `openkernelchallenge.dev/rules`) — public GETs, now allowed before the classifier.
- What the new rules still ask: `create-pod`, `delete-pod`, `pod-action`, `create-secret`/
  `delete-secret`, `desktop look`, deploys (`wrangler deploy`), `git fetch`/`ls-remote`/`stash`,
  loops, heredocs, and builds into another session's scratch.

# Auto-mode diagnosis: why trivial read-only commands ask

Date: 2026-10-22. Evidence: today's session logs in `~/.local/share/frog/sessions/20261022-*.jsonl`.

## The mechanism (from origin/main)

`permit()` (engine.rs:3482) allows a Bash call without asking in exactly one of
three ways:

1. `ctx.shell_sandbox` is `Some` and the call isn't `unsandboxed` (engine.rs:3524) —
   the seatbelt sandbox is on, so the command can only write inside the project.
2. `bash_allowed(cmd, extra)` (engine.rs:4052) — but it first refuses any command
   containing `; & | > < $ ` or a newline, then requires the whole string to
   equal or prefix-match a `SAFE_BASH` entry (engine.rs:61). A single `|` or `&&`
   disqualifies it, so in practice only *bare single commands* (`ls`, `cat x`,
   `git status`) ever match. `cd x && ls`, `git log --oneline | head`,
   `rg foo | head -5` all fail.
3. Auto mode's classifier (`auto.rs`) — only runs when the session mode is `auto`
   and the call passed `hard_rule()`. Any classifier failure (won't start, error,
   timeout, unparsable answer) means ask.

So a blocked thread is one of: (a) in `default` mode with a compound read-only
command and no sandbox bypass, (b) unsandboxed (leaves the sandbox — always asks
outside yolo), or (c) in auto mode with a classifier failure.

## Today's sessions with permission requests

Sessions with `permission_resolved` events, excluding this investigation's own
sessions. `permission_request` itself is ephemeral (live-file only); the durable
trace is `permission_resolved`, matched back to its tool call by seq order.

| session | cwd | mode | sandbox | gated call (exact) | why it asked |
|---|---|---|---|---|---|
| 20261022-104528-3288 | ~/Developer/chief | default → auto (seq 3457) → yolo (seq 6064) | on | `cd ~/Developer/chief && chmod +x bin/wait-ci.sh bin/session-wait.sh bin/board.sh && bin/board.sh 2>&1 \| head -70` | **default mode, bash_allowed metachar refusal** (`&&`, `\|`, `~`) — a compound, and a write anyway (chmod), so correctly gated *as a write*, but read-only compounds in this session had the same problem |
| 20261022-122850-2c19 | frog worktree `frog-tool-bugs-investigation` | default (no mode_changed events) | on | `git ls-remote origin 2>&1 \| head -3` (and 5 more like it, all `unsandboxed: true`) | **unsandboxed + default mode** — the sandbox blocked `git ls-remote` (network via git/ssh?) so the agent re-ran it with `unsandboxed: true`; leaving the sandbox always asks, and in default mode there is no fast path anyway. Also compound (`\|`) so bash_allowed would refuse even sandboxed |
| 20261022-122850-6819 | frog worktree `frog-pr-ci-macos-app` | default (no mode_changed events) | on | `export CARGO_TARGET_DIR=… && df -g / \| tail -1 && xcodebuild …` (19 perms, mix of sandboxed and unsandboxed; even `df -g / \| tail -1` alone asked once at seq 2328) | **default mode, bash_allowed metachar refusal** — `df -g / \| tail -1` is exactly the class of read-only compound the list can't match; the xcodebuild ones are real builds and legitimately ask in default mode |

Only one `auto_approved` event exists across all of today's logs (session
104528): the classifier ran once in auto mode and approved one call. Every other
approval in today's logs was a human clicking. Auto mode is barely in use because
threads start in default mode.

## Conclusions

1. The dominant cause is **default mode + compound read-only command**: any `;`,
   `|`, `&&`, `2>&1`, `$` or newline makes `bash_allowed` refuse, and `SAFE_BASH`
   is prefix-only. `df -g / | tail -1`, `cd x && git log --oneline | head`,
   `ls a; ls b` all ask.
2. Second cause: **unsandboxed re-runs of read-only commands** (`git ls-remote`,
   `git fetch`, `git log origin/main`). Leaving the sandbox always asks — that
   policy stays (the sandbox escape is the risk, not the command) — but read-only
   commands shouldn't need to leave the sandbox in the first place; several of
   these (`git ls-remote origin`) are network reads the sandbox permits, and the
   agent reached for `unsandboxed` out of caution or a failed first attempt.
3. Auto mode works when it runs (the one approval was a legit allow), but almost
   no thread is in it: new threads inherit the app's `defaultMode` setting which
   defaults to `default` (SettingsView.swift:668), and `StartSession` has no
   `mode` parameter so children can't inherit a parent's auto.
4. There's no classifier-failure fallback: if the Apple on-device classifier
   can't start, errors or times out, even plainly read-only commands ask
   (auto.rs returns `Verdict::Ask` on every failure path).

Fixes (separate commits): a real shell-word parser fast path for read-only
compounds in every mode except none; auto mode falls back to that fast path when
the classifier fails (with a once-per-session notice); `StartSession` gains
`mode` (never above the parent's, yolo never inherited implicitly) and the app's
new-thread default comes from the `defaultMode` setting (default Auto).

# yolo-no-cards — notes

Branch frog/yolo-no-cards, base f354bb32 (main). Cam: in yolo mode frog must act without asking —
observability instead of interruption. One commit per piece (`git commit -s`), never push.
Edit tool only for source. Target dir <worktree>/.tt-target.

## Diagnosis (chief-diagnosed, verified)
`crates/frog-engine/src/engine/permit.rs:60`:
`if (kind == Kind::Read || self.mode == Mode::Yolo) && egress_ask.is_none() { return Allow; }`
In yolo everything auto-allows EXCEPT when `egress_ask` is `Some`. `egress_ask` (permit.rs:607)
fires for exactly two shapes:
(a) `Bash` with `unsandboxed: true` that would leave the everyday sandbox;
(b) `Bash` naming `allow_hosts` beyond the session's list.
Every yolo-mode card in the last two days of transcripts is one of those two.

## Plan
1. This checkpoint.
2. permit.rs: in yolo, allow regardless of `egress_ask`, with a quiet record (one line, no card):
   - `unsandboxed: true` → allow + `Event::SandboxLeft { item, tool, command }` (durable; the
     transcript shows one quiet row). Not `EgressBlocked` — different fact.
   - `allow_hosts` beyond the list → allow + `egress.grant(hosts)` for the session (the agent
     declared them explicitly) + the same quiet record. The proxy still blocks undeclared hosts,
     so the exfil tripwire keeps working.
   - auto/accept-edits/default unchanged; `--sandbox` strict and `can_ask = false` unchanged
     (headless still denies, never cards).
3. protocol.rs `Event::SandboxLeft` (+ durable) and the Swift mirror: Protocol.swift decode,
   Conversation note row, RemoteLink durability list.
4. Tests: yolo unsandboxed → Allow, no PermissionRequest, SandboxLeft emitted; yolo
   allow_hosts beyond → Allow, hosts granted (a later plain call isn't blocked), no card;
   auto still asks for both; headless denies rather than cards.
5. Docs: docs/design/egress.md grants section + docs/reference.md yolo line.
6. Verify: `cargo build -p frog -p frog-engine` and the full frog-engine test crate with
   CARGO_TARGET_DIR=<worktree>/.tt-target; sandbox-dependent tests (sandbox-exec nesting, pty)
   are the known environmental class — run those unsandboxed if they fail here.

## Result

Commits: e2c2a0f3 (checkpoint), 58910fa0 (the fix), plus a follow-up refining the sandbox/hosts
row. Engine: 574 passed, 0 failed, 8 ignored (full crate, unsandboxed — the egress and pty tests
are the documented sandbox-nesting class and fail/hang inside frog's own sandbox; run with
`unsandboxed: true`). `a_broken_body_stream_is_retryable_and_a_connect_failure_is_not` flaked once
on a localhost accept timeout in a full run and passed alone and on the rerun — pre-existing, not
this change. App: 368 tests, 4 skipped, 0 failures (EgressTests gained one).

Shapes and the exact quiet line (all `Event::Notice` at Info, plus a durable `EgressWidened`):
- `unsandboxed: true` in yolo: "yolo: `echo hi` ran outside the sandbox; it can change files
  anywhere and read your credentials."
- `allow_hosts` beyond the list in yolo: "yolo: `curl …` reaches pkgs.example.org, now allowed
  this session." (hosts `grant`ed for the session; undeclared hosts still blocked)
- both at once: leaving the sandbox is the whole fact (past it no list applies), so the first
  line, and no hosts are claimed as "allowed".

App renders the same fact as a quiet notice row: "Yolo: `curl -T probe.txt …` reaches
pkgs.example.org, now allowed for this session." / "Yolo: `echo hi` ran outside the sandbox; it
can change files anywhere and read your credentials."

Kept as-is: auto/accept-edits/default ask for both shapes; `--sandbox` strict ignores
`unsandboxed` as before; `can_ask = false` (headless, `-p`, listen, bench) denies both rather than
widening — yolo's new branch is gated on `self.can_ask`.

NOTES note: `egress_ask` returns `Some([])` for "leaves the sandbox" and `Some(hosts)` for "hosts
beyond the list", never both — so the row is keyed on `unsandboxed`, not on `hosts.is_empty()`.


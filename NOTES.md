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
(filled in at the end)

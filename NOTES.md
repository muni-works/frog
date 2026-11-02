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

---

# chief-approvals — notes

Branch frog/chief-approvals, base b23479fd (origin/main). Cam: the chief of staff can approve or
deny ANY pending card in a session it started, and egress asks route to the chief as a delegable
class. Why: 90 yolo egress cards in two days all went to Cam because egress asks were excluded
from delegation. One commit per unit (`git commit -s`), never push. Edit tool only for source.

## Diagnosis (chief's brief, verified in source)
- `permit.rs:394`: `delegate_flagged` is called only `if layer == "second-pass"`. An egress ask
  (yolo/unsandboxed/allow_hosts card) never reaches auto's judge at all in auto mode? No — in
  auto, `egress_ask.is_some()` skips provenance and the auto branch (permit.rs:364 gates on
  `egress_ask.is_none()`), so the egress card goes straight to the user, bypassing the chief.
- `delegation.rs soft_class` has no egress shape; `config.rs grant::ALL` has no egress constant.
- `SessionBroker.resolveDelegated` refuses any approval not in its `delegated` map ("No
  delegated approval … is waiting"), so a card that merely sits PENDING in a child can't be
  decided by the chief that started it.

## Plan
1. This checkpoint.
2. Engine: `grant::EGRESS` = "egress-widen" in the vocabulary + `ALL`; `soft_class` returns it
   for the `egress_ask` shape (hosts beyond the list and/or leaving the sandbox); permit.rs
   routes egress-flagged auto cards to `delegate_flagged` too (layer "egress"). Hard classes,
   classifier outages (layer "classifier"/"fallback") and `can_ask = false` unchanged — never
   delegable always cards Cam.
3. Broker: `resolveDelegated` falls back to the PENDING card list (`approvals()`) when the id
   isn't in `delegated`: found → forward the decision to that session's asker as
   `Op::Permission` via `conv.answer`. Authority: only a chief named in `[delegation]` (or the
   session's parent) may answer an unrouted card; anyone else gets the refusal. Same
   `delegated:chief` audit shape in the reply copy.
4. Docs: delegation.md — egress-widen is chief-delegable; the chief may answer a pending card
   directly (authority rule).
5. Tests: engine (a) egress ask routes to chief when granted, cards when not; (b)
   never-delegable still cards with the grant; (c) is broker-side; (d) classifier outage cards.
   Broker: (c) chief accepts a pending-unrouted approval, others refused.
6. Verify: `cargo build -p frog -p frog-engine`, full `cargo test -p frog-engine` with
   CARGO_TARGET_DIR=<worktree>/.tt-target; app tests via xcodebuild test if the app builds
   (PRODUCT_BUNDLE_IDENTIFIER=toys.frog.testhost, FROG_PREBUILT_DIR=/private/tmp/be-prebuilt2,
   derived data /private/tmp/ca-dd).


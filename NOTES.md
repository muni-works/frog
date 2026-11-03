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

## Result

Commits: 323e67cd (checkpoint), 50a1e5a9 (engine), 24cec2d0 (engine tests), 1283299d (broker),
409670ea + 02c7aede (docs).

Engine: `grant::EGRESS` = "egress-widen" in `grant::ALL`; `delegation::soft_egress` returns it
for either egress shape; `delegate_flagged` checks `soft_egress` before `soft_class`, so the
chief's `DelegateApproval` carries `class: "egress-widen"`. permit.rs routes an auto-mode egress
ask to the chief before the card (hosts granted on approval exactly as an answered card does).

Two safety holes the predecessor's half-done edit had, both closed here:
- an egress ask skips `auto_judge`, so `hard_class` wasn't consulted: `rm -rf ~/Documents
  {allow_hosts:[…]}` would have routed to the chief. It's checked now, before routing, and cards
  as `never-delegable`.
- a failed second pass reported layer `second-pass` and would have routed on an outage. It now
  reports `fallback`, which no route accepts (`a_failed_second_pass_cards` proves no chief is
  asked, even with the grant).

Broker: `resolveDelegated` falls through to `resolvePending`, which finds the card in
`approvals()` by engine request id or session id and answers it in that session
(`conv.answer`, so the engine sees a normal `Op::Permission`), with a `delegated:chief: …`
row. Authority: the chief (`SessionBroker.chiefOf`, wired to `Library.shared.chief`) or the
session's parent; a session's own card and everyone else are refused. `ListApprovals` now
reports `approval_id` (the engine request id) so a caller knows what to name; its note says who
may answer.

Tests added: engine `egress_tests::an_egress_ask_routes_to_the_chief_when_the_class_is_granted`,
`::an_egress_ask_cards_the_user_without_the_grant`, `::a_never_delegable_egress_ask_still_cards_the_user`,
`a_failed_second_pass_cards` (rewritten for the fallback layer + no chief);
`delegation::tests::an_egress_ask_is_its_own_soft_class`; config grant assertions.
App: `SessionBrokerTests.testTheChiefAnswersAPendingCardAndNobodyElseCan`,
`testAParentAnswersItsChildsPendingCard` — SessionBrokerTests 55/55 green.

Audit copy for a chief-decided egress card:
  notice:  delegated:chief: `Bash curl -sS -m 3 -o /dev/null https://pkgs.example.org/x; echo rc=$?` — approved by chief (— its own package host)
  decision: layer "delegated", outcome "allow", reason "chief approved it (— its own package host) [egress-widen]"
  a pending card answered directly: transcript row `delegated:chief: <chief> approved `Bash cargo build``

Sandbox note: `sandbox-exec` nesting fails inside frog's sandbox here ("sandbox_apply: Operation
not permitted"), so the `#[cfg(target_os = "macos")]` egress tests and the pty/terminal-pane
tests only pass unsandboxed — the documented environmental class. Everything else runs in the
sandbox.


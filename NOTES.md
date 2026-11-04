# mode-applies — notes

Branch `frog/mode-applies`, worktree `/Users/cam/Developer/frog/.frog/worktrees/mode-applies`,
off `7841fa2d` (post #255 merge, tracks origin/main). One commit per unit (`git commit -s`),
never push. Edit tool only for source. `| head -60` caps. Never launch a Frog build.

## The bug (chief's evidence)

Cam set five workers to yolo with SetSessionMode; transcripts still read `mode=auto` ten
minutes later. Workers dispatched by a yolo manager are also born auto. He approves cards all
day. Three bugs:

1. **SetSessionMode waits for a turn boundary.** A mode is a safety setting, not conversation
   state: it must apply at the next tool call (next permission decision), not the next turn.
   `Op::SetMode` is handled in `crates/frog-engine/src/engine/mod.rs`; the permit path reads
   `self.mode` in `crates/frog-engine/src/engine/permit.rs`. Fix: a live value the permit path
   reads per decision (AtomicU8 on the shared state), durable `mode_changed` event logging
   unchanged.
2. **Children born in auto.** `apps/macos/Frog/Model/SessionBroker.swift` ~:461-473 handles the
   `mode` param with a cap. Default becomes: child inherits the parent's mode (capped so it can
   never exceed the parent). yolo needs no explicit `yolo: true` when the parent is already
   yolo (the parent's grant is Cam's); a default/auto parent must never silently produce yolo.
   Then the StartSession tool description in `crates/frog-engine/src/tools/sessions.rs`
   (~:100-115): "yolo never inherited implicitly" is the behaviour being changed.
3. **Yolo egress path.** Merged yolo fix reads `if self.mode == Mode::Yolo && self.can_ask &&
   egress_ask.is_some()`. If `can_ask` is the only remaining guard, drop it (headless already
   denies earlier in the flow).

## Checkpoint (before first edit)

- Branch confirmed, no uncommitted changes.
- Next: read engine/mod.rs op dispatch, permit.rs, SessionBroker.swift, then edit + tests.

## Units

- **U1 — SetMode applies at the next decision (BUG 1).** `Op::SetMode` was a queued op:
  the router passed it to the work loop, which takes one op at a time, so a turn inside a
  20-minute build never saw it. Now the router stores the mode into `Shared::mode` (an
  `AtomicU8` discriminant on the shared state, seeded from the agent's real mode after
  `Agent::new` so a resume can't be downgraded to the flag) and still forwards the op; the
  agent's `handle` reconciles `self.mode` and keeps the durable `ModeChanged` exactly as
  before (idempotent: no re-log for a repeated op). The permit path syncs per decision
  (`permit` → `sync_mode` → `live_mode()`), so the very next tool call obeys the change, and
  `log_mode` writes the `mode_changed` at that first governed decision. `emit_status`
  reports the live mode, so the sidebar is exact mid-turn.
- **U2 — children inherit the parent's mode (BUG 2).** `SessionBroker.childMode` dropped
  its "yolo is never passed on silently" exception: the child inherits the parent's mode
  exactly, still capped (`rank`) so it can never exceed it. A yolo parent is Cam's explicit
  grant, so its workers are born yolo; a default/auto parent still can't produce a yolo
  child. Tool docs updated: StartSession no longer says "yolo never inherited implicitly";
  SetSessionMode now says it applies "at its next permission decision, even mid-turn".
  Swift tests: `testChildModeInheritsCapped` (renamed from
  `testChildModeInheritsCappedAndNeverSilentYolo`).
- **U3 — the yolo egress guard is the mode (BUG 3).** The branch read
  `mode == Yolo && can_ask`; `can_ask` was the only thing routing a headless yolo call to
  the deny below — the brief's "headless already denies earlier in the flow" is not true
  for egress (there is no earlier deny). Now the guard is `mode == Yolo` alone, with the
  headless deny made explicit inside the branch (decision row `egress/ask/"yolo, not
  interactive: widening denied"`, then `Deny`). Interactive yolo unchanged (one quiet
  `EgressWidened` row); headless still denies, never cards.

## Test counts

- **Rust (unsandboxed, per the brief):** `cargo build -p frog -p frog-engine` clean; full
  `cargo test -p frog-engine` **599 passed, 0 failed, 8 ignored**, three consecutive runs.
  Targeted: `a_mode_set_mid_turn_governs_the_next_permission_decision`,
  `yolo_never_cards_on_egress`, `headless_yolo_denies_instead_of_widening`,
  `yolo_still_blocks_an_undeclared_host`, all pass.
  Gotchas hit: (a) the egress tests sandbox-exec their commands, so running cargo inside
  frog's own sandbox fails them all with `sandbox-exec: sandbox_apply: Operation not
  permitted` (sandbox-on-sandbox) — unsandboxed they pass, exactly as the brief warned;
  (b) `a_broken_body_stream_is_retryable…` passes in full-suite runs but can fail when the
  filter isolates it repeatedly (its `127.0.0.1` server connection times out) —
  environmental, not related to this branch; (c) disk hit 100% mid-verify (~116 MB free)
  and stalls looked like test hangs until space freed — commit-first saved the work.
- **Swift:** *(filled below)*

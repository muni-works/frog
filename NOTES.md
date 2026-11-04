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

## Test counts

*(filled at the end)*

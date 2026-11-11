# Graceful restart for Frog.app updates

Design doc; implemented on `frog/graceful-restart-design` (all six picks accepted). Before it, an an app update or reinstall (Cam's 14:36) kills every engine
mid-turn: sessions sit with no `turn_ended` and a stale `.live` file, the app shows them
"idle", and a message respawns them on the *sender's* model (bug 2c, fixed separately by
"resume keeps model"). Goal: an opted-in user gets an instant update — running agents stop at a
safe point, the app restarts, and every agent picks up where it left off, on its own model.

The pieces that already exist and this builds on:

- **Session logs** (`crates/frog-engine/src/session.rs`): one JSONL per session, line 1 a
  header (with the model), `flock`-guarded, fsynced at turn boundaries, torn tails tolerated.
- **`Op::Continue`** (`crates/frog-engine/src/protocol.rs:61`): resumes a cut-off turn with a
  note; `Engine::start` already detects a `TurnStarted` with no `TurnEnded` and repairs the
  history (`repair()` fills missing tool results with an interrupted marker).
- **`OpenSessions` / `SessionRegistry`** (`apps/macos/Frog/Model/SessionRegistry.swift`):
  `open-sessions.json` already records id, cwd, model, pane slot, `turnRunning`, and restore
  actions per session on quit.
- **Sparkle** (`apps/macos/Frog/Model/Updates.swift`): the current update path. Sparkle
  terminates the app after install; there is no pre-quit drain.

The gap: nothing tells a running engine "stop *soon*, you'll be resumed". Cancel looks like the
user's stop (`[Request interrupted by user]`, `EndReason::Cancelled`), and Sparkle just kills.

## 1. The drain signal and its safe points

**Protocol Op, not SIGTERM.** The engine reads ops on a queue and already has immediate
(`Interrupt`) vs queued semantics; SIGTERM would race the tokio runtime and can't carry a
deadline. Add:

```rust
/// Graceful stop for an app update: finish the current step, then stop at the next
/// safe point and exit. Not a cancel — the turn is resumable via `Op::Continue`.
Drain {
    /// Unix ms; after this the engine force-stops and records itself suspended.
    deadline: i64,
},
```

`Drain` is immediate, like `Interrupt`, but cooperative: it sets a flag checked at the two
**safe points** in the agent loop —

1. **between model calls** (a step finished; the model's message and all tool results are in
   the log), and
2. **between tool calls** (a tool returned; its result is recorded).

**A tool in flight** gets the rest of the deadline, then is killed (its
`CancellationToken` — the same one `Interrupt` uses — is cancelled) and recorded as
`tool result: "Interrupted by app update; will be re-run or resumed."` (is_error, distinct
from repair()'s "Interrupted by user before this ran."). In-flight streaming text from the
model is kept: the partial assistant message is already pushed/extended as it arrives, so it
survives.

**A new end reason.** The turn ends with `EndReason::Suspended { resume_at_step: Option<u64> }`
added to the `EndReason` enum (protocol.rs). It is recorded durably as `TurnEnded`, exactly like
a normal end. It must never be conflated with `Cancelled`:

- the transcript marker is `[Suspended for app update]`, never `[Request interrupted by user]`;
- `OpenSession.userStopped` stays false (the `action(for:)` restore logic then continues it);
- `repair()` on resume already appends the missing-tool-results user message — the suspended
  marker content is what distinguishes the cases in history.

A `Suspended` turn carries on automatically at restart (it's the same shape as a crash-resume,
which `action(for:)` already handles when `quit == .resume`). `Drain` while idle is a no-op ack.

**Sequencing with Sparkle.** Sparkle's `SPUserDriverDelegate` / delegate callbacks
(`updaterWillShowModifiedUpdateAlert` is too early; use the install-step delegate where the
relaunch is about to happen — `SPUpdaterDelegate` doesn't have it, so use
`SPUserDriverDelegate.updater(_:willInstallUpdate:)`) fire before the app terminates: Frog
drains all engines there, then allows termination. Debug builds have no updater, so the same
drain path is also callable from a debug menu item ("Simulate update…") for testing.

## 2. What gets persisted

The session log already carries history, events, snapshots and checkpoints. On `Drain`, at the
safe point, the engine fsyncs (`Journal::sync`) and additionally:

- **Pending tool state:** nothing extra needed — at a safe point every in-flight tool has
  either a recorded result or an interrupted marker (above). Partial shell output is already
  streamed as `Event::Output`; the tail is captured by the kill marker.
- **Background jobs** (`background.rs`: shell jobs, monitors, timers; background `Task`s are
  retired — parallel work is a child session, see `kids.rs`):
  start/finish are durable (`BackgroundStarted`/`BackgroundDone`). On drain, each still-running
  job is stopped and recorded `BackgroundDone` with outcome `interrupted_by_update`. On resume,
  the engine does **not** re-run them automatically; the "resumed after update" notice lists
  them by id so the model can decide to re-attach (call `JobOutput`/re-launch) or drop them.
  Re-running blindly would duplicate side effects (a second `git push`, a double purchase).
  Subagents (Task children) are their own engines logging to the same store; a `Drain` to the
  parent cascades `Drain` to live children (the engine already tracks them for
  `StopSubagent`), each recording its own `Suspended` turn.
- **Panes:** already handled — on resume, stale pane ids from the log are closed
  (`Event::PaneClosed`) since their shells died with the process. Drain adds nothing.
- **Queued inbound SendMessages (the inbox):** ops queued in the engine's mpsc that haven't
  run yet are the app's problem, not the log's. The broker delivers via `Op::Deliver`; if a
  delivered message never ran as a turn (no `TurnStarted` for it), the app re-delivers it
  after resume. Simplest correct rule: on drain, the engine acks with a list of un-run queue
  contents; the app re-sends those as fresh ops post-restart. (The queue is small — usually
  empty — so this is a rare path.)
- **Pending approval cards / open questions:** an open permission request or `Event::Question`
  at drain time is recorded as resolved-dismissed (the engine already does this for
  interrupts: `QuestionResolved` with a default answer). The resumed turn's history shows the
  tool result as interrupted-by-update, so the model re-asks if it still needs it.

The `.live` file is truncated/removed on clean drain exit (it's per-process view state); stale
ones from crashes are already tolerated.

## 3. The restart handshake

Sparkle installs and relaunches. The handshake around it:

1. **Pre-quit (old app):** drain all engines (per-session `Drain` with a shared deadline, the
   engine acks with `Event::Drained { session, steps_done }`). Wait until all ack or the
   deadline passes; force-stop stragglers (their logs show an unfinished turn — the crash path).
2. **Resume manifest:** reuse `open-sessions.json` — `SessionRegistry.quitting(.resume)` plus
   per-session `turnRunning` already *is* the manifest; add one field, `suspendedByUpdate: Bool`
   (or just infer: `turnRunning && lastEndReason == suspended`). No new file format.
3. **Relaunch:** Sparkle relaunches the new bundle (or the user opens it). At launch the
   registry is read as today; the quit marker says `.resume`, so each entry's restore action is
   `.continue`.
4. **Post-restart (new app):** windows open, engines spawn with `-r <id>`, each engine detects
   the unfinished/suspended turn exactly as `Engine::start` does today.

## 4. Auto-resume

For each restored session with a suspended turn, the app sends `Op::Continue { note: Some(
"<resumed after the app updated; your previous turn was suspended; continue>") }` — a sibling
of `CONTINUE_NOTE`, distinct from the crash note. The model:

- runs **on the session's stored model**: the engine is spawned from the header's model
  (`Options.resume` path) and the app must pass the session's model, never the default or the
  sender's — bug 2c's fix (fc123e7) already guarantees this for `frog --resume`; the app-side
  restore passes `OpenSession.model`, and the engine falls back to the header, not the
  profile default.
- mode, profile and context window likewise come from the session/config as in any resume.

The transcript gets a small system notice (like `ResumedBanner` today): "resumed after update",
and the turn continues from the repaired history. Sessions that were idle at drain just reopen,
no turn.

## 5. CLI workers (`frog -p`, `--serve`, the chief's frog-worker lanes) and app engines

All engines are separate processes, app ones included (`EngineProcess`). An update replaces
the app bundle; CLI binaries live elsewhere (`~/.local/bin`, cargo installs, worktrees), so:

- **CLI workers never see the app update** — they keep running untouched. No drain, no
  suspend. Only the *sidecar* (if a frog-engine sidecar ships inside the bundle) gets the
  drain via the same `Drain` op.
- An app update should not touch running CLI sessions' `flock`s: they hold their logs, the new
  app's engines must not touch those sessions (the existing `Log::open` refusal covers this —
  "session open in another frog process").
- The one shared-file risk is the *config* and *skills* directories versioned with the app;
  running CLIs read them lazily. Acceptable: they keep their loaded copies for the rest of
  their process lifetime.
- `frog -p` one-shot runs: if the user updates mid-run, the process is independent and simply
  finishes; no change.

So: only app-spawned engines drain. Everything else survives by being outside the bundle.

## 6. Opt-in, timeout, testing

**Opt-in:** a setting, default **off** ("Update without stopping my agents" vs "Instant
updates: pause agents at a safe point and resume them"). When off, Sparkle behaves as today
(quit prompt per `QuitGuard`, agents die mid-turn, resume-as-crash). When on, the Sparkle
delegate runs the drain instead of the quit prompt. Cam's manager fleet is the obvious first
audience: agents run long turns, and an update should cost them one resumed step, not a
cancelled turn.

**Timeout and fallback:** one shared drain budget, default **20 s** (setting, 5–120 s). Each
engine gets the whole budget (parallel drain). Engines that ack early exit early; an engine
that misses the deadline is SIGKILLed and left as an unfinished turn — i.e. today's crash path,
which already resumes via `Continue` with the crash note. So the fallback is never worse than
status quo. A drain that starts and is then cancelled (user picks "Cancel" in Sparkle) sends
`DrainAbort`; engines ignore it if already suspended (resume on next user message).

**Test plan (integration, engine side, no GUI):**
1. `drain_between_tools`: script a turn with several tool calls; deliver `Drain` mid-turn;
   assert `TurnEnded` reason `Suspended`, log fsynced, no `[Request interrupted by user]`.
2. `drain_kills_long_tool`: a tool that sleeps past the deadline; assert the interrupted-by-
   update tool result, then `Suspended`.
3. `drain_resume_continues`: after (1), spawn a new engine with `resume`, send `Continue`,
   assert the stored model is used (scripted provider records the request), the turn completes,
   and the notice event is present.
4. `drain_during_model_stream`: `Drain` while the provider streams; assert the partial text is
   kept and the turn suspends at the stream's end (model calls are a safe point only once the
   message closes).
5. App-side: a debug menu "Simulate update" that runs the full drain → quit → relaunch loop on
   a test session; assert `ResumedBanner` shows and the turn continues.

## 7. Decisions for Cam

1. **Turn off for everyone at first, enable for your manager fleet via setting.** Safest
   rollout; you get instant updates where it matters, strangers aren't surprised by resumed
   turns. Tradeoff: most users keep losing turns to updates until it's proven.
2. **Drain signal = a protocol Op (`Drain`), not SIGTERM.** Carries a deadline, reuses the
   immediate-op path, testable in-process. Tradeoff: an engine wedged *outside* the op loop
   still needs the SIGKILL fallback.
3. **Background jobs are stopped and listed on resume; the model decides what to re-run.**
   Never duplicates side effects. Tradeoff: a long build job is lost and must restart from
   scratch even when it was 95% done.
4. **Re-queued inbox: un-run delivered messages are re-sent by the app after restart.**
   Correctness over elegance (no inbox persistence format). Tradeoff: a message delivered
   twice could run twice if the crash lands between turn-start and log fsync — accepted, it's
   the same risk as a crash today.
5. **Timeout: 20 s shared budget, then force-kill falls back to the crash-resume path.**
   Bounded wait, fallback already works. Tradeoff: a turn with a 30s model call suspends
   crudely (as a crash) rather than gracefully.
6. **Resume notice wording: `<resumed after the app updated; your previous turn was
   suspended; continue>` (own note, not the crash note).** The model knows it wasn't its
   fault or the user's. Tradeoff: one more string the model can quote back verbatim.

## 8. Field evidence: children dying with a parent restart

Reported by the frog manager session (2026-10-23), twice: the manager's own engine restarted
(07:23:58), and about 9 minutes later all 4 of its child sessions' engines died **in the same
second**. It happened again later the same morning (all 4 workers together).

What the code says (as of this branch):

- Child sessions (`StartSession`) are **not** processes of the parent engine. The app's
  `SessionBroker` owns them (`background[id]`, `SessionBroker.swift`), each its own
  `frog --serve` process. A parent engine restart doesn't reach them directly.
- A child engine that dies mid-turn is already picked back up: the broker's idle check sees a
  dead engine with an open turn, restarts it with `-r <id>` and calls `continueInterrupted()`
  (the crash-resume path; `SessionBroker.swift`, "An engine that died mid-turn").
- So "all 4 at once" points at a shared cause rather than the parent, e.g. a shared upstream
  (that morning frog cloud was down and the workers ran `cloud/qwen3-coder-next`), or the app
  itself restarting. **Not root-caused.** Next step: the four children's `~/.local/share/frog/
  sessions/<id>.jsonl` tails, plus `EngineProcess.log` around the death second, to tell an
  engine exit (stderr tail, exit status) from a provider error ending the turn.

What this branch guarantees either way: children survive as sessions (their logs are intact)
and are resumed. Through the broker's crash path when they die. Through `Drain` (the
subagent cascade is tested; app-level sessions drain one by one in `UpdateDrain.drainAll`)
when the app updates with graceful restarts on.

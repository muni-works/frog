# The engine is a daemon; the app is a frontend

Plan, 2026-11-12. Prompted by the failure in the wild (composer-sizing session, 2026-11-12): an
agent rebuilt the app and ran `open frog.app` to check its work. macOS handed the folder to the
running copy, which quit; the new copy's restore waited `--wait-lock 5` for the old engine to
let go of the session log, expired, and the session died with a red line — then the compaction
rescue ("start a carried-forward session") failed too, because the broker that would run it was
in the app that was being killed. The app is both the host of every engine and the thing under
test, so testing the app costs sessions.

**Thesis.** The engine (`frog --serve`) is already a separate process speaking a line protocol.
The only thing tying it to the app is ownership: the app spawns it, stops it, and dies with it.
Flip ownership: the engine outlives the app, and the app attaches. Restarting the UI becomes a
non-event — mid-turn, mid-compaction, mid-anything.

Builds on (all exist and are load-bearing):

- **Session logs** (`crates/frog-engine/src/session.rs`): one JSONL per session, `flock`-guarded,
  fsynced at turn boundaries. The lock already encodes "who owns the session" at process
  granularity.
- **The serve protocol** (`crates/frog-engine/src/protocol.rs`, `crates/frog/src/headless.rs`):
  Op JSONL in, Envelope JSONL out; durable events carry `seq` for replay (`Op::Subscribe`).
- **Follow** (`crates/frog-engine/src/follow.rs`): a client that opens a session another process
  holds replays its log and streams what it appends, read-only. The app already uses this shape
  when a session is taken.
- **`ConversationLink`** (`apps/FrogKit/Model/Conversation.swift`): the conversation's engine is
  already an interface, not a process. `CloudLink` (websocket, reconnect + replay after
  `resume_after`), `RemoteLink` (phone→Mac) and `EngineProcess` (pipes) all implement it. A
  link that talks to a live daemon is one more implementation, not a rewrite.
- **Restore machinery** (`apps/macos/Frog/Model/SessionRegistry.swift`, `open-sessions.json`):
  id, cwd, model, `turnRunning`, queued messages, restore action — a manifest the attach path
  can consume as is.
- **Drain/suspend** (`Op::Drain`, `docs/design/graceful-restart.md`): built for update
  relaunches. With a daemon it demotes to an optimization (drain *before* detach so nothing is
  mid-flight), not the thing that keeps sessions alive.
- **`Frog.released(session:within:)`** (`apps/macos/Frog/Engine/EngineProcess.swift:17`): the
  Swift side can already wait out a flock.

## Design

### Phase 1 — sessions survive the app (the pain killer)

**`frog --serve --unix <path>`**: the serve protocol over a unix-domain socket stream instead
of pipes, and the process detaches (`setsid`, stdin null) so it is not tied to its spawner.
Socket at `~/.local/share/frog/serve/<session>.sock` (dir 0700; same trust domain as the logs).
An optional first frame `{"hello":{...}}` → `{"welcome":...}` / `{"refused":...}` carries the
protocol version (the ws path's handshake, reused) so an old app attaching to a newer engine
gets "update needed" instead of garbage.

**Attach instead of spawn.** `Conversation`'s engine path gains a second constructor: if the
session's socket exists, connect; if connecting fails or the engine dies, fall back to spawn
with `--wait-lock` (today's behavior). `EngineProcess` stays the class — it gains an
"attach" mode that connects to a socket instead of spawning, so the line plumbing
(`onLine` → `RemoteBridge.forward`, `outLines`, exit logging) is shared. Pipes and sockets are
the same code shape: one stream of lines in, ops out.

**Keep-alive policy: the app's death is not the session's death; the user's close is.**
- On quit-with-resume and on update relaunch: detach, don't stop. The daemon engine keeps the
  turn running.
- On window close / conversation close while the app lives: today's behavior (stop the engine).
  An explicit user close is a stop.
- At next launch, restore attaches to live engines instead of waiting on flocks: no
  `--wait-lock 5` against your own engines, no lost turns, no "still open in another frog
  process after 5s".

**Environment.** Detached engines are spawned with the same `Frog.environment` PATH once, at
spawn; `FROG_APP_PID` is *not* set for daemon-mode engines (sidecars follow the engine's
lifetime the way CLI runs already do — `sidecars/frog-apple` watches the pid only when the
variable is present). The engine's own `ParentWatch` on the daemon socket's owner is not needed:
the engine *is* the daemon.

**Failure semantics stay honest.** The socket belongs to the engine process, so EOF = engine
gone, exactly like pipe EOF today. The reconcile-from-log watchdog, follow-mode fallback and
red-line error paths are unchanged.

### Phase 2 — the fleet (one supervisor, no new wire protocol)

`frog fleet`: a headless supervisor that owns engine processes — spawns them per session
(per-session sockets exactly as Phase 1), answers attach, lists live engines, applies keep-alive
policy, and is the one place that knows how to start an engine in this store. Clients (app,
second app copy, CLI `frog attach <id>`) speak the same per-session socket protocol; the fleet
is a babysitter, not a proxy. This kills the spawn race of Phase 1 (both apps check `in_use`,
both spawn, the loser's engine bails on the flock and its app attaches instead): the fleet
serializes ownership.

- **Cross-build sharing.** The dev app (`toys.frog.dev`) and the installed app both default to
  the same fleet (same store). Your real sessions keep running while the dev UI restarts all
  day. Engine-on-engine work sets `FROG_FLEET=isolated` (own store root) so a dev engine never
  shares state with the release one.
- **Sparkle updates** become: detach from the fleet, swap the bundle, reattach. The drain
  machinery stays for the brief window the fleet is mid-update itself.
- **Sidecars and lending.** `tang-llm` (MacLender) and `frog-apple` move to fleet-start, once,
  instead of per-app — they already outlive engines and get reused; the app's copies become
  attach-only.
- **The broker stays in the app.** `SessionBroker` (StartSession/SendMessage orchestration,
  worktrees, approvals) is UI-adjacent policy; sessions it starts spawn *through the fleet*,
  but the orchestration remains a frontend concern until there's a reason to move it.

### Phase 3 — the end state

- The app bundle stops spawning engines in any path; every engine it shows lives in the fleet.
- A UI crash costs nothing: reopen and you're where you were (the transcript replays from the
  log's durable seqs; PTY terminals live in engine processes the fleet kept, so a terminal
  survives too — today's graceful-restart doc treats pane death as accepted; here it's fixed).
- `serve-ws` (Frog Cloud) and the unix fleet are the same role at two trust boundaries; the
  CloudLink reconnect/replay code is the template both share.

## Build order

| Step | What | Where |
|---|---|---|
| A | `--serve --unix <path>` + detach + hello/welcome version check | crates/frog |
| B | `EngineProcess.attach` (socket mode, shared plumbing); Conversation tries attach, falls back to spawn | apps/macos |
| C | Keep-alive policy on quit/update (detach, not stop); restore attaches to live engines | apps/macos |
| D | Stopgap regardless of phases: on resume-by-lock-failure, wait via `Frog.released` up to 30 s and retry before declaring the session dead; never auto-open a fresh conversation over a recoverable one | apps/macos |
| E | `frog fleet` supervisor + `frog attach`; keep-alive policy and engine listing move there; sidecars to fleet-start | crates/frog, apps/macos |
| F | Dev/release fleet sharing + `FROG_FLEET=isolated`; drain demoted to pre-detach optimization | apps/macos, crates/frog |

A–D are shippable alone: they end the "testing frog kills frog" failure with the architecture
the codebase already has. E–F are where "app is just a frontend" becomes structural.

## Tests

- Rust: `--unix` end-to-end (spawn detached, ops in, envelopes out, EOF on kill); hello version
  refuse; two attaches (follow semantics via flock held by the engine).
- Swift: attach-or-spawn matrix (socket live / stale / absent); quit-with-resume keeps the
  engine (no `stop`); restore attaches without `--wait-lock`; the existing
  `SessionBrokerTests`/`ContinuityTests` suites keep passing with a socket-mode test double.

## Cut (for now)

- A multiplexed multiplexer daemon (one socket, many sessions, ops framed per session) — the
  per-session socket reuses the protocol verbatim; multiplex only pays for it when a remote
  attach needs one port, and serve-ws covers that.
- Moving compaction or the broker into the daemon.
- Fleet discovery beyond this machine (that's the node protocol's job).

## Open

- **Who reaps abandoned engines.** A fleet with no clients keeps engines until idle grace
  (today's `idleGrace`), then stops them; a fleet-less Phase 1 engine detached from a crashed
  app needs the same grace — owned by the engine itself (no client attach for N minutes →
  stop), since without a fleet nobody else is watching.
- **Two frontends, one session.** Both apps attach read-write; ops serialize at the engine.
  The transcript diverges only in client-side caches, which reconcile from the log on next
  event. Acceptable; revisit if it bites.
- **Socket squatting.** A dead socket file at `<session>.sock` with no engine behind it is just
  stale state; connect-refused → fall back to spawn (same path as Phase 1's race loser).

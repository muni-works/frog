# Delegated approvals

Status: design, direction from Cam 2026-10-25 · 2026-10-25

Auto mode's failure mode isn't sloppiness, it's noise: the classifier flags anything unusual and the session cards the user, so a day of agents is a day of cards. Cam's rule: **we only care about irreparable harm.** `rm -rf` outside scratch and `ssh` deserve a double-check; everything else should flow. And when a call *is* flagged, the answer usually isn't Cam — it's more context, then the chief of staff. Cam is the last resort, not the default.

## Philosophy

- **Irreparable harm is the only real harm.** Anything undoable — a build that fails, an edit, a pod that restarts, a temp dir that gets recreated — should not cost a human decision. Today's flagged→card path treats recoverable annoyance as danger; that's the noise we're removing.
- **Flags are questions, not verdicts.** A flag means "the cheap judge lacked context," and the fix for missing context is context: what the session is doing, what it recently did, who owns the paths, what the task actually needs. Only a flag that *survives* context is real.
- **Delegate down, never up.** The escalation ladder ends at Cam and starts well below it. The chief (a session, not a person) is the first approver; Cam sees only what the chief can't decide and what nobody may delegate at all.
- **Fail closed, flow by default.** Every failure mode (classifier error, timeout, chief unreachable) lands on the *more* careful side, but the careful side is "card," not "block forever." The default path — most calls — never touches any of this.

## Pipeline (supersedes flagged→card)

```
call
 → allow layers (reads, sandbox, provenance, prefix, [mcp_trust]) — unchanged
 → hard rules: rm -rf outside scratch, ssh → ALWAYS double-checked, even outside auto mode
 → auto mode, no hard rule: cheap classifier (today's auto.rs judge, unchanged)
     → allow: run
     → flagged:
         → context-rich SECOND classifier pass (same Classifier, richer prompt)
             → allow (upgraded, with a reason): run; audit "delegated:auto"
             → still flagged:
                 → class in [delegation] chief's grant list?
                     → yes: route to the CHIEF session via the broker
                         → chief approves → run; audit "delegated:chief"
                         → chief unreachable / busy / declines / no reply → card Cam
                     → no (never-delegable class): card CAM directly
```

Key properties:

1. **The second pass can only upgrade, never downgrade a card into a hidden allow it can't justify** — it upgrades flag→allow *with a reason*, and the reason is audited.
2. **Error/timeout on the second pass = keep the flag** (card). Never fail-open.
3. **The chief comes before Cam.** Cam's card only fires when the class is never-delegable, or the chief couldn't take it.
4. **Hard classes override every allow.** A never-delegable call (see below) goes to Cam even when the classifier said allow; soft classes only choose between the chief and Cam.
5. **rm and ssh always double-check** — the second pass at minimum — in every mode, not just auto.

## Grant classes

The vocabulary the classifier's reason and the config share. A class is a *shape of harm*, not a tool name:

| class | shape | examples |
|---|---|---|
| `ssh-scratch` | remote shell into ephemeral infra the session itself spun up | `ssh runpod@<pod-this-session-created>` |
| `pod-spend` | creates or bills compute the org pays for | RunPod pod create/start within a capped budget |
| `own-scope-writes` | writes inside the project or the session's own scratch | Write/Edit outside the checkout but into session-created paths |
| `scratch-deletes` | deletes inside the session's own scratch only | `rm -rf /private/tmp/deleg-target` (this session made it) |
| `network-read-writes` | network calls that send the session's own data out but to a first-party endpoint | pushing to the project's own remote, API writes for the task's own resources |
| `mcp-write-granted` | MCP writes on a server already granted in `[mcp_trust]` but flagged for another reason | `mcp__runpod__pod-action` on a session-created pod |
| `long-commands` | long multi-step commands that are individually ordinary | the 12-command deploy script, all segments routine, all paths own-scope |

There are two kinds of class, and they do different jobs:

- **Hard (never-delegable)** — fixed, in code, not config. These override everything: a classifier `allow` (first or second pass), a `[delegation]` grant, a chief's approval. A call in a hard class always reaches Cam as a card.
- **Soft (the grant classes above)** — these only decide whether a call that is *still flagged after the second pass* goes to the chief or to Cam. They never turn a flag into an allow by themselves, and they never apply to a hard class.

The hard set:

- deletes outside the session's scratch (`rm -rf` or any other kind)
- force-push / history rewrite on a shared remote
- production deploy
- purchase / spend beyond configured caps
- public posts, publishing, and messages to people (email, chat, social)
- credentials access (reading or moving keychains, tokens, `.env` secrets out)

The hard set is fixed so a mis-edited config can never widen it. Config can only add soft classes to the chief's list.

## Config shape

`[delegation]`, mirroring `[mcp_trust]` (config.rs ~294):

```toml
[delegation]
# The session that decides flagged calls in these classes. Name or id,
# resolved by the broker exactly like SendMessage's `to`.
chief = ["chief", "chief-of-staff"]

# Which classes the chief may decide. Everything else (or an absent
# chief) cards Cam.
chief_classes = [
  "ssh-scratch", "pod-spend", "own-scope-writes", "scratch-deletes",
  "network-read-writes", "mcp-write-granted", "long-commands",
]

# One approvals roll-up notice per day, at most (default true).
rollup = true

# Seconds the chief has to answer before the card falls back to Cam.
chief_timeout_secs = 300
```

Absent `[delegation]`: today's behavior, plus the second pass. `chief = []` disables delegation entirely (everything flagged twice cards Cam).

## Second classifier pass

Same `Classifier` struct and provider; a richer prompt built on top of `describe()`:

- **Session brief**: the task as stated (recent user messages, already collected) plus the agent's own last statement before the call (what `approval::card` already shows).
- **Recent actions**: the session's last few tool calls — what it already did successfully.
- **Target ownership**: for each path the call touches — in-project, session-created (`approval::created`), fresh scratch, or foreign; for MCP calls, whether the target resource belongs to this session.
- **Task need**: what the call is *for*, phrased from the brief ("cleanup of a build dir it created", "restart the pod it owns").

Output schema adds a `context` decision value: `allow` / `ask` / `ask-cam`. `allow` upgrades the flag (audit: reason). `ask` keeps the card. `ask-cam` short-circuits to Cam. Any error/timeout/unparsable answer = keep flagged (card), never fail-open. The pass runs only on flagged calls, so its cost lands on maybe 1 in 50 calls.

## Chief routing

The engine already asks the client to carry session tools (`Event::SessionRequest`, `tools::sessions::Hub`): `SendMessage`, `ListSessions`, `StartSession`. Delegation rides the same wire, no new transport:

1. Engine emits `Event::SessionRequest` with tool `DelegateApproval`: `{ id, tool: "DelegateApproval", input: { approval_id, tool, arg, card, class, reason, second_pass } }` — the full card the user would have seen.
2. The broker (SessionBroker.swift) handles `DelegateApproval` like any session request: resolve `[delegation] chief` by name/id, `send(from: "system", ...)` the escalation text (the same structure as `SessionBroker.escalation`), and hold the reply.
3. The chief sees a normal `<session-message>` and answers by sending `Op::Permission { id: <approval_id>, decision }` — its engine is told the approval id; a chief without engine access replies via `ResolveDelegated` message text (`approve <id>` / `deny <id> <note>`), which the broker parses and routes as `Op::Permission` into the *asking* session.
4. On answer: `Op::Permission` flows into the asking engine's existing `Op::Permission` path. Audit notice `delegated:chief: <tool> <arg> — decided by <chief name>`; the decision event carries `layer: "delegated"`.
5. Unreachable / rate-limited / timeout (`chief_timeout_secs`) / unparseable answer → the engine's normal card path, marked `delegation fell back to the user`.

**Stub, documented:** until the broker gains the `DelegateApproval`/`ResolveDelegated` handlers, the engine treats `DelegateApproval` exactly like any other session request the client may answer — a client that doesn't know it will never answer, the wait times out, and the card falls back to Cam. So the engine ships complete and safe with no app change; the app change only turns the fallback into the real thing.

## Audit

Extends #95's notice pattern (`mcp_trust` at engine.rs:4318 — `self.notice(Level::Info, line)` plus a durable `PermissionDecision`):

- every second-pass upgrade: notice + decision `layer: "second-pass"`, outcome `allow`, the reason in `reason`.
- every chief delegation: notice tagged `delegated:chief:` + decision `layer: "delegated"`, `reason` naming the chief and the class.
- every never-delegable card: decision `layer: "never-delegable"` so the approvals roll-up can separate them.
- chief fallbacks (unreachable, timeout): notice `delegated:chief: fell back to the user (<why>)`, decision `layer: "delegated"`, outcome `ask`.

## Cam's approvals roll-up

Named to avoid colliding with the sidebar's hover-summary "digest": this is the count of who decided what. It replaces per-card interrupts for Cam — at most **one notice per day**, plus an on-demand roll-up:

- The engine keeps the day's counters in memory (per session): `delegated_chief`, `auto_allowed` (first + second pass), `blocked` (cards Cam saw / denies), `never_delegable`. Date-keyed, midnight rollover.
- `Op::ApprovalDigest` (new, client-triggered like `Op::Shell`) returns this session's counts as text; `frog approvals --since 24h` rolls up every session's durable `PermissionDecision` events from the session logs. Also emitted as the day's single notice, at the first Cam-carded call after midnight (so the daily notice exists only on days something actually reached Cam).
- Target, from Cam: **≤5 cards/day.** The roll-up exists to measure it. If `blocked` sits above 5 for a few days, the fix is a grant class or a wider scratch rule — a config change, not new machinery.

## Failure modes

| failure | behavior |
|---|---|
| second pass errors / times out / unreadable | keep the flag → card (never fail-open) |
| chief not configured | card Cam (no delegation anywhere) |
| chief unresolvable (renamed, archived) | card Cam + one notice |
| chief busy / doesn't answer in `chief_timeout_secs` | card Cam |
| chief's answer unparseable | card Cam, notice says so |
| chief approves a never-delegable call | impossible by construction: never-delegable classes never route to the chief |
| config grants a class not in the vocabulary | warn once at startup, ignore the unknown class |
| roll-up counter lost (crash) | counters are advisory; next session starts at 0 |

## Testing

Per class, in `engine.rs`'s test harness (`engine_perm_cfg`, scripted classifier via a `cfg(test)` verdict hook):

1. second-pass upgrade: `rm` of the session's own scratch with a brief that says cleanup → runs, no card.
2. `ssh` into session-created scratch → upgraded, runs.
3. `ssh` outside scratch → still flagged → chief list contains `ssh-scratch` → `delegated:chief` audit emitted.
4. `rm -rf` outside scratch → Cam card even when the chief list has `scratch-deletes`.
5. second pass errors → card.
6. chief unreachable (session reply errors) → card Cam.
7. roll-up counts: one of each path → `Op::ApprovalDigest` returns 1/1/1 (+ never-delegable).
8. all #95 approval tests still pass unchanged.

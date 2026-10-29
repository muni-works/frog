# Frog web (frog.toys)

A clickable prototype of the Frog web app. It's front-end only. Every session pretends to run in a private Frog Cloud sandbox, and there's no backend or auth yet. Design source: `docs/design/frog-web/` (`Workspace.dc.html` with `platform="web"`, `Composer.dc.html`, `PromoCard.dc.html`). `src/tokens.css` and `src/components.css` are copied unchanged from `ds/frog/`.

```bash
npm install
npm run dev      # http://localhost:5173
npm run build
```

## What works

- **Signed out** (`/`): "Try one" starters, the Mac card, a sign-up card and the composer. Sending a message, or clicking a starter, shows the sign-up gate. The fake "Sign in with GitHub" lands you in a new session that is already running your message.
- **Signed in**: the sidebar (New session, Search, Repos, Routines, Skills), Needs you with inline Allow and Deny, and sessions grouped by repo with status symbols. The thread has tool lines, "Decided" steps, streamed replies and diff cards with Allow ⌘↩ / Deny ⌘.. The composer has a run-on chip fixed to Frog Cloud, a model pill and the context bar (repo, branch, bound PR with checks, changes with Commit or Push). The inspector has Changes, Terminal and Preview tabs.
- **Connect a repo** picker, the **out-of-credits** card (in "Move dates to Temporal"), the **⌘K** palette and **Settings** (⌘,) with Account, Plan, Models, Permissions and MCP tabs.

To jump straight to a screen, add `?demo=` with `gate`, `workspace`, `credits`, `repos`, `palette` or `settings`. Add `?theme=light` or `?theme=dark` to pin the theme. These are for review and screenshots.

The sign-up gate is one branch in `App.tsx` (`if (!signedIn)`), with `gate` holding the message the user sent. A guest allowance would replace that branch.

## How the mock maps to the engine protocol

The UI talks to an engine only through `EngineClient` (`src/engine/client.ts`):

```ts
interface EngineClient {
  subscribe(session, after, onEnvelope): () => void   // Op::Subscribe { after }, then live events
  send(session, op: Op): void                         // Op::Submit / Permission / Interrupt
}
```

`src/engine/protocol.ts` is a TypeScript slice of `crates/frog-engine/src/protocol.rs`. It uses the same serde tags (`op`, `event`, `type`) and snake_case names, so real JSONL parses into it unchanged:

| Protocol (Rust) | Used by the web app for |
|---|---|
| `Envelope { seq, session, created, ..event }` | Every event. `seq` starts at 1 and only grows; the reducer drops anything `<= lastSeq`, so replays that overlap live events are safe. |
| `TurnStarted { turn, input }` | The user's bubble, and the composer's timer (from `created`). |
| `ItemStarted { id, kind }` | A new entry: `message`, `reasoning` (drawn as a "Decided" step) or `tool_call { name, arg }`. |
| `ItemDelta { id, delta }` | `text` streams the reply. `output` streams a running tool and feeds the Terminal tab. |
| `ItemCompleted { id, item }` | Finishes the entry. A `tool_call` with a `diff` (`FileDiff`) becomes a diff card and adds to the Changes tab. |
| `PermissionRequest { id, item, name, arg, preview }` | The diff card's Allow and Deny, and the Needs you card in the sidebar. Answered with `Op::Permission { id, decision }`. |
| `PermissionResolved` | Clears the ask. |
| `TurnEnded { reason }` | Stops the turn. `error { error: { type: "out_of_credits" } }` shows the out-of-credits card. That error type is a placeholder until the gateway defines one. |

`src/engine/thread.ts` folds envelopes into a `Thread` with a pure `reduce(thread, envelope)`. Replay and live streaming use the same code path.

`src/engine/mock.ts` (`MockEngine`) keeps a log of envelopes for each session, replays it on `subscribe`, and plays scripted turns with delays. A script step can wait for `Op::Permission` before it goes on. Seeded sessions are made by running the same scripts with no delays, so the history comes through the protocol too.

### Swapping in Frog Cloud

Write a `CloudEngine implements EngineClient` that opens a websocket to the session's sandbox (via the gateway), sends `Op` JSON, and calls `onEnvelope` for each JSONL line. Then change one line in `src/store.ts` (`export const engine: EngineClient = …`). Session metadata (title, repo, branch, bound PR, checks) is in-memory in `store.ts` today. It belongs to the account API, not the engine stream.

## Not here yet

Real auth, the account and session list API, billing, email sign-up, routines, skills, image attachments, and the Preview tab showing a real sandbox port.

## Frog Cloud transport

`src/cloud/` talks to the Frog Cloud gateway (`docs/plans/2026-10-28-frog-cloud-wire-contract.md`): `client.ts` does the §2 handshake (refused, reconnect with `resume_after`) and the §4 routes, `protocol.ts` mirrors `crates/frog-engine/src/protocol.rs`, and `transcript.ts` folds envelopes into a transcript. `test/` runs it against the zest mock gateway, vendored in `test/mock/`.

```bash
npm run mock   # mock gateway on :8788; any key is an account
npm run dev    # Vite proxies /v1 (and its websockets) to $GATEWAY, default the mock
npm test
```

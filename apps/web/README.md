# Frog web (frog.toys)

The Frog web app. Every session runs in a private Frog Cloud sandbox, reached through the Frog Cloud gateway (`docs/plans/2026-10-28-frog-cloud-wire-contract.md`). There's no fake data: sessions, transcripts and the account all come from the gateway and the accounts edge. Design source: `docs/design/frog-web/` (`Workspace.dc.html` with `platform="web"`, `Composer.dc.html`, `PromoCard.dc.html`). `src/tokens.css` and `src/components.css` are copied unchanged from `ds/frog/`.

## Run it locally

```bash
npm install
npm run mock                    # mock gateway on :8788; any bearer key is an account
VITE_DEV_KEY=dev npm run dev    # Vite proxies /v1 (HTTP and websockets) to $GATEWAY, default the mock
npm run check && npm test && npm run build
```

`VITE_DEV_KEY` (dev builds only) skips sign-in and uses that key with the gateway. Without it you get the real sign-in, which needs the edge to allow your origin (below).

| Variable | Default | What |
|---|---|---|
| `VITE_API` | `https://api.frog.toys` | Accounts edge: sign-in, `/v1/auth/exchange`, `/v1/me` |
| `VITE_GATEWAY` | the page's origin | Frog Cloud gateway (`/v1/sessions`, websockets) |
| `GATEWAY` | `http://127.0.0.1:8788` | Where Vite's dev proxy sends `/v1` |
| `VITE_DEV_KEY` | unset | Dev only: skip sign-in |

## Sign-in

GitHub on api.frog.toys, ending in a `frog_` key for this browser (`src/auth.ts`):

1. `signIn()` makes a PKCE verifier, an S256 challenge and a state, keeps them in sessionStorage, and goes to `api.frog.toys/auth/web?challenge&state&device&return` (ecto/zest#77). The edge runs GitHub if you're signed out, then 302s back with `?code&state`.
2. `finishSignIn()` checks the state and calls `POST /v1/auth/exchange {code, verifier, device_name}`, which returns `{key, account}`. The key goes in localStorage and is the bearer for the gateway and `/v1/me`.
3. The device is `frog.toys web · xxxx`, one per browser, so it can be revoked on its own from api.frog.toys/account. Signing in again on the same browser replaces it.

If you typed a message before signing up, it survives the GitHub round trip, and the repo picker opens with it once you're back. The edge only redirects to origins in its `WEB_APP_ORIGINS` var. To sign in from localhost, add `http://localhost:5173` there.

## How it maps to the engine protocol

The UI talks to an engine only through `EngineClient` (`src/engine/client.ts`). `CloudEngine` (`src/engine/cloud.ts`) implements it over the gateway client in `src/cloud/client.ts`: one websocket per session, the §2 handshake, and reconnects with `resume_after`.

```ts
interface EngineClient {
  subscribe(session, after, onEnvelope): () => void   // connect, replay seq > after, then live
  send(session, op: Op): void                         // Op::Submit / Permission / Interrupt
}
```

`src/engine/thread.ts` folds envelopes into a `Thread` with a pure `reduce(thread, envelope)`, so replay and live use one path:

| Protocol (Rust) | Used by the web app for |
|---|---|
| `Envelope { seq, session, created, ..event }` | Every event. Anything `<= lastSeq` is dropped, so replays that overlap live events are safe. |
| `TurnStarted { turn, input }` | The user's bubble, and the composer's timer (from `created`). |
| `ItemStarted { id, kind }` | A new entry: `message`, `reasoning` (drawn as a "Decided" step) or `tool_call { name, arg }`. Item ids are scoped to their turn. |
| `ItemDelta { id, delta }` | `text` streams the reply. `output` streams a running tool and feeds the Terminal tab. |
| `ItemCompleted { id, item }` | Finishes the entry. A `tool_call` with a `diff` becomes a diff card and adds to the Changes tab. |
| `PermissionRequest { id, item, name, arg, preview, reason }` | A diff card (edits) or a command card, with Allow ⌘↩ / Deny ⌘., and the Needs you card in the sidebar. Answered with `Op::Permission`. |
| `PermissionResolved` | Clears the ask. |
| `Titled { title }` | The session's name in the sidebar and title bar. |
| `TurnEnded { reason }` | Stops the turn. An `error` mentioning `insufficient_credit` (the edge's 402) shows the out-of-credits card. |

Sessions come from `GET /v1/sessions` (refreshed every 15 s), new ones from `POST /v1/sessions {repo}`. The app streams the open session and any whose sandbox is `running` or `starting`. It doesn't attach to `sleeping` ones, because attaching would wake them. Commit, Push and Open PR are messages to the agent, so they show up in the conversation like any other step.

## Not here yet

Each of these needs an API that doesn't exist yet, so the UI leaves it out instead of faking it:

- A list of the repos the GitHub App can see. The picker takes `owner/name` or a URL.
- PR checks. The PR number shows when the session summary has one.
- A model list and model switching.
- Permission modes, MCP servers, routines and skills.
- The Preview tab. It needs a sandbox port.
- Email sign-in.
- Asks after a reconnect. `PermissionRequest` isn't durable, so a client that attaches mid-ask (after a reload, or on another device) doesn't see the open ask. The engine or gateway needs to re-send outstanding asks after replay.

## Frog Cloud transport

`src/cloud/` talks to the gateway: `client.ts` does the §2 handshake (refused, reconnect with `resume_after`) and the §4 routes, `protocol.ts` mirrors `crates/frog-engine/src/protocol.rs`, and `transcript.ts` is a standalone fold its tests use. `test/` runs them against the zest mock gateway, vendored in `test/mock/`.

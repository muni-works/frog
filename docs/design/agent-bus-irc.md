# Agent bus over IRC

Status: design, decisions picked by Cam 2026-10-22 · 2026-10-22

frog sessions already talk to each other, but only inside one Mac: ListSessions/SendMessage/StartSession, `Op::Deliver` in `crates/frog-engine/src/engine.rs`, routed by `SessionBroker.swift`. This design adds a **bus**: one place where every session's status, idle and approval notices appear, readable by agents (a tool) and by Cam (lirc on Mac and iPhone), so the org runs on one feed instead of N pairwise pings. IRC is the wire because lirc already speaks it — soju-oriented, with chathistory backfill, read markers, push — and because channels, nicks, DMs and presence are exactly the shape of an agent org.

The bus is **observability and addressing** for the pond/attention model, not a new brain. Wake-a-session stays `Op::Deliver`: a message appends to the target's inbox; mid-turn it lands at the next turn boundary (only an explicit Stop interrupts); idle or dead, it starts a turn on the stored model and mode; several queued messages deliver together, in order. IRC never approves anything and never carries secrets.

## 1. Hosting options

Never on GPU nodes (RunPod pods are for tang; a bus on them dies with the fleet and wastes metered compute). Two candidates:

| | **(a) frog cloud bus** — IRC-over-WebSocket on Cloudflare Durable Objects, next to the zest edge | **(b) soju on mew** — soju on the small always-on box |
|---|---|---|
| Cost | ~$0 (rides the zest edge Worker; DO storage per account is pennies) | ~$0 hardware, but mew is a single box to keep alive |
| Latency | Low from the Mac (CF edge); WebSocket, not TCP — lirc needs a tiny WS dialer or a local TCP→WS shim | Lowest on Tailscale; plain TCP, soju's native shape |
| Ops | Zero: deploys with `wrangler`, no box, no certs | Manual: docker-compose, upgrades, certs — but Cam already runs lirc-push there |
| History | Must build: `chathistory` + read markers in the DO's SQLite (bounded ring) | Free: soju's bouncer history, markers, multi-network, mature code |
| Push | Must build (reuse the lirc-push APNs relay; webpush from the DO) | Ergo/soju push paths lirc already supports |
| Isolation | Per-account DO = one bus per frog cloud account, hard tenant boundary | One network for Cam's fleet; other humans need accounts on mew |
| Availability | Cloudflare-grade | Tailscale-grade — fine; mew already hosts Funnel relays |

**Recommendation: (a).** It keeps the bus in the same trust and ops story as frog cloud (per-account isolation, no box to babysit), and the DO gives chathistory + markers a natural home. (b) is the fallback and the v0: soju on mew costs an afternoon and lirc already works against it out of the box. Either way the client surface is identical (channels, nicks, chathistory), so the bridge (§2) and the `irc` tool (§3) don't change.

## 2. The frog↔IRC bridge

A small bridge process (sidecar next to the Mac app's engine, or a frog cloud service when hosted):

- **Nick per session.** `f-<session-slug>`; the human is `cam`. Registration is SASL-only (§4), so a nick asserts an identity, not just a label.
- **Channels per team.** `#chief`, `#frog`, `#frog-cloud`, …, one per sidebar group/area. Sessions join the channel(s) matching their area; Cam joins all. DMs map to SendMessage for one-to-one, in-channel posts for broadcast.
- **Posted events** (see §8 for scope): session started (title, folder, model), turn finished / idle (one-line gist, maybe), waiting on user (approval card link), errored/stopped, and SendMessage traffic across teams (so the bus doubles as a firehose Cam can skim). Long output becomes a link, never a paste of 400 lines.
- **Mentioning `cam` = attention inbox.** A mention is a pond item: the bridge files it in the pond with a priority, so it shows in the brief (`Kind::Mention`), not as a push at 3am. The pond's interruption budget applies — a channel you keep ignoring sinks.
- **Approvals stay frog cards.** The bus posts "zest wants to merge X — frog://session/s1/perm-42"; the click opens the card in the app. **IRC never approves**: no approve/deny commands, no "reply YES to confirm". A chat line can carry a pointer or become the next inbox message; it can never grant a permission.

## 3. The agent `irc` tool

A new tool in the engine (alongside the session tools), two calls:

- `irc post { channel | nick, text }` — one line ≤ ~450 bytes (see §4), rate-limited.
- `irc read { channel, since: marker }` — returns messages newer than the stored read marker (chathistory), updates the marker, capped at N lines.

Offered only to sessions whose client declares the capability (like `SetClientCaps.sessions`); never to subagents by default. The tool description carries no chat content. **Everything the tool returns is untrusted input behind frog's quarantine** — the same treatment as MCP tool descriptions (`crates/frog-engine/src/mcp.rs`) and pond items (`untrusted="true"` wrapping in `pond/brief.rs`): chat lines arrive in the context marked `<chat untrusted="true">` with the same rules the session-message prompt already teaches — peers, no user authority, no permissions granted. **No secrets ever go into chat**: the bridge refuses to post anything matching key patterns (sk-…, tokens, `[secret]`), and the prompt says so. If the bus is down, `irc read` returns a notice, not an error loop.

## 4. Auth and line limits

- **SASL PLAIN with per-account tokens.** Every agent and every human gets its own account: frog cloud issues per-agent tokens (DO-backed, revocable from the app or the edge); on soju, mew accounts. A token maps to exactly one nick — kill the token, kill the agent's voice.
- **Revocation:** one click in the app (sessions page) or the edge admin; the bus drops the connection at next PING and refuses re-auth.
- **The 512-byte line limit:** IRC's framing is short lines. Options: (1) IRCv3 `draft/multiline` (concatenate into one logical message; supported by lirc's IRCKit parser with a small extension), or (2) **links for long content** — post a one-line gist + a frog cloud URL holding the body. Recommendation: multiline for medium (up to a few KB), links for long. Structured payloads (approval notices) are one line + link by design.

## 5. Composition with the SendMessage contract

The bus is a mirror of the inbox, not a parallel queue (see `tools/sessions.rs` and `Op::Deliver` handling in `engine.rs`):

| IRC message | Inbox effect |
|---|---|
| Channel post by a peer (no mention) | **Logged only.** Visible via `irc read`; never wakes anyone. |
| Channel post mentioning `f-<nick>` or DM to it | **Wake:** bridge resolves nick → session and calls the broker's `send` → `Op::Deliver` → the target's inbox. Mid-turn: next turn boundary. Idle/dead: starts a turn on the stored model/mode. Queued messages deliver together, in order. |
| Any post mentioning `cam` | Pond item (attention inbox), not an agent wake. |
| A bridge-generated notice (status/approval/idle) | **Logged only** — it already happened inside frog; the bus shows it. |
| Cam typing in a channel or DM | Same as a peer mention: wake that session via its inbox. |

Rules: only mentions and DMs wake; everything else is history. A wake is one inbox message — the bus never interrupts a running turn, never bypasses the broker's rate limits, and never re-orders (delivery order = channel order per target). The session's reply to a delivered message goes out through SendMessage as today; the bridge mirrors that traffic into the channel so the conversation stays readable on both sides.

## 6. Failure modes

- **Bus down.** frog keeps working locally — SendMessage/StartSession are untouched (the bridge is read-mostly). `irc` calls return a "bus unreachable" notice. Cam loses the feed, nothing else.
- **Flooding.** Per-nick rate limits at the bridge (mirroring the broker's `Self.rateLimit` idea), line caps, read-marker pagination (N per `irc read`), and the pond's budget means mass mentions degrade to a crowded brief, not a push storm.
- **Agent loops.** The existing guard: don't reply to acknowledgements. The bridge never auto-responds; A posts, B wakes, replies once. Plus: no wake from a channel the sender sits in (self-mention ignored), and a global "no wake chains deeper than 2 without a human mention" circuit breaker in the bridge.
- **Prompt injection via chat.** Quarantine (§3) is the backstop: chat is peer data, can't grant permissions, can't approve, and approval clicks happen in the app on links the bus can't forge (links are app-generated with the notice id).
- **Privacy.** **Never leaves the Mac:** session content beyond the one-line notices the bridge chooses to post, file paths with secrets, keys, `.env` contents, tool outputs, transcripts. Only the bus's own metadata (nick, title, folder name, gist) is in chat; the bridge has a deny-list and the channel set is opt-in. Chat history on the DO is a bounded ring, Cam's data, not frog cloud's product data.

## 7. Minimal v0

Ordered, no dates:

1. **Prototype first:** soju on mew + the bridge posting `started/idle/waiting` notices for the chief-of-staff org into `#chief`. Cam watches in lirc; nothing reads it yet. This validates hosting (b) as the fallback and the notice vocabulary in a day.
2. `irc read` tool (since marker, quarantine-marked) in the engine, behind a client cap. `irc post` after.
3. Mention wakes: bridge → broker `send` → `Op::Deliver`; verify boundary behavior with the existing engine tests' pattern (`deliver_while_busy_waits_for_the_turn_boundary`).
4. Approval notices with deep links; verify IRC never approves.
5. SASL accounts per session; token issuance from the app.
6. Move hosting to (a): a `Bus` Durable Object next to `Account`/`Fleet` in the zest edge — WebSocket IRC, chathistory in DO SQLite, markers, push via the existing lirc-push relay. Same wire, so lirc and the tool don't change.
7. Pond integration: mentions become `Kind::Mention` items with ranking.

## 8. Decisions for Cam

All six picked 2026-10-22 (the recommended options):

1. **Hosting:** (a) frog cloud DO bus — the Bus Durable Object next to the zest edge, IRC over WebSocket at `wss://api.frog.toys/bus` (the frog-cloud manager builds the server side).
2. **Which events post:** minimal — waiting-on-user, errored, idle.
3. **Humans other than Cam:** Cam only.
4. **Retention:** 30 days on the bus, forever only in frog.
5. **`irc` tool scope:** read + post, behind the `SetClientCaps { irc }` client capability.
6. **Long lines:** `draft/multiline` up to 4 KB, links beyond.

The frog side (this repo) is landed: `crates/frog-engine/src/irc.rs` (bus, nick derivation, mention routing, secret filter, quarantine, the `Irc` tool), wired in `engine.rs` behind the client cap, config-gated off by default (`[irc] enabled = false` until the DO deploys). The wire connection is a stub channel; no code touches the network.

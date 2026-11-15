# Every frog is a node

Plan, 2026-11-11, revised after a blind review the same day. Builds on [frog node](2026-10-04-frog-node-design.md) (N0–N6). Prompted by Apple's Harbor (Claris, private preview): Macs pooled over Thunderbolt 5 into one private inference server.

**Thesis.** The same one as [elegant and legendary](2026-10-27-elegant-and-legendary.md): shrink the core, and be the thing nobody else can be.
- **Elegant:** one idea, nothing to configure. Every machine of yours that frog can run on is a node: found on its own, trusted once, pooled.
- **Legendary:** frog owns its inference (tang), its app and its transcript. So a turn survives a machine going away, and a session can move between your machines while staying warm.

Harbor pools memory between Macs and stops at an endpoint. frog pools any machine you own (Mac or CUDA box) and is the agent that uses the pool.

**Scope: local only.** Frog Cloud already works as a provider and stays as it is: no Frog Cloud nodes, no cloud KV, no cloud in the scheduler. Moving any of that onto the node protocol needs its own plan, starting from a multi-tenant threat model (shared prefix caches, timing side channels, client-supplied KV). The map keeps showing Frog Cloud as it does today.

---

## The story

> "I have a second machine. Two minutes later frog is using it, and I never typed an address or a key."

- **Two Macs** (Harbor's pitch): no terminal at all.
- **A Mac and a GPU box** (Harbor can't): one command on the box.

## Elegant: one idea

**Every frog is a node.**
- **One binary.** A Mac lends its compute with one toggle (Settings → "Lend this Mac to my other Macs"); Frog.app already bundles `tang-llm`. A Linux box runs `curl -fsSL https://frog.toys/node | sh`: the same `tang-llm` built for CUDA, plus a systemd unit.
- **One gesture to trust.** The node shows a 6-digit code; type it once on the Mac. The code authenticates a key exchange, so it's useless to anyone watching the network.
- **No providers for your nodes.** A paired node joins the pool instead of becoming a row in Settings → Providers. The model picker lists models, each with where it would run.
- **One surface.** The composer chip ("on mew · 41 tok/s") and the map it opens. The Devices window is the map at full size.
- **Failure is quiet.** frog owns the transcript and KV is a cache: if a node goes away mid-turn, the partial answer is dropped and the turn reruns on the next node with that model, with one line saying so.
- **Local first, always.** Your machines are preferred. Nothing moves to Frog Cloud unless you picked a cloud model. A session can be locked "local only", and the receipt is computed from where each call actually ran.

## Legendary

1. **The turn survives.** Close the lid on the box mid-turn; the chip says "on this Mac" and the turn finishes.
2. **A hot session moves between your machines.** KV blocks stream from one node to the other instead of re-reading 30k tokens. tang already has content-addressed blocks and a disk tier. Your machines only: every node is yours and trusted.
3. **Width.** Subagents, the auto-mode classifier and best-of-n spread over idle nodes. The map draws them as flows.
4. **Every turn has a receipt.** "ran on mew · 412 tokens · 7.1 s · stayed on your network", from where it actually ran.
5. **The additivity bench.** Adding a node never makes a task's median or p95 slower, and killing one mid-task still finishes. A target until the bench proves it; then public.

## Security (from the review)

Today a keyless `tang-llm serve` beyond loopback serves anyone on the network, and `/node` lists `prompt_cache_keys`. That's fixed first, before anything widens exposure.
- **No key, no network.** `tang-llm` refuses a non-loopback address without a key. `/node` and `/v1/*` are always key-gated beyond loopback; `/health` stays open.
- **Pairing authenticates, not just authorizes.** The 6-digit code drives SPAKE2 (already chosen in the frog node design): both sides derive a shared secret only if they hold the same code, which pins the node's Ed25519 identity and wraps the API key. Sniffing, relaying or a spoofed Bonjour record gets nothing. Mutual TLS on the pinned keys follows; the key exchange is v1.
- **Rate limits and a window.** Pairing is open for two minutes after the node shows the code, five tries, then closed.
- **Un-pair** from either side: the Mac forgets the key, the node revokes it.
- Same-Apple-account pairing without a code is out until it has a real design.

## Build order

| Step | What | Where |
|---|---|---|
| D0 | No keyless serve beyond loopback; `/node` and `/v1` key-gated; `/node` stops listing cache keys without the key | tang |
| D1 | Pairing: node identity (Ed25519) and code; `POST /pair` runs SPAKE2, pins the identity, hands over a key; window and rate limits; un-pair | tang |
| D2 | "mew is on your network. Use it?" → code → Keychain → the node joins the pool | app |
| D3 | Model identity across nodes (weights hash plus quant, not display names); pooled models in the picker; the chip resolves through the pool | tang, engine, app |
| D3.5 | Placement stub: the pinned node if any, else any node with the same model id, else this Mac | engine |
| D4 | Failover: a dropped node mid-turn drops the partial answer and reruns the turn from the transcript on the next node with that model; tool calls that already ran stay done | engine |
| D5 | The installer: `frog.toys/node` for Linux; the "Lend this Mac" toggle (on power only by default, paused on thermal pressure, never prevents sleep) | site, app |
| D6 | Models onto nodes from the picker (`/models/load`), with the fit check | app |
| D7 | The scheduler (N4): estimated finish time, KV affinity, width, fair queues when several Macs share a node | engine |
| D8 | Hot-session hand-off between your nodes | tang, engine |
| D9 | Splitting a model over Thunderbolt (N6). Cross-node speculative decoding only if a measured round trip leaves a gain | tang |

**The first demo (D0–D4):** run tang on mew, type 6 digits on the Mac, pick a model both machines hold (Qwen3-4B). The chip says "on mew" and the map lights up. Stop mew mid-turn: the chip goes "on this Mac" and the turn finishes. Every number on screen is measured.

## Cut

- Setting up your own box as a custom provider becomes pairing. Existing custom providers keep working; the app offers to pair one when its host turns out to be a node.
- Keyless `tang-llm serve` beyond loopback.
- The Devices window as its own destination.
- Frog Cloud as nodes (see Scope).

Kept from what's built: Bonjour discovery (`_frog-node._tcp`), `/node`, the composer chip, the map.

## Open

- **Off your network.** The café-to-home story needs a node reachable away from the LAN. Tailscale names work today by address; anything more (a relay) contradicts "no relay for now" and needs a decision.
- **Version checks.** The app reads `/node`'s `schema`; a node too old or too new shows "update needed" instead of joining.
- **Sleep and wake.** A sleeping node drops out like a failed one; Wake-on-LAN for a paired box is a maybe.
- **Several Macs, one node.** Fair queueing lands with the scheduler (D7); until then, first come first served.

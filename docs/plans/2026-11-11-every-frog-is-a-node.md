# Every frog is a node

Plan, 2026-11-11. Builds on [frog node](2026-10-04-frog-node-design.md) (N0–N6) and [Frog Cloud as the model gateway](2026-10-29-frog-cloud-model-gateway.md). Prompted by Apple's Harbor (Claris, private preview): Macs pooled over Thunderbolt 5 into one private inference server.

**Thesis.** The same one as [elegant and legendary](2026-10-27-elegant-and-legendary.md): shrink the core, and be the thing nobody else can be.
- **Elegant:** one idea, nothing to configure. Every machine frog can run on is a node, and that includes Frog Cloud.
- **Legendary:** frog owns its inference (tang), its app and its transcript. That lets it do things an endpoint can't: move a hot session between machines, run one stream on two machines, and finish a turn when a machine goes away.

Harbor pools memory between Macs and stops at an endpoint. frog pools any machine (Mac, CUDA box, Frog Cloud) and is the agent that uses the pool.

---

## The story

> "I have a second machine. Two minutes later frog is using it, and I never typed an address or a key."

- **Two Macs** (Harbor's pitch): no terminal at all.
- **A Mac and a GPU box** (Harbor can't): one command on the box.

## Elegant: one idea

**Every frog is a node.**
- **One binary.** A Mac lends its compute with one toggle (Settings → "Lend this Mac to my other Macs"); Frog.app already bundles `tang-llm`. A Linux box runs `curl -fsSL https://frog.toys/node | sh`: the same `tang-llm` built for CUDA, plus a systemd unit.
- **One gesture to trust.** The node shows a 6-digit code; type it once on the Mac and the node's key goes into the Keychain. Two Macs on the same Apple account may skip the code. A node listening beyond loopback never runs without a key.
- **No providers for nodes.** A paired node is not a row in Settings → Providers; it joins the pool. The model picker lists models, each with where it would run and how fast.
- **One surface.** The composer chip ("on mew · 58 tok/s") and the map it opens. The Devices window is the map at full size, not a separate concept.
- **Failure is invisible.** frog owns the transcript and KV is a cache: a node going away re-prefills elsewhere, and the turn says so in one line.

## Frog Cloud is nodes too

Today Frog Cloud is a provider (`cloud/*`, OpenAI chat completions at `api.frog.toys/v1`) that the zest edge routes to tang's GPUs or other upstreams. Make the tang part of it nodes:

- **zest exposes each account's slice of Frog Cloud as nodes.** The same `/node` shape scoped to the account: the models it can serve, measured rates, this account's queue, and this account's KV (cache keys and block hashes, in a per-account namespace). Auth is the account key the app already has. No pairing.
- **One scheduler.** The engine places every call over this Mac, your nodes and Frog Cloud with the same estimated-finish-time rule. Cloud wins when it's faster or when nothing local fits the model, and the cost (dollars per token) is part of the decision when the user sets a budget.
- **The map shows it honestly.** Frog Cloud is a node on the map linked by "Internet", priced per token, with a receipt line on every turn that ran there.
- **Hand-off falls out.** Because cloud nodes speak the same KV protocol, moving a hot session between local and cloud is the same operation as between two local machines. That was a separate roadmap item ("handing a hot session from local to cloud without re-sending it") and now isn't.

What stays in zest, not the node protocol:
- auth, credit, the usage ledger and pay-per-token billing
- multi-tenancy: one GPU serves many accounts, so KV is isolated per account and `/node` never shows another account's queue or blocks
- third-party upstreams (Claude and others through the gateway). They are Frog Cloud *models*, not nodes: no `/node`, no KV, routed as today.

Trade-offs to watch:
- A cloud "node" is a slice of a shared pool, so its rates move with other tenants' load. `/node` reports what this account would get now, not the GPU's peak.
- Scheduler polling over the internet costs requests. Poll cloud nodes slowly and lean on per-response timing headers instead.

## Legendary: what only frog can do

1. **A hot session moves between machines.** Close the laptop at a café; at home the session is warm on the box, because KV blocks stream across instead of 30k tokens being re-read. tang already has content-addressed blocks and a disk tier.
2. **Two machines on one stream.** The Mac drafts, the box verifies (cross-node speculative decoding, already decided in the frog node design). Two machines make one session faster, not only bigger.
3. **Width.** Subagents, the auto-mode classifier and best-of-n spread over idle nodes. The map draws them as flows.
4. **Every turn has a receipt.** "ran on mew · 412 tokens · 7.1 s · stayed on your network".
5. **The additivity bench, public.** Adding a node never made a task's median or p95 slower; killing one mid-task still finishes. Weekly, on the scoreboard.

## Cut

- Setting up your own box as a custom provider (base URL, key, port). Paired nodes replace it; custom providers stay for other people's servers.
- `tang-llm serve --host <non-loopback>` without a key.
- The Devices window as its own destination.

Kept from what's built: Bonjour discovery (`_frog-node._tcp`), `/node`, the composer chip, the map.

## Build order

| Step | What | Where |
|---|---|---|
| D1 | Pairing: a node makes its key on first run and shows a 6-digit code; `POST /pair` trades the code for the key, rate-limited and time-boxed | tang |
| D2 | "mew is on your network. Use it?" notice → code → Keychain → the node joins the pool; no keyless non-loopback serve | app, tang |
| D3 | Pooled nodes in the model picker, models not machines; the chip resolves through the pool | engine, app |
| D4 | Failover: a dropped node re-prefills on the next best, with one line in the turn | engine |
| D5 | The installer: `frog.toys/node` for Linux, the "Lend this Mac" toggle | site, app |
| D6 | Models onto nodes from the picker (`/models/load`) | app |
| D7 | Frog Cloud as nodes: account-scoped `/node` in zest; the engine schedules over it | zest, engine |
| D8 | The scheduler (N4): estimated finish time, KV affinity, width | engine |
| D9 | Hot-session hand-off between nodes, local and cloud | tang, engine |
| D10 | Cross-node speculative decoding; splitting a model over Thunderbolt (N6) | tang |

**The first demo (D1–D4):** run the installer on mew, type 6 digits on the Mac, pick Qwen3-Coder-Next. The chip says "on mew · 58 tok/s" and the map lights up. Unplug mew mid-turn: the chip goes "on this Mac" and the turn finishes.

## Open

- Pairing strength for v1: the code trades for an API key (proposed), with SPAKE2, pinned keys and mutual TLS from the frog node design to follow.
- Same-Apple-account trust without a code: what proof (iCloud Keychain item, a CloudKit record) is strong enough.
- Whether Frog Cloud nodes show as one node or one per region/GPU class on the map.

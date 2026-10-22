---
name: product-direction
description: "Cam's product decisions (2026-10-20) — one staged muni app, free app + paid agent on zest, cortex head as portable persistent personality with Apple-style colorways, head-as-zest-node"
metadata:
  node_type: memory
  type: project
  originSessionId: 8c3dcc85-ad81-4ab4-9e67-2dd50bec4698
  modified: 2026-10-21T00:55:55.536Z
---

Decided 2026-10-20 in the chief-of-staff session:
- **One app, staged** (Cam: "yes"): vcad desktop is the shell. v1 (~2 wks) = vcad desktop + built-in agent (frog) running on zest + gradients + photoreal renders. v2 = Simulate workspace (phyz/kosm). v3 = Operate workspace (Dojo, from ipse/apple/Dojo) once a lymb exists. The web app becomes a viewer/share link. Free app; revenue = zest tokens + lymb hardware.
- **Cortex head = persistent self.** Each head stores a personality (memory, voice, prefs, per-body schemas). Bodies are swappable, even across morphologies ("like r2d2"). Body swap is a body-schema problem → mind manager.
- **Apple-style colorways** for the head are important → rose (CMF params in cortex.loon, lineup render).
- **Head Jetson as a zest node** when docked and idle (not always on), serving frog light/offline tasks; heavy tasks go to cloud zest. Orin NX can't fit Coder-Next; ~8B or a small coder only.
- **Names (2026-10-21):** branded house = "Municipal Robotics" with lowercase products. Paid inference product = **"tang cloud"** (hosted tang), on a muni.works subdomain; "zest" is the internal codename only. Short ownable .coms don't exist, and zest/kyte/swyft carry trademark risk — that's why. The app is **vcad** (Cam, 2026-10-20: keep vcad; agent/sim/operate ship as workspaces inside it).
- **Launch:** 3 beats — Oct 30 (tang IR + #1 speed + frog OSS, tang cloud as a capped free beta), Nov 3 (compress), ~Nov 17 (app + voice + cortex; paid GA).
Open with Cam: target user for v1, umbrella brand vs vcad (ties to the pending zest rename), and whether he has an Orin on hand.

Related: [[manager-structure]], [[muni-master-plan]].

**Rebrand (Cam, 2026-10-20, supersedes "tang cloud"):** paid side = **frog pro** (subscription, hosted Coder-Next) + **frog api** (per-token); frog = free OSS agent; tang = engine ("powered by tang"). frog api priced = Novita's per-token, but faster. frog pro price: zest modeling 2–3 options.
Pricing (2026-10-20, input SUPERSEDED 2026-10-22): frog api $0.20/M in, $1.50/M out; frog pro = Pro $20 + Max $200. Domain **frog.toys** (api.frog.toys), Cam owns it at Namecheap (also frog.eco/.ceo, tang.toys, vcad.dev, phyz.dev, loonlang.com, kozm.net, muni.works exp Dec 19 2026). Renew daemon.so before Nov 5.
2026-10-21: tang-compress renamed **cram** (crate `cram-codec`). Beat 2 rescoped to the H200 result + cram; the Metal port of Coder-Next starts for a later Mac beat (48 GB Mac, ~2.5-bit). frog api 24/7 at launch (no beta hours); paid at Novita price once batching lands; AA email and OpenRouter on hold; coding-agent snippets ship with Beat 1. Robot heads: a mini and a full-size cortex, with the humanoid head pitched down by default.
Heads (Cam, 2026-10-21): sell ONLY complete products (no kits); everything open source so people can DIY. Head = Orin Nano (reComputer Mini J3011 decased) for mini; USB-only exterior (1 USB-C + pogo dock), 4S pack + 19 V buck-boost. Goal: make complete mini/full profitable, then competitive analysis (rose owns).
Head prices (Cam, 2026-10-21): mini $999, full $1,499 (complete only). frog api: windows for beta, 24/7 for first 48 h of launch, always-on after batching makes cost < price.
Design direction (Cam, 2026-10-21): first release is MINIMAL — like Seeed reBot arm but safer, in our humanoid language; no decorative perforations; black or white plastics only + fun accents (no brown). Mini = deep (+15 mm, Waveshare-capable), J3011 for MVP.
Dogfood goal (Cam, 2026-10-21): move the whole operation (CoS + managers + agents) into the frog app midday Oct 22. Managers on Opus inside frog, coding agents on frog api (Coder-Next). Gateway always-on only when ready. frog owns app gaps; zest owns gateway readiness.
Naming (2026-10-21): hosted service = "frog cloud" (plans: beta/API/Pro/Max); "frog api" only for endpoint/per-token plan. CLI `frog -m cloud/qwen3-coder-next`; local `local/qwen3-4b`. Old prefixes alias.
frog accounts (Cam, 2026-10-21): Better Auth self-hosted on Cloudflare; Postgres on Neon via Hyperdrive = source of truth; Durable Objects for live credits/rate limits; KV cache only. Beautiful sign-in + onboarding is a design deliverable.
BUDGET (Cam, 2026-10-21 evening): Claude usage 90% weekly + $4k credits — can't afford continuing in Claude. Move org into frog TODAY: managers on OpenAI via ChatGPT-subscription sign-in in frog, coding agents on frog cloud (Coder-Next). All managers paused except frog + zest. Be frugal: low effort, short messages, no watcher monitor.
Cortex compute (Cam, 2026-10-21 late): use the Seeed **J401** carrier (booted Ubuntu) as the cortex for now, instead of the Orin Nano devkit. CAN on J401 J16 and devkit J17 is 3.3V TTL only (no transceiver); plan our own transceiver breakout/harness board for real CANH/CANL.
frog cloud billing (Cam, 2026-10-22): payments WEB ONLY via Stripe (no Apple IAP; app opens browser checkout, deep-links back). At limit: offer local fallback + API overage credits. Limit shape: leaning to match Claude Code (5h windows + weekly), pending zest's cost/margin model (frog-cloud-plans-model.md). API output $1.50/M may be below H200 cost (~$1.70/M at full util) — Cam: model it first.
Plan tiers (Cam, 2026-10-22): Pro $20 / Max 5x $100 / Max 20x $200, Claude Code shape (5h window + weekly). zest model (ecto/zest 8956d0e): ~7/35/70 agent-hrs/wk, 2/4/8 concurrent at 60% margin @50% util. frog api input pricing still open (cold input is the loss: ~$2.67/M today).
frog api pricing (Cam, 2026-10-22, supersedes $0.20 flat input): $0.60/M cold input, $0.06/M cached input, $1.50/M output.

frog model family (Cam, 2026-10-22): tiers **dart · glass · bull** (small / medium / large), with **auto** as the default router and **leap** as the escalate verb ("leapt to bull for this turn"). API ids frog-dart / frog-glass / frog-bull, with dated versions (frog-glass-2610). Backing: dart = qwen3-8b, glass = Qwen3-Coder-Next UD-Q4_K_XL (Q8 tested 2026-10-22: no switch, since Q8+8b+VL is ~148 GB > 144 GB; Q4 vs Q8 top-1 97%, 20/20 coding), bull = our port of GLM-5.3-Flash or DeepSeek-V4.1-Flash (port audit pending; no Claude fill-in). Future fine-tunes: frog-coder (glass), router, compact, review, head voice, vl. Licences: Apache/MIT bases are fine to fine-tune and release as MIT OR Apache-2.0 with notices kept; never distill from closed-model outputs; user data opt-in only.

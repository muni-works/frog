---
name: muni-master-plan
description: "Brief of muni's master-plan.typ — mission, strategy, products, phases, decisions (D-numbers), metrics; how each Developer/ project maps to it"
metadata:
  node_type: memory
  type: project
  originSessionId: 8c3dcc85-ad81-4ab4-9e67-2dd50bec4698
  modified: 2026-10-20T23:16:32.845Z
---

Source: `~/Developer/muni/.claude/worktrees/quads-d33/paper/master-plan/master-plan.typ` at ee46550 ("add quads as the ground body (D33)", unpushed, 1 ahead of origin/main). Title: "Robots that build robots" (Municipal Robotics), signed Cam Pedersen, Cleveland, Oct 2026. Contact: info@muni.works.

## Mission / thesis
- Machines that make the next machine, each unit measured, until the bought fraction hits zero and a "seed" can grow where no supply chain reaches. Grows into an **autonomous company, amplified by intelligence**: it grows itself, people decide what it may do.
- Robots cost a lot because people make them (idiot index of rana parts ~8–12). The bet: own the whole stack so one gradient runs from a measured robot back to a parameter in loon source, through contact (phyz adjoint). The sim-to-real gap ε̄ is the central number, published per unit.
- Software first: frog (free coding agent) → kyte (paid inference on tang) funds the arm.

## Stages (gates, not calendars)
Only Desk is a plan. The rest are goals. Every gate threshold is "proposed, to be confirmed by the author." EUM is order of magnitude, not a target.
| Stage | What | Gate (short) | EUM |
|---|---|---|---|
| **Desk** (yrs 1–3, aspirational) | frog+kyte; lymbs sold one at a time | kyte ≥$10k/mo for 3 months with no outside money; ≥10 lymbs to outside buyers at ≥40% gross margin; ≤2.0 mm RMS tool-point error (50 poses, 0 and 1 kg); rana ≥1.2× RS04 stall torque per kg or per $, or rana is dropped | 0 W→10 kW |
| Shop | duet = 2 lymbs at any table; duet builds a duet | named task (e.g. 50 garments) ≥95%; duet assembles a lymb with ≤30 min human touch; duet builds duet at ≤20% bought cost, falling over 3 generations, shutdown drill passed | 100 kW |
| Road | humanoid (Rose) + quad; body schema; co-design by gradient | hardware body-schema fit ≤0.8× persistence at 0.1/0.5 s, masses ±5%; Rose walks 100 m with 2 lymbs, 0 falls in 5/5; co-designed part ≥10% better | 1 MW |
| City | fleet + twin work a city (Lakewood reference) | litter pilot renews ≥12 mo after ≥3-mo trial, 0 contact incidents; ≥90% repairs by duets | 10 MW |
| Home | branches on self-made collectors | ≥1 yr on own collectors; doubling over ≥3 gens; bought ≤5% | 1 GW |
| Moon | seed grows duet, with lifeline | ≥50% local mass, remote approval only | 1 kW |
| Mars | seed, lifeline cut | 0 human commands landing→receipt | 1 kW |
| Star | Dyson swarm of collectors (Mercury quarry) | none; EUM + doubling | 3.8e26 W |
Desk steps: (1) software pays for the arm, (2) an arm worth buying on RobStride, (3) own the actuator (rana/torc) only where it wins. Rose mini starts now, in parallel (Road overlaps Shop). No dates after Desk. Star ≈75 doublings from 10 kW (75 yrs at a 1-yr doubling, 375 at 5 yrs).
Next three results ("Now"): first built lymb's reach/hold/sag vs model; rana's first dyno run vs its predicted 36 N·m; preregistration of the K1 body-schema fit.

## Products / bodies (status Oct 2026)
- **frog**: free coding agent for local models. In use. Quarantines tools that look like injection.
- **kyte**: hosted inference on tang. Warm session caches, drafting, local→cloud handoff, **$0.25 per finished task**, not per token. Not built.
- **lymb** (Rose fork v9): 6-DOF arm (RS04×3, RS02×2, RS00), all plates 1/8" 5052, 786 mm reach, 8.44 kg, 1.27 kg continuous hold straight out (modeled). $5,000 list, ~$2,000 materials (~$1,200 actuators), 60% materials margin. Designed, ready to cut, none built. Sizes mini/full/mega, one loon source.
- **Gripper v2 ("hand")**: EL05 rack-and-pinion parallel jaw, 0–100 mm, 485 g. Modeled.
- **duet**: 2 lymbs + plate + hub + camera pair + kore. $12,000, ~$4,400 materials, 63%. Concept; first task is laundry folding.
- **Rose**: humanoid, "a duet on legs." mini 1.2 m/18 kg (the only size verified end to end), full 1.75 m/~55.5 kg, mega 2.0 m/64.3 kg. Full is $15,000, waits for rana. Concept.
- **quad** (new in D33 commit): replaces the rover. Four legs of lymb actuators, a lymb as the head (gripper and camera). Mini (dog), full (pony; street and litter work), mega (horse; cargo; the Moon vehicle). Mockup only. Open: does the leg reuse the lymb geometry or only its actuators?
- **moth**: street-perception drone. Never armed. Not designed.
- **seed**: duet + mill + router + collector + pack + germ line. Concept.
- **rana**: axial-flux actuator. Prototype est. $1,086 ($717 machining) plus $150–300 for teeth, vs ~$200 per RobStride joint, so it needs to be 6–7× cheaper. 36 N·m and 0.166 N·m/A are predicted upper bounds. **torc**: rana motor control (prototype).
- **Standards** (all modeled, none built): 36–60 V unregulated bus; one 13S2P Molicel P50B pack (468 Wh, ~2.65 kg; the BMS logs EUM); brick = half a pack; **kore** compute module (CM5 or Jetson carriers; open question: does a 16 GB Orin NX hold S2?); **nerv** boards (BMS and duet hub are owned first); CAN-FD tool changer; tools in order: grabber/reacher, drill (torc), leaf blower.
- In hand: Booster K1 (bought, the control body), CNC mill, software stack. EUM = 0 W. K1 ~100 W is counted as "electrons under control."

## Numbered decisions
**The file has no D1…D33 list.** No "D<n>" appears anywhere in master-plan.typ. "D33" exists only in the commit message (the quad decision). Decisions are cited as `@mr2026decisions` (a separate source, not in this file) for: the quad replaces the rover; moth; the four standards (bus/pack/kore/nerv); the board ownership order. The register itself presumably lives in another muni doc (inference). Decisions stated inline in the plan:
- Principles: (1) gates, not calendars; (2) every unit ships with its gap; (3) one part everywhere; (4) buy the commodity, own the winning layer; (5) the guarantee should live in hardware; (6) never be Flock Safety; (7) everything that can be open is open (K1 firmware excepted); (8) no division without a license.
- Safety: no weapons or military sales. Commitments carry to any acquirer. Ipse refusals are logged and never trained against.
- Replication: licensed per-copy division; a germ line no duet can edit; a "vitamin" of signed instructions; a doubling ceiling; tested stop drills; no foraging on Earth.
- Agents: caps, approvals, signed receipts, no self-raises, quarantine of outside text.
- Governance (proposed): a board of ≥3, multi-party keys, a named successor, a public license record before Shop's first division.
- The rover is retired (the earlier BVR era). Quad replaces it. rana may be dropped.

## Key numbers
- Four dashboard numbers: gap ε̄ (—), EUM (0 W), doubling time (—), labor fraction (≈100%). Also tracked: bought fraction and bought-intelligence fraction.
- kyte: a frog task is ~40 calls, ~800k tokens in and 30k out, 79% cacheable (4.8× less prefill), drafting 1.5–2.2× faster. Cost per task: DeepSeek V4 Flash ~$0.03, Qwen3-Coder-Next ~$0.11, tang on an H200 at 30% busy ~$0.06, frontier $1–3. Scaling: APIs first, then one rented H200 (~$2,500/mo, ~$3.50/hr) at ~23k tasks/mo, plus another H200 per ~45k tasks or when the last is ~40% busy. Gate: $10k/mo is about 40k tasks at $0.25.
- Lymb sensitivity: actuators +50% gives 48% margin; rana at $100/joint gives ~72%; rana at $1,086 gives −46%.
- Pack runtime ~1.7 h walking (Rose, two packs, 936 Wh). Duet ~150 W mean.
- Headcount: **one person** (Cam). Capital: undecided whether, when or how much to raise. Moon and Mars need a funder.

## Open questions and risks
- Plan-killers: lymbs don't sell at margin; the gap doesn't close to 2 mm; a duet can't build a lymb; gradients don't survive real contact (K1 flat feet).
- Others: single supplier (RobStride); 1.27 kg hold may be too small; K1 vendor support; breadth across many projects ("projects not needed in Desk wait for their stage"); rana never wins; sidewalk incident or Lakewood's legal fit (response undecided); liability owner by City; competition (humanoids, coding agents); GPU rent, heavy tasks under a per-task price, labs hosting their own agents (kyte).
- Open: cloth-contact gradient (gates folding); RS02 thread depth; clock-spring cassettes; crush-point policy; USB 2.0 over a 2.1 m harness; S2 size on a kore; ISO 13482 not assessed; Rose sizes not in one design language; the board, and who sits on it; city pricing; TODOs in the intro (Founders Inc; when and why the rover was retired).

## Software stack (periodic table, 26 elements)
Make: **loon** (source language for parts, worlds and chips; root of the tree), **tang** (math, inference, one GPU; serves kyte), **vcad** (CAD kernel with gradients), **kerf** (design to part, with a receipt). World: **wodl** (world format, concept), **kosm** (runs wodl worlds), **phyz** (physics, contact adjoint, cloth on a branch), **iris** (renderer for robot cameras, concept). Body: rana, torc, lymb, hand, duet, Rose, quad, moth, seed. Power: pack, kore, nerv. Mind: **Ipse** (developmental mind on the K1, world model, interoception; phyz/vcad sim, no MuJoCo or Isaac), frog, kyte. Silicon (Home): loom (HDL), rune (maskless lithography), chyp (inference chip). Rules: engines never depend on vcad; vcad never depends on an app; engines read wodl; one GPU device; mm, Z-up. vcad-render makes the paper's renders.
**Not mentioned in the plan:** zest, kino, irys (only "iris"; same project? inference), broca, quad00, cortex, snorlax. Rose and K1 appear as bodies, not software.

## How current agent work maps to the plan
- **tang-llm inference speed (H200, Coder-Next, gpt-oss, zest gateway)**: maps directly to Desk step 1 and the kyte ramp. Per the plan, "first tang must learn to serve many sessions at once, at full speed on rented NVIDIA GPUs," and the H200 is the plan's unit of compute. Qwen3-Coder-Next is a priced route in the plan. gpt-oss is not mentioned. zest is not in the plan; inference: it is kyte's routing/gateway layer.
- **tang-compress**: not named. Inference: it serves kyte cost per task (tang gains land in cost) and the bought-intelligence fraction step "models tuned on the company's own work." Weak, indirect link.
- **vcad engine/MCP kernel-down**: maps to vcad (Make, "exists") and the gradient chain loon→vcad→phyz→Ipse. Road co-design depends on it. The MCP surface is not in the plan.
- **rose quad00 cortex head**: Rose and quad are Road bodies, and the quad's "head" is a lymb with gripper and camera. quad00 and cortex are not named. Inference: the first quad mini prototype plus its kore/Ipse compute. Note the plan says the quad is mockup only.
- **ipse voice/broca on robot**: Ipse is in the plan (Road, the K1, body schema, refusal layer). Voice and broca are not mentioned. The plan's Road claim is the body-schema fit, not speech, so voice is **off the critical path** (inference).
- **irys splat**: likely iris, the renderer for robot cameras (concept, Shop stage), plus the city-twin visual gap. Gaussian splatting is not in the plan. The plan lists iris as "new in the stack" and an open software item. Ahead of its stage per "projects not needed in Desk wait."
- **kino stream eval**: **does not map.** kino is not in the plan. Inference: closest is measurement/receipts or the Ipse experience store.
- **snorlax home backup**: **does not map.** Personal infra. (Not "Home" the stage.)
- Desk-critical items with no listed workstream: kyte productization, building and measuring the first lymb, the rana dyno, the K1 body-schema preregistration.

# Frog Cloud base load: rent or own GPUs?

Status: proposal, 2026-11-11. Decision owner: Cam.

**Short answer: don't buy yet.** Today's traffic would fill about 0.1% of one card. Owning one RTX PRO 6000 costs about $0.70–1.05 per hour all-in, not $0.45. It only beats the $2.49/hr rented pod once coder-next keeps a card **≥35–40% busy at C=16**: about 1.3B output tokens a month on that card. Buy one 4-GPU 6000 box when the rented pod has held that level for 4 weeks. Keep DeepSeek V4.1 Flash on rented or upstream capacity until it runs at tens of thousands of tok/s.

Tags: **[M]** measured by us, **[S]** sourced (see Sources), **[A]** assumed.

## 1. What we know

| Input | Value | Tag |
|---|---|---|
| coder-next, 1× RTX PRO 6000, hand engine, C=1, ~300 ctx | 299 tok/s output | M |
| same, C=16, ~300 ctx | 1,043 tok/s aggregate output | M |
| same, C=16, ~6k ctx | 503 tok/s aggregate output | M |
| Rented 6000 on RunPod (prod pod) | $2.49/hr | M |
| Traffic, last 30 days | ~0.5M coder-next completion tokens; ~5.6B prompt tokens (89% cached) on GLM + DeepSeek; all internal | M |
| coder-next market price (OpenRouter) | $0.00000012 in / $0.00000007 cached / $0.00000080 out per token | S |
| DeepSeek V4.1 Flash market price | $0.00000015 in / $0.000000003 cached / $0.00000060 out per token (off-peak) | S |

0.5M tokens in 30 days averages about 0.2 tok/s. One 6000 at C=16 does about 1,000 tok/s. We are around three orders of magnitude below needing an owned card.

## 2. Cards

The prices are November 2026 street prices. Memory costs have pushed every card above its launch price.

| Card | VRAM | Buy price | Rent price (on demand) | coder-next fit | Tag |
|---|---|---|---|---|---|
| **RTX PRO 6000 Blackwell** | 96 GB GDDR7 | $9.3k–11.8k retail; NVIDIA store $16k | $2.49–3.36/hr | Fits on one card with KV room. Measured above. | S, M |
| H100 SXM | 80 GB HBM3 | $27k–40k (new) | ~$3.39/hr; $1.70 spot | Fits on one card, little KV at 6k × 16. Faster HBM, not worth 3× the 6000's price for us. | S |
| H200 SXM | 141 GB HBM3e | $30k–44k per card; 8× HGX ~$319k | $4.49–6.06/hr (prices up through 2026) | Lots of KV. Only sold as 8-GPU HGX boards: a $320k entry ticket. | S |
| B200 | 180 GB HBM3e | $45k–55k street; 8× server $360k–550k | $5–6.7/hr | Overkill for one 80B-A3B model. | S |
| B300 | 288 GB HBM3e | $50k–65k per GPU; 8× HGX $537k–786k | not yet common | For DeepSeek, not coder-next. | S |
| L40S | 48 GB GDDR6 | $7.5k–11k | ~$0.55/hr | Needs 2 cards, or a 4-bit quant, plus KV. Ada, no FP4. Worse $/token than a 6000. | S, A |
| RTX 5090 | 32 GB GDDR7 | $1.8k–2.5k | ~$0.35/hr | Only aggressive quants across 3–4 cards. **The GeForce EULA forbids data-center use.** Fine at home, not for a paid service. | S |
| RTX 4090 | 24 GB | ~$1.6k–2k used | ~$0.3/hr | Same EULA issue, even less VRAM. | A |

**For coder-next the 6000 is the card.** It is the cheapest card that holds the model plus a 16-way 6k KV cache, it is licensed for servers, it runs FP4, and our engine is already tuned for it. H100/H200 cost 3–4× as much per card and don't triple our throughput: decode on an A3B MoE is bound by scheduling and kernels, not memory bandwidth, at our batch sizes [A].

### DeepSeek V4.1 Flash sizing

- Native weights are ~510 GB [M, from the brief]. Add KV cache and activations.
- **4× H200** (564 GB) holds the weights with ~50 GB spare: only a few long-context sequences. It works, but it's tight.
- **8× H200** (1.13 TB) is the comfortable minimum for batching. The whole HGX costs ~$320k to buy or $36–48/hr to rent.
- **2× B300** (576 GB) is the same tight fit as 4× H200. **4× B300** (1.15 TB) is comfortable. B300 boxes ship as 8-GPU HGX, so ~$540k+.
- 6000s: 6 cards hold the weights (576 GB), 8 cards give KV room. That needs a PCIe 8-card chassis with no NVLink, so tensor-parallel all-reduce goes over PCIe 5. That is cheap (~$110k) but slow per token [A, untested].

DeepSeek output sells at $0.60 per M. Even renting 8× H200 at ~$40/hr needs ~18,500 output tok/s, sustained, just to cover the GPU bill. Its cached input sells at $0.000000003 per token, which is near zero. Our DeepSeek traffic is 89% cached prompt. **Self-hosting DeepSeek doesn't pay at any traffic we can see coming.** Resell it upstream.

## 3. Cost of owning one RTX PRO 6000 over 3 years

All hourly figures use 26,280 hours (3 years, 24/7).

| Line | Home/office rack | Colo | Tag |
|---|---|---|---|
| Card | $11,000 | $11,000 | S (mid retail) |
| Share of a 4-GPU server (CPU, 512 GB RAM, NVMe, 2.8 kW PSU, chassis ~$14k ÷ 4) | $3,500 | $3,500 | A |
| Networking share (10/25 GbE switch, optics, firewall) | $300 | $500 | A |
| **Capex per card** | **$14,800** | **$15,000** | |
| Residual value after 3 years | −25% of card (~$2,750) | same | A |
| Depreciation per hour, net of residual | $0.46 | $0.47 | |
| Power: ~600 W card + ~150 W host share; PUE 1.0 home, 1.4 colo; $0.10–0.15/kWh | $0.08–0.11 | $0.11–0.16 | A |
| Colo space and power commit: ~$200/kW-month, ~0.9 kW per card | — | $0.25 | A |
| Uplink (business fiber ~$300/mo for the box ÷ 4, or colo cross-connect) | $0.10 | $0.05 | A |
| Spares and repairs (5% of capex per year) | $0.03 | $0.03 | A |
| **All-in $/hr per card** | **~$0.70** | **~$0.95–1.05** | |
| Undepreciated (cash cost only, after payback) | ~$0.25 | ~$0.50 | |

**Frog's ~$0.45/hr estimate leaves things out.** It matches card depreciation alone, or a home rack after the hardware is paid off. Honest numbers are **$0.70 (home) to $1.00 (colo)**. That is still **2.5–3.5× cheaper than $2.49 rented**, but only for hours we actually use. Owned hours cost the same whether they're busy or idle.

Hidden costs that aren't in the table [A]: someone on call for hardware (a home rack has no remote hands), a single site, the ~4–8 week lead time on 6000s now, and residential power and cooling limits. One 4-GPU box draws ~3 kW, which is about one dedicated 20 A/240 V circuit plus ~10k BTU/h of heat.

## 4. Economics: break-even and payback

Revenue per card-hour if the card were 100% busy, counting **output tokens only** at $0.00000080 [M throughput × S price]:

| Workload | tok/s | Output tokens/hr | Revenue/hr at 100% busy |
|---|---|---|---|
| C=16, ~300 ctx | 1,043 | 3.75M | $3.00 |
| C=16, ~6k ctx | 503 | 1.81M | $1.45 |

Input tokens add more on top. At a 6k-context agent workload, each output token comes with ~20 prompt tokens, 89% cached. The blended input price is ~$0.000000076 per token, so input adds ~$1.50 per M output tokens and roughly doubles revenue per card-hour [A: input:output ratio from coding-agent traces, not yet measured on Frog Cloud]. The tables below leave that out to stay conservative.

**Break-even busy fraction** = cost per hour ÷ revenue per hour at 100% busy:

| | Cost/hr | Short ctx ($3.00) | 6k ctx ($1.45) | 6k ctx with input (~$2.90) |
|---|---|---|---|---|
| Rented RunPod 6000 | $2.49 | 83% | never (172%) | 86% |
| Owned, colo | ~$1.00 | 33% | 69% | 34% |
| Owned, home rack | ~$0.70 | 23% | 48% | 24% |

**Payback on $15k capex** = capex ÷ (revenue × busy fraction − cash opex):

| Busy fraction | Colo, 6k ctx, output only | Colo, 6k ctx, with input | Home, 6k ctx, with input |
|---|---|---|---|
| 40% (the brief's planning figure) | never ($0.58 − $0.50 → $0.08/hr) | 2.6 yr | 1.9 yr |
| 60% | 4.6 yr | 1.4 yr | 1.1 yr |
| 80% | 2.6 yr | 0.9 yr | 0.8 yr |

Read this as: **owning pays back inside the card's life only if we bill the input side and keep the card at least ~40% busy.** On output tokens alone at long context, even owned cards barely cover cost at market price. That is a pricing and engine problem as much as a hardware one. The C=16/6k number (503 tok/s) is the lever: doubling it does more for margin than any purchase.

For comparison, the brief's $2.07 per M output on rented hardware at C=16 and 40% busy sits under the ~$2.69 market all-in, so it's thin but positive. Owned in colo at 40% busy, it costs ~$0.67 per M output tokens at short context and ~$1.38 per M at 6k context [derived: $1.00/hr ÷ (0.4 × output tokens per hour)].

## 5. Burst capacity

Base load we own; peaks we rent. None of these need a commitment for on-demand.

| Provider | What they have for us | Notes | Tag |
|---|---|---|---|
| RunPod | 6000 at $2.49/hr; H200/B200 nodes | Our current home and the same image. **4–8 GPU nodes were out of stock all day on 2026-11-11.** Single cards are fine. | M |
| Shadeform | A marketplace across ~20 clouds; H200 seen from ~$2.45/hr | One API covers many suppliers. Best hedge against stock-outs. | S (price unclear) |
| Prime Intellect | An aggregator, similar to Shadeform | No published H200/B200 price found. | — |
| SF Compute | A spot/term market, from ~$1.82/hr | Cheapest for scheduled multi-hour blocks. Not instant. | S |
| Lambda | H200 ~$4.49/hr; B200 $4.99–6.69/hr | Reliable 8× nodes. Reserved clusters cost more per hour. | S |
| Nebius | H200 $5.40/hr (up from $4.50); B200 $5.50/hr | Good 8× availability, per-hour billing. | S |

H200 rental prices rose through 2026 (mean across 11 providers $5.95 → $6.06 per GPU-hour from August to November) [S]. Plan for burst getting more expensive, not cheaper.

Gateway work this implies (zest): route to more than one backend per model, and fail over when a provider has no stock. Shadeform + RunPod covers most of it.

## 6. Plan

**Phase 0: now (traffic ≈ 0.2 tok/s average).** Buy nothing.
- Keep the one rented 6000 (q6pluwjkklulmt) as prod. Measure how busy it is, broken out by concurrency and context, in the ledger.
- Put engineering time into throughput at long context (503 → 1,000 tok/s at C=16, 6k). Prefix cache and batching sessions are already on this.
- Bill input tokens properly. That decides whether owning ever pays back.
- DeepSeek, GLM: resell upstream.

**Phase 1: trigger is the rented 6000 ≥40% busy at C≥8 for 4 straight weeks** (≈1.3B coder-next output tokens a month, or ~$1,000 a month of output revenue).
- Buy **one 4-GPU RTX PRO 6000 server** (~$60k). Start it with 2 cards (~$37k), with slots for 2 more.
- **Put it in colo, not the office**: remote hands, redundant power, a real uplink. The extra ~$0.30/hr per card buys uptime that paying customers will notice.
- Keep RunPod as burst and failover. Drop the always-on rented pod once the owned box has run 2 weeks clean.
- Expected: base load at ~$1.00/hr per card instead of $2.49.

**Phase 2: trigger is the owned cards averaging ≥60% busy, or burst spend over ~$1,500 a month.**
- Fill the box to 4 cards, then add a second box in the same colo for redundancy.
- Rule of thumb: own enough cards to cover the **p30 hourly load**. Rent everything above it.

**Phase 3: trigger is DeepSeek-class self-hosted traffic above ~20k output tok/s sustained.**
- Re-run this doc for 8× H200 vs 4× B300 vs 8× 6000 over PCIe. At that point consider a 1-year reserved 8× node over buying (a ~$320k–540k ticket).

## 7. Risks

- **Demand risk (biggest).** All traffic today is internal. Hardware bought for demand that doesn't come costs ~$0.50/hr per card in cash even when idle, plus depreciation.
- **Price compression.** OpenRouter prices for open models fall several times a year. If coder-next output drops from $0.80 to $0.40 per M, every break-even in §4 doubles.
- **Model churn.** A successor model could need >96 GB, or prefer HBM. The 6000 is the most general card here, but this is still the risk that would strand a $320k H200 box.
- **Hardware prices.** The 6000 is up 30–90% over MSRP. Buying at the peak raises depreciation. If memory prices ease, used values fall too, so the 25% residual could be optimistic.
- **Supply.** Lead times run weeks, and RunPod multi-GPU nodes were out of stock today. Owning a base load is partly insurance against this.
- **Operations.** We have no hardware on-call today. Colo remote hands cost extra. A home rack is one breaker trip away from an outage.
- **Licensing.** GeForce cards (4090/5090) are out for paid serving. Keep to RTX PRO / data-center SKUs.
- **Measurement gaps.** Every throughput number is one card, one engine, synthetic prompts. Real traffic mixes and input:output ratios are unmeasured. Phase 0's ledger work closes this before any money is spent.

## Sources

Prices were read on 2026-11-11 and move fast. Re-check before buying.

- RTX PRO 6000 retail range and NVIDIA store price: [Digital Citizen](https://www.digitalcitizen.life/nvidia-rtx-pro-6000-blackwell-prices-climb-past-10000-as-ai-demand-keeps-rising/), [TweakTown $16k](https://www.tweaktown.com/news/113098/nvidias-rtx-pro-6000-blackwell-gpu-price-almost-doubles-reaching-16-000/index.html), [GPUPrix](https://gpuprix.com/us/gpus/rtx-pro-6000-blackwell), [Thunder Compute rental (Oct 2026)](https://www.thundercompute.com/blog/nvidia-rtx-pro-6000-pricing)
- H100/H200/B200/B300 purchase: [IntuitionLabs](https://intuitionlabs.ai/articles/nvidia-ai-gpu-pricing-guide), [Hyperbolic H200](https://www.hyperbolic.ai/blog/h200-price), [gpuperhour](https://gpuperhour.com/blog/nvidia-gpu-prices), [Thunder Compute B300](https://www.thundercompute.com/blog/nvidia-b300-pricing), [Spheron B300](https://www.spheron.network/blog/nvidia-b300-blackwell-ultra-guide/)
- L40S/5090/4090 and GeForce EULA: [PC Server & Parts](https://pcserverandparts.com/news/used-gpu-server-buying-guide-2026-l40s-vs-a100-vs-rtx-4090/), [getdeploying L40S vs 5090](https://getdeploying.com/gpus/nvidia-l40s-vs-nvidia-rtx-5090), [Novita H100/L40S](https://www.usagepricing.com/blueprint/activity/novita-ai-2026-08-26-h100-l40s-self-serve)
- Cloud rental: [Thunder Compute H200 (Nov 2026)](https://www.thundercompute.com/blog/nvidia-h200-pricing), [Spheron B200 cloud](https://www.spheron.network/blog/nvidia-b200-cloud-pricing-2026/), [Spheron comparison](https://spheron.network/blog/gpu-cloud-pricing-comparison-2026/), [computeprices Nebius vs Shadeform](https://computeprices.com/compare/nebius-vs-shadeform), [barrack.ai H200](https://blog.barrack.ai/h200-price/)
- Model prices: OpenRouter model pages for Qwen3-Coder-Next and DeepSeek V4.1 Flash, as given in the brief.

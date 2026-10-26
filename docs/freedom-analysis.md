# Model freedom, consumer demand, and the legal frontier

*Research memo for Municipal Robotics (muni), frog / frog cloud. Written 2026-10-26. This is not legal advice. Every item marked **needs a lawyer** is an open legal question that a qualified attorney should answer before we act on it.*

Cam's question: AI is new and the law hasn't caught up. How far can we push model freedom? Consumers want freedom (to root their Samsung device, say), and somebody used Claude for that and got shut down. Should frog cloud's planned "bull" tier serve an abliterated DeepSeek V4.1 Flash with a legality classifier on top?

## TL;DR

1. **The story is real, but it isn't quite what it sounds like.** In mid-October 2026, thousands of people used Claude Code to debloat their smart TVs, one of them a Samsung Tizen set. Then a Reddit user reported that Opus 5.5's guardrails blocked a TV reverse-engineering request while the same request for a video game went through. No account ban was reported. It was a real-time classifier block, and nobody has confirmed it ([XDA, Oct 26](https://www.xda-developers.com/users-report-that-anthropic-blocked-claude-from-reverse-engineering-tvs/); [GSMDome](https://www.gsmdome.com/reddit-user-says-claude-refused-smart-tv-reverse-engineering-request)). Anthropic's own written policy *allows* security work on systems you own ([Anthropic Usage Policy](https://www.anthropic.com/legal/aup)). The block came from a classifier that Anthropic itself calls "conservative," one that "block[s] most cyber work" ([Anthropic, Oct 6](https://www.anthropic.com/news/cyber-verification-program)). **The policy and the classifier disagree, and that is the lesson.**
2. **Very little is legally required of a model provider.** US law imposes no general duty to refuse. Aiding-and-abetting liability needs "conscious, voluntary, and culpable participation," and providing a generally available tool isn't that ([Twitter v. Taamneh](https://supreme.justia.com/cases/federal/us/598/21-1496/)). The hard requirements are few: CSAM reporting on actual knowledge ([18 U.S.C. §2258A](https://www.law.cornell.edu/uscode/text/18/2258A)), sanctions and export controls, EU AI Act transparency, and the EU's new bans on nudifier and CSAM systems. Most of what labs refuse is self-imposed.
3. **Product liability for model output is the live frontier.** One federal judge has declined, so far, to treat chatbot output as protected speech ([AP on Garcia v. Character Technologies](https://apnews.com/article/ai-lawsuit-suicide-artificial-intelligence-free-speech-ccc77a5ff5a84bda753d2b044c83d4b6)). Section 230's application to AI output is undecided ([Wikipedia, Section 230](https://en.wikipedia.org/wiki/Section_230)). **Needs a lawyer.**
4. **Cam's proposal as framed ("obliterated" plus a legality classifier) is the wrong shape.** The classifier would rebuild the exact failure that blocked the TV hacker. It would also create records of what we *knew*, which is the input courts use for culpability. Branding a tier "obliterated" is evidence of intent. And a fully abliterated general model produces adult content on request, which Stripe and RunPod both prohibit.
5. **The better shape is freedom by architecture.** Run local first (the user's own hardware). Keep a short, published list of hard lines that match master-plan values (no weapons, no surveillance, no CSAM, no attacks on systems you don't own or have authorization to test). Allow everything else. Let users attest ownership ("this is my device") instead of having us guess. Put safety in frog's approval cards (the agent's hands), not in censorship (its mouth). Refusals should be visible and appealable, and accounts should only be actioned for hard-line violations.
6. **Measure before we abliterate.** Open-weight coding models may already do adb, rooting and firmware work without complaint; the refusals people hit mostly come from *closed-API classifiers*. A small "freedom bench" settles that cheaply.

---

## 1. What actually happened (the news Cam saw)

| Date (2026) | Event | Source |
|---|---|---|
| Oct 17 | Gathin T. ([@gathint](https://x.com/gathint/status/2111379569030939102)) posts that Claude Code found his parents' Xiaomi TV on Wi-Fi, removed 25 packages and wrote an Apple TV-style launcher. "A few thousand people did the same to their own TVs over the next two days." His project is [cleanyourtv](https://github.com/Gathin23/cleanyourtv). | [TechCrunch, Oct 19](https://techcrunch.com/2026/10/19/people-are-using-ai-to-make-their-smart-tvs-dumb-again/) |
| Oct 17 | Ryan Doyle sends Claude Code his TV's listing, asks "Can you hack this?", and gets it debloated. | [TechCrunch](https://techcrunch.com/2026/10/19/people-are-using-ai-to-make-their-smart-tvs-dumb-again/), [X post](https://x.com/doooyle/status/2111196679680540724) |
| Oct 18 | [dumbtv](https://github.com/humblemuzzu/dumbtv) launches: "no root, nothing written to /system, every step reversible." Its author says he built it with **DeepSeek V4.1 Flash**, Claude Opus 5.5 and Sonnet 5.5. | [TechCrunch](https://techcrunch.com/2026/10/19/people-are-using-ai-to-make-their-smart-tvs-dumb-again/) |
| Oct 17–19 | Some users found Claude "wouldn't respond" to simple "hack my TV" prompts and needed more elaborate ones. One person bricked an Android TV. | [TechCrunch](https://techcrunch.com/2026/10/19/people-are-using-ai-to-make-their-smart-tvs-dumb-again/) |
| Oct 21 | Reddit user 0xVic points Claude at a **Samsung Tizen** TV (no ADB). Over about 11 hours, Claude builds a local page that uses the user's phone camera to photograph the TV every 4 s, replaces the home screen, and wipes the Samsung ad ID. | [XDA, Oct 21](https://www.xda-developers.com/someone-debloated-their-samsung-tizen-tv-by-pointing-a-camera-at-it-for-claude/) |
| Oct 26 | Reddit user reports that Opus 5.5 "hit a guardrail" on TV reverse-engineering while a video-game request went through. Unverified, a single account, and Anthropic hasn't commented. | [XDA, Oct 26](https://www.xda-developers.com/users-report-that-anthropic-blocked-claude-from-reverse-engineering-tvs/), [GSMDome](https://www.gsmdome.com/reddit-user-says-claude-refused-smart-tv-reverse-engineering-request), [r/ClaudeAI thread](https://www.reddit.com/r/ClaudeAI/comments/1xetxga/seems_like_anthropic_enabled_safeguards_around/) |

**Context that makes this a pattern, not a one-off:**

- **Classifiers on closed models are tuned to over-block.** Anthropic says its generally available models "have conservative cyber safeguards that block most cyber work," and that it is still working "to reduce false positives for secure coding." Fewer blocks are available through a vetted, tiered Cyber Verification Program (Defense / Red Team / Specialized), and that program *requires data retention* ([Anthropic, Oct 6](https://www.anthropic.com/news/cyber-verification-program)). When Opus 5.5 launched, most security tasks sent to it were routed to the older Opus 4.8 ([SiliconANGLE](https://siliconangle.com/2026/10/06/anthropic-folds-project-glasswing-into-an-expanded-three-tier-cyber-verification-program/)). Without CVP access, every one of 50 CyScenarioBench trials was blocked on the first prompt ([Anthropic](https://www.anthropic.com/news/cyber-verification-program)).
- **The written policy permits what the classifier blocked.** Anthropic's Usage Policy bans unauthorized intrusion, but it says the section "does not prohibit security research, testing, or tool development conducted on systems you own or operate" ([Anthropic AUP](https://www.anthropic.com/legal/aup)). Debloating your own TV falls in that permitted zone. The classifier can't see who owns the TV.
- **Bans happen at enormous scale, and appeals rarely win.** Anthropic banned **11.4 million accounts** in January–June 2026. It received 398k appeals and overturned 42k of those decisions, about 10.6% of appeals ([Anthropic Transparency Hub](https://www.anthropic.com/transparency/system-trust-reporting)). An October wave of "suddenly banned" posts on X included a Max subscriber suspended after four days with no reason given, and a report that a Claude Code session behind a local proxy drew a suspension email within seconds ([note.com roundup](https://note.com/daikidomon/n/n5e309697c821?hl=en), citing [X](https://x.com/AgwntV/status/2109642680212795785) and [X](https://x.com/alexgetmancom/status/2086131953607049275)). Those are individual, unverified claims.
- **The rules keep tightening.** Anthropic's October usage-policy update expanded its weapons, surveillance and hardware rules ([Anthropic](https://www.anthropic.com/news/2026-usage-policy-update); [The Verge](https://www.theverge.com/ai-artificial-intelligence/1008100/anthropic-new-usage-policy-abuse-claude)).

**Demand signal.** Thousands of TVs were debloated within days, and the projects were explicitly about ads and tracking (ACR) ([TechCrunch](https://techcrunch.com/2026/10/19/people-are-using-ai-to-make-their-smart-tvs-dumb-again/)). Gaming outlets report AI-assisted decompiles and ports ([XDA](https://www.xda-developers.com/people-are-now-vibe-coding-their-smart-tvs-to-strip-them-of-ads-and-unwanted-features/)). XDA's own conclusion is that closed-model blocks "push people toward using LLMs from other vendors, or even open-source ones" ([XDA](https://www.xda-developers.com/users-report-that-anthropic-blocked-claude-from-reverse-engineering-tvs/)). That's our market.

---

## 2. What the law requires vs. what labs choose

### 2.1 United States

**Is the act itself legal? Usually yes, but the details matter.**

- **DMCA §1201 (anti-circumvention).** Circumventing access controls on copyrighted software is unlawful unless an exemption applies ([17 U.S.C. §1201](https://www.law.cornell.edu/uscode/text/17/1201)). The 2024 triennial rule ([Copyright Office](https://www.copyright.gov/1201/2024/); [final rule](https://www.govinfo.gov/content/pkg/FR-2024-10-28/pdf/2024-24563.pdf)) exempts several device categories ([37 C.F.R. §201.40](https://www.law.cornell.edu/cfr/text/37/201.40)):
  - smartphones and portable computing devices, for interoperability **"or to permit removal of software"** (b)(9);
  - **smart TVs**, for interoperability of lawfully obtained apps (b)(10);
  - voice assistants (b)(11);
  - routers and dedicated network devices (b)(12).

  Exemptions last three years, so the current set expires with the next triennial cycle ([Copyright Office](https://www.copyright.gov/1201/2024/)). Separately, §1201(f) permits circumvention for software interoperability ([LII](https://www.law.cornell.edu/uscode/text/17/1201)).
  - *Nuance 1:* the smart-TV exemption's text says nothing about "removal of software," which the smartphone exemption does. Debloating a TV by circumventing its protections may fall outside the exemption's letter. **Needs a lawyer.**
  - *Nuance 2:* debloating over **ADB with no circumvention** (dumbtv's "no root" approach) uses a developer feature the vendor ships, so it likely isn't circumvention at all ([dumbtv](https://github.com/humblemuzzu/dumbtv)). **Needs a lawyer** to confirm.
  - *Nuance 3, which matters most for us:* exemptions cover the user's *act* of circumvention under §1201(a)(1). They do **not** cover the separate bans on *trafficking* in circumvention tools under §1201(a)(2) and (b) ([LII](https://www.law.cornell.edu/uscode/text/17/1201)). Could a hosted model that writes a bespoke circumvention tool for one user count as "providing" or "trafficking"? Nobody knows. **Needs a lawyer.** This is the single most relevant open legal question for a "root anything" tier.
- **CFAA.** After *Van Buren*, "without authorization" is a "gates-up-or-down" question about access, not about purpose restrictions in contracts ([Van Buren v. United States](https://supreme.justia.com/cases/federal/us/593/19-783/)). Hacking a device you own is very unlikely to be a CFAA crime. Hacking someone else's is the clear line.

**Is the provider liable when a user misuses the model?**

- **Aiding and abetting.** The Supreme Court requires "knowing and substantial assistance" that amounts to "conscious, voluntary, and culpable participation." Supplying "generally available" services at "arm's length" isn't enough, even when you know some bad actors use them ([Twitter v. Taamneh, 2023](https://supreme.justia.com/cases/federal/us/598/21-1496/)). In 2025 a unanimous Court applied similar reasoning to gun makers: knowing that some products get misused does not establish aiding and abetting ([Smith & Wesson v. Mexico](https://en.wikipedia.org/wiki/Smith_%26_Wesson_Brands,_Inc._v._Estados_Unidos_Mexicanos)). For a general-purpose coding agent, this is our strongest legal footing. Note the flip side: the standard turns on knowledge, intent and *affirmative misconduct*, so marketing and monitoring choices matter (see §4).
- **Section 230.** Whether §230 protects generative output "has yet to be determined in case law." Its authors, Cox and Wyden, have said they don't think it does ([Wikipedia](https://en.wikipedia.org/wiki/Section_230); [CRS, Section 230 and Generative AI](https://www.congress.gov/crs_external_products/LSB/PDF/LSB11097/LSB11097.3.pdf)). Assume it doesn't protect us. **Needs a lawyer.**
- **Product liability / negligence.** In *Garcia v. Character Technologies*, the judge was "not prepared" to hold that chatbot output is speech "at this stage," and let wrongful-death claims proceed ([AP](https://apnews.com/article/ai-lawsuit-suicide-artificial-intelligence-free-speech-ccc77a5ff5a84bda753d2b044c83d4b6)). The case settled in January 2026, and state attorneys general have since sued Character.AI on consumer-protection grounds ([Wikipedia](https://en.wikipedia.org/wiki/Character.ai)). That line of cases involves consumer chat and minors, not developer tools. Still, it shows that "we're just a tool" is not a settled defense when a *design choice* is the alleged defect. Removing safety training on purpose is a design choice. **Needs a lawyer.**

**What is actually mandated?**

- **CSAM reporting.** Providers must report to NCMEC "as soon as reasonably possible after obtaining actual knowledge." Fines for knowing and willful failure reach $600k–$1M. The statute expressly does **not** require monitoring users or content ([18 U.S.C. §2258A(a), (e), (f)](https://www.law.cornell.edu/uscode/text/18/2258A)). Anthropic filed 15,079 NCMEC reports in H1 2026, most of them through image hash-matching ([Anthropic Transparency Hub](https://www.anthropic.com/transparency/system-trust-reporting)). frog cloud is text-only today, which narrows this, but it does not remove it.
- **Sanctions and export controls.** These are mandatory in practice, and our vendors pass them through to us ([RunPod ToS](https://www.runpod.io/legal/terms-of-service)).
- **Frontier-model laws mostly don't reach us.** California SB 53 applies to models trained with more than 10^26 FLOPs (fine-tuning included), and most of its duties apply only to developers with $500M+ revenue ([Wikipedia, SB 53](https://en.wikipedia.org/wiki/Transparency_in_Frontier_Artificial_Intelligence_Act)). We don't train frontier models.
- **State AI law is retreating under federal pressure.** Executive Order 14365 (December 2025) created a DOJ AI Litigation Task Force to challenge state AI laws. DOJ intervened in *xAI v. Weiser* against Colorado's AI Act. Enforcement was stayed, and Colorado replaced the law with a narrower SB 189 effective January 1, 2027 ([Tech Times](https://www.techtimes.com/articles/318956/20260623/colorado-ai-law-hits-june-30-deadline-without-bias-audits-here-what-consumers-keep.htm), which links the [EO](https://www.whitehouse.gov/presidential-actions/2025/12/eliminating-state-law-obstruction-of-national-artificial-intelligence-policy/)). Twenty-six attorneys general are pushing Congress to preserve state authority ([JD Supra](https://www.jdsupra.com/legalnews/26-state-ags-urge-congress-to-regulate-2874492/)). The direction in late 2026 is fewer US obligations, but it is contested and moving.
- **ToS are enforceable if shown properly.** Courts enforce clickwrap terms when a reasonable user is on notice ([Meyer v. Uber, 2d Cir. 2017](https://cases.justia.com/federal/appellate-courts/ca2/16-2750/16-2750-2017-08-17.pdf); [Wikipedia, Clickwrap](https://en.wikipedia.org/wiki/Clickwrap)). So a user's sign-up attestation ("I own or am authorized to modify the devices and systems I work on") is worth having. It shifts responsibility to the user, and it is evidence that we lack culpable intent. **Needs a lawyer** to draft.

### 2.2 European Union

- **AI Act timeline after the Digital Omnibus** (Regulation (EU) 2026/1744, in force July 27, 2026):
  - Prohibited practices have applied since February 2025.
  - General-purpose AI (GPAI) obligations have applied since August 2025, with Commission fining powers from August 2, 2026.
  - Article 50 transparency rules (disclose that it's AI; mark synthetic content) have been enforceable since August 2, 2026.
  - High-risk obligations slipped to December 2027 or August 2028.
  - The Omnibus adds **prohibitions from December 2, 2026 on systems that generate non-consensual intimate imagery or CSAM**, after Grok generated about 3 million sexualized images in 11 days.

  All of this is per [Tech Times, Jul 10](https://www.techtimes.com/articles/320101/20260710/eu-ai-act-enforcement-here-chatbot-rules-live-high-risk-ai-delay-now-binding-law.htm).
- **Who is the "provider"?** Offering access through an API counts as placing the GPAI model on the market. A downstream modifier becomes the GPAI *model* provider only if its modification significantly changes the model's generality, capabilities **or systemic risk**. The indicative rule of thumb is modification compute above one-third of the original training compute. Models above 10^25 FLOPs are presumed to carry systemic risk ([CMS, summarizing the Commission's July 2025 guidelines](https://cms.law/en/swe/legal-updates/general-purpose-ai-models-obligations-and-roles-for-providers-and-downstream-modifiers-under-the-eu-ai-act)).
  - Abliteration uses almost no compute, so on the compute test we would stay a mere *system* provider.
  - But the materiality test names "systemic risk" separately. Deliberately removing refusals from a likely-systemic-risk model is arguably exactly the change that test targets. **Needs a lawyer.** This is the EU's sharpest edge against the proposal.
- **Interoperability.** EU software law permits decompilation for interoperability ([Directive 2009/24/EC, Art. 6](https://eur-lex.europa.eu/legal-content/EN/TXT/?uri=CELEX:32009L0024)). Anti-circumvention law differs by member state. **Needs a lawyer** before we market device-modding to EU users.

### 2.3 Required vs. self-imposed

| Constraint | Required by law? | Imposed by |
|---|---|---|
| Never generate CSAM; report on actual knowledge | **Yes** (US §2258A; EU prohibition from Dec 2, 2026) | Law |
| Sanctions / export controls | **Yes** | Law, enforced by vendors |
| EU: disclose AI interaction; GPAI documentation flows | **Yes** (AI Act Art. 50, Art. 53) | Law |
| Don't knowingly and substantially assist a specific wrong | **Yes**, but the bar is high (*Taamneh*) | Law |
| Don't design or market for unlawful use | Indirectly: it is evidence of intent and defect | Law (via tort) |
| Block "most cyber work" for unverified users | No | Anthropic's choice |
| Refuse to help modify a device the user owns | No (subject to the §1201 nuances above) | Lab choice |
| Ban without stated reasons, with ~10% of appeals winning | No | Lab choice |
| Retain prompts to monitor misuse | No (§2258A(f): no duty to monitor) | Lab choice; required for Anthropic's CVP |

**Answer to "how far can we push?"** Legally, far. The binding constraints are the narrow mandatory items above, plus the *evidence* we create about intent (marketing, design, logs). The tighter constraints are **commercial**: payment processors and hosting vendors (§4.2).

---

## 3. The freedom spectrum today

| Approach | Example | What users get | Posture |
|---|---|---|---|
| Closed model, conservative classifiers, vetted tiers | Anthropic GA models plus CVP | Strong models. Cyber and device work is often blocked unless the user is vetted and accepts data retention ([Anthropic](https://www.anthropic.com/news/cyber-verification-program)) | Maximum caution. 11.4M bans in six months ([Anthropic](https://www.anthropic.com/transparency/system-trust-reporting)) |
| Hosted "private, uncensored" aggregator | Venice.ai | Chat history stays on the device; requests relayed "without being stored" ([Venice privacy](https://venice.ai/privacy)) | The ToS disclaims outputs entirely ("Output is generated and provided by the third-party providers… and not Venice.ai"). It still bans illegal use and CSAM, and reserves the right to block anything ([Venice ToS §2, §10.10, §12](https://venice.ai/legal/tos)) |
| Abliterated open weights | `huihui-ai/Huihui-DeepSeek-V4-Flash-0731-abliterated-GGUF` (~356k downloads) and many Qwen variants with millions of downloads ([HF search](https://huggingface.co/api/models?search=abliterated&sort=downloads&limit=15)) | Refusals removed; runs anywhere | Its own model card advises "avoiding direct use in production or public-facing commercial applications" and puts all responsibility on users ([model card](https://huggingface.co/huihui-ai/Huihui-DeepSeek-V4-Flash-0731-abliterated-GGUF)) |
| Stock open weights, run locally | DeepSeek V4.1 Flash (MIT license) ([HF](https://huggingface.co/api/models?search=DeepSeek-V4&author=deepseek-ai&limit=20)); Qwen through frog `local/` | Whatever the model does; no account to ban | The user is the operator. The vendor sees nothing |

**How abliteration works.** Refusal in chat models "is mediated by a one-dimensional subspace." Erasing that direction "surgically disables refusal with minimal effect on other capabilities" ([Arditi et al., 2024](https://arxiv.org/abs/2406.11717)). It's cheap, and it has already been done to DeepSeek V4 Flash. We wouldn't be building anything; we'd be choosing to *serve* it under our name.

---

## 4. Evaluating "bull = DeepSeek V4.1 Flash obliterated + legality classifier"

### 4.1 What's right about it

- The demand is real (§1), and it is exactly where frontier labs are visibly weakest.
- DeepSeek V4.1 Flash is MIT-licensed ([HF](https://huggingface.co/api/models?search=DeepSeek-V4&author=deepseek-ai&limit=20)), and dumbtv's author used it ([TechCrunch](https://techcrunch.com/2026/10/19/people-are-using-ai-to-make-their-smart-tvs-dumb-again/)).
- It fits master-plan principle 7 ("everything that can be open is open").

### 4.2 Problems, ranked

**1. A "legality classifier" rebuilds Anthropic's failure.**
- Legality turns on facts a classifier can't see: who owns the device, whether testing was authorized, which jurisdiction applies, and whether anything is circumvented at all (ADB vs. an exploit).
- Anthropic's classifier blocked TV work that its own policy permits ([AUP](https://www.anthropic.com/legal/aup) vs. [XDA](https://www.xda-developers.com/users-report-that-anthropic-blocked-claude-from-reverse-engineering-tvs/)).
- Over-refusal is a measured, persistent failure across 32 LLMs ([OR-Bench, ICML 2025](https://arxiv.org/abs/2405.20947)). A *legality* classifier is a harder version of the problem: it has to predict law, not tone.
- Developer work (adb, `fastboot flashing unlock`, Frida, firmware dumps, `iptables`, `sudo`) is dense with surface triggers. Every false positive is the October TechCrunch story with our name on it.

**2. A classifier that logs creates "knowledge."**
- *Taamneh* turns on knowing, culpable participation ([Justia](https://supreme.justia.com/cases/federal/us/598/21-1496/)), and §2258A turns on "actual knowledge" ([LII](https://www.law.cornell.edu/uscode/text/18/2258A)).
- An advisory classifier leaves us holding records of flagged requests that we then *served*. A blocking classifier makes us adjudicators of legality.
- Either way, we arguably end up more exposed than a no-log tool that doesn't monitor, and the law doesn't require monitoring (§2258A(f)). **Needs a lawyer.** The intuition still stands: half-monitoring is the worst of both worlds.

**3. The name "obliterated" is evidence against us.**
- Aiding-and-abetting and product-defect analyses both look at intent and design ([Taamneh](https://supreme.justia.com/cases/federal/us/598/21-1496/); [Garcia via AP](https://apnews.com/article/ai-lawsuit-suicide-artificial-intelligence-free-speech-ccc77a5ff5a84bda753d2b044c83d4b6)).
- A tier marketed as "safety removed" reads to a court, a reporter or a payment processor as a product built for what others refuse. Grok showed how fast that becomes regulation ([Tech Times](https://www.techtimes.com/articles/320101/20260710/eu-ai-act-enforcement-here-chatbot-rules-live-high-risk-ai-delay-now-binding-law.htm)).
- "Works on your own stuff" sells the same freedom without the confession.

**4. Vendor ToS put the whole company at risk, not just the tier.**
- **Stripe** prohibits pornography "and other mature audience content… designed for the purpose of sexual gratification," including "[a]ny artificial-intelligence generated content that meets the above criteria." It also prohibits services that "facilitate infringement" ([Stripe restricted businesses](https://stripe.com/legal/restricted-businesses)). An abliterated *general* model writes erotica on request. Losing Stripe kills Pro/Max billing for every frog cloud customer.
- **RunPod** bars "pornography or graphic adult content" and illegal content, with "immediate termination… and a lifetime ban." It also requires compliance with Delaware law and the user's local law ([RunPod ToS](https://www.runpod.io/legal/terms-of-service)). Whether model *output* counts as "Content submitted to the Service" is ambiguous. **Needs a lawyer**, or ask RunPod in writing.
- **Cloudflare** (our gateway) bars unlawful content, malware distribution and "technical abuse," and can suspend immediately for breaches ([Cloudflare Self-Serve Subscription Agreement §2.7, §8](https://www.cloudflare.com/terms/)).
- Net: an unfiltered hosted tier needs either separate billing and infrastructure, or a filter on *these specific categories* (sexual content, malware distribution). A category filter is far narrower, and far easier to get right, than a "legality" classifier.

**5. "DeepSeek" is now a procurement liability.**
- DHS ordered federal civilian agencies to remove DeepSeek products, "including third-party products and services developed using DeepSeek" models, under FASCSA ([WinBuzzer](https://winbuzzer.com/2026/10/20/us-civilian-agencies-must-remove-deepseek-based-ai-xcxwbn/); [Federal Register filing](https://public-inspection.federalregister.gov/2026-21447.pdf)).
- At least eight governments restrict DeepSeek ([MSN](https://www.msn.com/en-in/news/other/from-rome-to-washington-why-governments-are-pulling-deepseek-off-official-systems/ar-AA2fENvp)).
- Self-hosting the weights avoids sending data to China, but enterprise buyers will screen by model lineage. "DeepSeek, obliterated" stacks two red flags. **Needs a lawyer** on FASCSA reach for any customers who are federal contractors.

**6. EU systemic-risk exposure** (§2.2). Taking a likely 10^25+ FLOP model, deliberately removing its safety training, and serving it to EU users by API is the scenario the "significant change in systemic risk" test exists for. **Needs a lawyer.** The cheap mitigation is to not serve abliterated variants in the EU.

**7. It may not be needed.**
- dumbtv was built partly on *stock* DeepSeek V4.1 Flash ([TechCrunch](https://techcrunch.com/2026/10/19/people-are-using-ai-to-make-their-smart-tvs-dumb-again/)), and the refusals in the news came from closed-API classifiers, not open weights.
- Abliteration's capability cost ("minimal" on the models Arditi et al. tested; [arXiv](https://arxiv.org/abs/2406.11717)) still has to be measured on *our* agentic-coding evals.
- If stock open models already do the dev-freedom tasks, abliteration only adds the content categories that get us de-platformed (problem 4).

### 4.3 Verdict

Right goal, wrong mechanism. Serve **stock open weights** under a **short, published hard-line policy** with **owner attestation**. Use narrow category filters only where law or vendors force them (CSAM, sexual content on Stripe-billed tiers, malware distribution). Build no server-side legality classifier, and don't use "obliterated" anywhere. Abliterated weights, if offered at all, are **local-only**.

---

## 5. Alternatives, built for what frog is

### 5.1 Freedom by architecture: local first

frog already runs `local/<model>` on the bundled `tang-llm` sidecar, as well as ollama, LM Studio, llama.cpp and vLLM ([docs/reference.md](reference.md)). The Orin head is planned as a light/offline frog node (muni product notes).

When the model runs on the user's hardware, we see no prompts, hold no logs, and make no per-request decisions. That is the cleanest form of the *Taamneh* "generally available" posture and the §2258A "no duty to monitor" posture.

Two caveats:
- *Shipping* a de-safetied model preinstalled on hardware we sell is still placing a product on the market, and still a design choice. **Needs a lawyer.**
- Ship stock weights by default, and let users pull variants themselves.

### 5.2 A short, published hard-line list

These are ours, rooted in the master plan, and enforced only on clear cases:
1. Sexual content involving minors (law).
2. Weapons development (master plan: "no weapons or military sales").
3. Tracking or surveilling people without consent (master plan: "never be Flock Safety").
4. Attacking systems you don't own or aren't authorized to test. This tracks the CFAA and Anthropic's own carve-out ([AUP](https://www.anthropic.com/legal/aup)), but is enforced on facts the user states, not on a classifier's guess.
5. Building malware or ransomware to deploy against others.

Everything else is allowed. The terms should say so explicitly: rooting, jailbreaking and debloating your own devices; reverse engineering for interoperability; CTFs; and pentesting your own lab. That is a stronger line than "uncensored," and a safer one.

### 5.3 Owner attestation instead of guessing

- Add a project-level policy file (say `.frog/policy.toml`) or a first-use card where the user declares scope: "devices on 192.168.1.0/24 are mine," "this APK is my app," "authorized pentest of host X under engagement Y."
- frog injects that scope into context, and the model works confidently inside it.
- This is Anthropic's "systems you own or operate" carve-out with the user supplying the missing fact.
- Pair it with a clickwrap representation at sign-up ([Meyer v. Uber](https://cases.justia.com/federal/appellate-courts/ca2/16-2750/16-2750-2017-08-17.pdf)). A false attestation is then the user's misconduct. **Needs a lawyer** for the wording.

### 5.4 Visible refusals, appeals, and no silent bans

- When frog cloud declines, it names the hard line and links the policy.
- No bans on a classifier score alone: only on human-reviewed hard-line violations, and with a stated reason.
- Publish counts the way Anthropic does ([Transparency Hub](https://www.anthropic.com/transparency/system-trust-reporting)). Anthropic's ~10.6% appeal-overturn rate is a number we can beat publicly.

### 5.5 Zero retention as a product choice

Zero retention by default, like Venice's proxy model ([Venice](https://venice.ai/privacy)), is privacy-first, and it avoids the knowledge trap in §4.2(2). The cost is that we can't investigate after the fact. That's acceptable when hard lines are few, and when account-level levers (payment fraud, sanctions screening) carry most enforcement. **Needs a lawyer** on how this interacts with §2258A and the EU's AI Act duties.

### 5.6 Jurisdiction-aware serving

Serve one model with per-region wrappers:
- **EU:** add the Article 50 AI disclosure and pass through the GPAI documentation. Don't offer abliterated variants.
- **Sanctioned regions:** blocked (required).
- **US and elsewhere:** stock models plus attestation.

### 5.7 Safety at the agent's hands, not its mouth

frog's control plane already *is* the freedom-preserving safety layer:
- **Permission modes** run `default` → `accept-edits` → `auto` → `yolo` (`crates/frog-engine/src/protocol.rs`).
- **Auto mode rules.** In `auto`, deterministic rules "can't be talked out of": privilege escalation, history rewrites, force pushes and publishing, piping downloads into a shell, and writes outside the project always ask the user.
- **Auto mode classifier.** A small *local* classifier judges the remaining calls "against the user's recent requests," and agent-supplied arguments are marked untrusted (`crates/frog-engine/src/auto.rs`).
- **Quarantine.** MCP tools that look like prompt injection are quarantined (`docs/quarantine.md`).

That is where a classifier belongs. It protects the **user** from the agent: one TechCrunch user bricked a TV ([TechCrunch](https://techcrunch.com/2026/10/19/people-are-using-ai-to-make-their-smart-tvs-dumb-again/)). It runs on the user's machine, and the user can override it. A server-side legality classifier does the opposite: it protects the **provider** from the user, and no one can override it.

The better "bull" feature is device-modding guardrails in auto mode, in the spirit of dumbtv's "every step reversible with one script" ([dumbtv](https://github.com/humblemuzzu/dumbtv)):
- back up before touching the device;
- prefer reversible changes (disable, don't uninstall);
- show an approval card before any flash or bootloader operation;
- generate a restore script every time.

### 5.8 Positioning

"The coding agent that works on your stuff." The launch demo: debloat a TV with backup, reversible steps and a restore script, on a local or stock open model. It lines up with right-to-repair (the §1201 exemptions exist because the Copyright Office found the ban harmed non-infringing uses; [Copyright Office](https://www.copyright.gov/1201/2024/)), and with the master plan's openness and privacy principles.

---

## 6. Recommendation

The stages below are ordered by dependency. Per Cam's rule, only launches get dates, so there are none here.

**Stage A: now, and cheap**
1. Publish a frog cloud usage policy: the five hard lines (§5.2), plus an explicit allow-list for own-device and authorized work.
2. Commit in writing: no classifier-only bans, refusals that name the rule, and a human-reviewed appeal.
3. Add an owner/authorization representation to sign-up (**needs a lawyer**).
4. Keep frog cloud on stock Qwen3-Coder-Next, with no legality classifier.

**Stage B: before bull ships**
1. Build a **freedom bench**:
   - about 200 legitimate-but-scary dev tasks: adb debloat, bootloader unlock on your own phone, Frida on your own APK, dumping your own router's firmware, Tizen developer mode, CTF binaries, home-lab pentest, iptables and sudo-heavy sysadmin;
   - about 50 clear hard-line violations;
   - scored on refusal rate and task success for stock Qwen3-Coder-Next, stock DeepSeek V4.1 Flash, and an abliterated variant.
2. If a stock model clears about 95% of the legitimate set and refuses the violations, then **bull = that stock model + owner attestation + device guardrails**. No abliteration.
3. Take the §7 questions to a lawyer, starting with §1201 trafficking and EU systemic risk.
4. Ask RunPod and Stripe in writing whether "permissive coding model, sexual content filtered" fits their terms.
5. Market bull by capability, not by lineage (§4.2.5).

**Stage C: later**
1. Offer abliterated or uncensored weights **local-only** (frog `local/`, the Orin head), behind a clear "you are the operator" screen, and never preinstalled by default.
2. Ship the device-modding guardrails (§5.7).
3. Publish transparency numbers once there's volume.

**What not to do**
- Don't use "obliterated," "jailbroken" or "no guardrails" anywhere in product or marketing copy.
- Don't build a server-side legality classifier that blocks or bans.
- Don't serve a fully uncensored general model on Stripe-billed, RunPod-hosted infrastructure.
- Don't serve abliterated variants into the EU without legal sign-off.
- Don't log flagged prompts "just in case." Either don't monitor, or monitor narrowly under a written policy.
- Don't sell exceptions to the hard lines. The master plan's safety commitments "carry to any acquirer," so they shouldn't be for sale to customers either.
- Don't assume Section 230 covers model output.

### 6.1 Should muni seek grant money for the research layer?

**Market signal.** Funder-matching services now treat cash, cloud credits, GPU hours and API credits as interchangeable needs for independent labs ([Open Research Fund](https://www.openresearchfund.com/)). That supports the consumer-freedom thesis: for unfunded developers, frontier access is a budget problem as much as a policy problem. frog's free local path and cheap cloud tiers answer it directly.

**Fit is poor for the obvious targets:**
- **Schmidt Sciences, Science of Trustworthy AI ($5M on that index).** The 2026 agenda explicitly excludes "model safeguards (e.g., I/O filtering, constitutional classifiers)," "policy and AI governance," "jailbreak discovery," and "near-term product engineering" ([Schmidt Sciences](https://www.schmidtsciences.org/research-agenda/trustworthy-ai-research-agenda/)). A legality classifier is out of scope by name, and §4 recommends against building one anyway. The only plausible fit is §2.1, "science of evaluation": an open over-refusal benchmark with construct and predictive validity (the freedom bench). Our eligibility as a for-profit is unconfirmed.
- **SFF.** Funded by Jaan Tallinn. Theme rounds accept for-profits, but the 2026 main-round application closed April 22 ([SFF-2026](https://survivalandflourishing.fund/2026/application)). The index's "rolling" label points at the rolling application form, not an open round.
- **Open Philanthropy, now Coefficient Giving** ([Coefficient Giving](https://coefficientgiving.org/)). Its global-catastrophic-risk grants fit a "reduce refusals" agenda poorly.

**Recommendation.**
- Don't pursue grants now. Capital strategy is undecided in the master plan, and these funders' priorities lean toward *more* restriction. That is a slow-burn string on our hard lines.
- If we pursue one later, it should be narrow and no-strings: a grant for the **open, published freedom bench** (data, code and results public; no data-retention or monitoring conditions; no say over product policy). Apply through an academic partner if for-profit eligibility blocks us.
- Walk away from any term that touches user data, adds monitoring, or gives the funder input on who we serve. That's the "never be Flock Safety" test.

---

## 7. Needs a lawyer (consolidated)

1. **§1201 trafficking.** Could a hosted model that writes a bespoke circumvention tool for one user count as "providing" or "trafficking" under §1201(a)(2) or (b), even when the user's own circumvention is exempt?
2. **Smart-TV exemption scope.** Does 37 C.F.R. §201.40(b)(10) cover *removing* vendor software, or only running apps? Is ADB-based debloating circumvention at all?
3. **Output liability.** What's our exposure under Section 230 and product liability? Is deliberately removing safety training a design defect?
4. **Monitoring vs. knowledge.** Does a logging content classifier raise our aiding-and-abetting or §2258A exposure compared with zero retention?
5. **EU AI Act.** Does serving an abliterated, likely-systemic-risk GPAI model make us its "provider" under the materiality test? What do we owe as a system provider either way?
6. **EU member-state law.** How do national anti-circumvention rules treat device-modding features marketed to EU users?
7. **Vendor terms.** Does model *output* count as "Content" under RunPod's and Stripe's terms, and what filter scope satisfies them?
8. **FASCSA.** Does the DHS DeepSeek order reach our customers who are federal contractors?
9. **Attestation.** Enforceable wording for the ownership and authorization representation.
10. **Hardware.** Liability and EU placing-on-market implications of models preinstalled on the Orin head.

---

## Sources

**Incident:** [TechCrunch, Oct 19](https://techcrunch.com/2026/10/19/people-are-using-ai-to-make-their-smart-tvs-dumb-again/) · [XDA, Oct 19](https://www.xda-developers.com/people-are-now-vibe-coding-their-smart-tvs-to-strip-them-of-ads-and-unwanted-features/) · [XDA, Oct 21](https://www.xda-developers.com/someone-debloated-their-samsung-tizen-tv-by-pointing-a-camera-at-it-for-claude/) · [XDA, Oct 26](https://www.xda-developers.com/users-report-that-anthropic-blocked-claude-from-reverse-engineering-tvs/) · [GSMDome](https://www.gsmdome.com/reddit-user-says-claude-refused-smart-tv-reverse-engineering-request) · [r/ClaudeAI](https://www.reddit.com/r/ClaudeAI/comments/1xetxga/seems_like_anthropic_enabled_safeguards_around/) · [dumbtv](https://github.com/humblemuzzu/dumbtv) · [cleanyourtv](https://github.com/Gathin23/cleanyourtv) · [note.com ban roundup](https://note.com/daikidomon/n/n5e309697c821?hl=en)

**Anthropic:** [Usage Policy](https://www.anthropic.com/legal/aup) · [Cyber Verification Program](https://www.anthropic.com/news/cyber-verification-program) · [2026 Usage Policy update](https://www.anthropic.com/news/2026-usage-policy-update) · [Transparency Hub](https://www.anthropic.com/transparency/system-trust-reporting) · [Safeguards warnings and appeals](https://support.claude.com/en/articles/8241253-safeguard-warnings-and-appeals) · [SiliconANGLE](https://siliconangle.com/2026/10/06/anthropic-folds-project-glasswing-into-an-expanded-three-tier-cyber-verification-program/) · [The Verge](https://www.theverge.com/ai-artificial-intelligence/1008100/anthropic-new-usage-policy-abuse-claude)

**US law:** [17 U.S.C. §1201](https://www.law.cornell.edu/uscode/text/17/1201) · [37 C.F.R. §201.40](https://www.law.cornell.edu/cfr/text/37/201.40) · [Copyright Office 2024 cycle](https://www.copyright.gov/1201/2024/) · [Van Buren](https://supreme.justia.com/cases/federal/us/593/19-783/) · [Twitter v. Taamneh](https://supreme.justia.com/cases/federal/us/598/21-1496/) · [Smith & Wesson v. Mexico](https://en.wikipedia.org/wiki/Smith_%26_Wesson_Brands,_Inc._v._Estados_Unidos_Mexicanos) · [18 U.S.C. §2258A](https://www.law.cornell.edu/uscode/text/18/2258A) · [Section 230](https://en.wikipedia.org/wiki/Section_230) · [CRS on §230 and generative AI](https://www.congress.gov/crs_external_products/LSB/PDF/LSB11097/LSB11097.3.pdf) · [AP on Garcia](https://apnews.com/article/ai-lawsuit-suicide-artificial-intelligence-free-speech-ccc77a5ff5a84bda753d2b044c83d4b6) · [Character.ai litigation](https://en.wikipedia.org/wiki/Character.ai) · [SB 53](https://en.wikipedia.org/wiki/Transparency_in_Frontier_Artificial_Intelligence_Act) · [Colorado and EO 14365](https://www.techtimes.com/articles/318956/20260623/colorado-ai-law-hits-june-30-deadline-without-bias-audits-here-what-consumers-keep.htm) · [26 AGs](https://www.jdsupra.com/legalnews/26-state-ags-urge-congress-to-regulate-2874492/) · [Meyer v. Uber](https://cases.justia.com/federal/appellate-courts/ca2/16-2750/16-2750-2017-08-17.pdf) · [Clickwrap](https://en.wikipedia.org/wiki/Clickwrap)

**EU law:** [AI Act and Omnibus timeline](https://www.techtimes.com/articles/320101/20260710/eu-ai-act-enforcement-here-chatbot-rules-live-high-risk-ai-delay-now-binding-law.htm) · [CMS on downstream modifiers](https://cms.law/en/swe/legal-updates/general-purpose-ai-models-obligations-and-roles-for-providers-and-downstream-modifiers-under-the-eu-ai-act) · [Directive 2009/24/EC](https://eur-lex.europa.eu/legal-content/EN/TXT/?uri=CELEX:32009L0024)

**Models and vendors:** [Arditi et al., refusal direction](https://arxiv.org/abs/2406.11717) · [OR-Bench](https://arxiv.org/abs/2405.20947) · [DeepSeek V4.x on HF](https://huggingface.co/api/models?search=DeepSeek-V4&author=deepseek-ai&limit=20) · [abliterated models on HF](https://huggingface.co/api/models?search=abliterated&sort=downloads&limit=15) · [huihui DeepSeek V4 Flash abliterated](https://huggingface.co/huihui-ai/Huihui-DeepSeek-V4-Flash-0731-abliterated-GGUF) · [Venice ToS](https://venice.ai/legal/tos) · [Venice privacy](https://venice.ai/privacy) · [Stripe restricted businesses](https://stripe.com/legal/restricted-businesses) · [RunPod ToS](https://www.runpod.io/legal/terms-of-service) · [Cloudflare Self-Serve Agreement](https://www.cloudflare.com/terms/) · [DHS DeepSeek order (WinBuzzer)](https://winbuzzer.com/2026/10/20/us-civilian-agencies-must-remove-deepseek-based-ai-xcxwbn/) · [Federal Register filing](https://public-inspection.federalregister.gov/2026-21447.pdf) · [governments restricting DeepSeek](https://www.msn.com/en-in/news/other/from-rome-to-washington-why-governments-are-pulling-deepseek-off-official-systems/ar-AA2fENvp)

**Funding:** [Open Research Fund](https://www.openresearchfund.com/) · [Schmidt Sciences Trustworthy AI agenda](https://www.schmidtsciences.org/research-agenda/trustworthy-ai-research-agenda/) · [SFF-2026 application](https://survivalandflourishing.fund/2026/application) · [Coefficient Giving (formerly Open Philanthropy)](https://coefficientgiving.org/)

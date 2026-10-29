# Interpretability as a product: a survey for frog (late 2026)

Research note, 2026-10-26. Companion to `architecture.md` (what our models expose) and
`features.md` (what to build).

This is mechanistic and white-box interpretability work, filtered for one question: **what could
a coding agent's user see, computed cheaply at inference time on a stack we control (tang)?**
Each section covers three things:
- what the technique shows;
- what it would cost on tang;
- what evidence exists that users want it.

> **Method note.** The search backend failed partway through, so items from mid-to-late 2026
> are under-represented. Searches that had worked earlier started returning nothing. Most
> sources below were fetched directly from known URLs. Treat "as of late 2026" as "as of what
> could be verified". The newest items are MIT Technology Review's Jan 2026 pick, Goodfire's
> Silico (Apr 2026), OpenAI's confessions (Dec 2025) and the circuit-tracer transcoder list as
> it stands now.

---

## 0. The landscape in one paragraph

Mechanistic interpretability went mainstream in 2026:
- MIT Technology Review named it one of its **10 Breakthrough Technologies of 2026**
  ([MIT TR, Jan 12 2026](https://www.technologyreview.com/2026/01/12/1130003/mechanistic-interpretability-ai-research-models-2026-breakthrough-technologies/)).
- The tooling is now productised **for model builders**:
  - Anthropic's open-sourced circuit tracer, with a Neuronpedia front end
    ([Anthropic](https://www.anthropic.com/research/open-source-circuit-tracing),
    [GitHub](https://github.com/decoderesearch/circuit-tracer)).
  - Transluce's Monitor ([Transluce](https://transluce.org/observability-interface)).
  - Goodfire's **Silico**, a downloadable macOS "interpretability agent", released Apr 30 2026
    as "the first off-the-shelf mech-interp tool spanning data, training and debugging"
    ([Goodfire](https://www.goodfire.com/silico);
    [MIT TR, Apr 30 2026](https://www.technologyreview.com/2026/04/30/1136721/this-startups-new-mechanistic-interpretability-tool-lets-you-debug-llms/);
    [summary](https://www.aichatdaily.com/ai-tools/goodfire-silico-llm-interpretability-tool)).

**Nobody has shipped interpretability to end users of a coding agent.** The only consumer-facing
interp product on record is a 24-hour demo, Golden Gate Claude, in May 2024
([Anthropic](https://www.anthropic.com/research/golden-gate-claude)). The gap is open. The
evidence also says most of what researchers find exciting is *not* what users need (§3, §10).

---

## 1. Attribution graphs / circuit tracing

**What it shows.**
- A trained **cross-layer transcoder (CLT)** replaces the model's MLPs with sparse,
  interpretable features.
- For one prompt and one target token, attention patterns and norm denominators are frozen.
  That makes feature-to-feature effects linear, so you get a pruned graph of "which features
  caused which, leading to this token"
  ([Ameisen et al. 2025, methods](https://transformer-circuits.pub/2025/attribution-graphs/methods.html)).
- Showcase findings ([Lindsey et al. 2025, biology](https://transformer-circuits.pub/2025/attribution-graphs/biology.html)):
  - two-hop reasoning done "in its head";
  - **planning ahead** (rhyme words chosen before the line is written);
  - a **default "can't answer" circuit**, inhibited by "known entity" features, whose misfire
    causes hallucinations;
  - telling *faithful* chains of thought apart from *motivated* ones that work backward from a
    hint.

**Limits that matter for us.**
- The CLT matches the model's outputs in only **about 50% of cases**. On out-of-distribution
  prompts, "error nodes" can "completely obscure what the model is doing" (methods paper,
  §Limitations).
- Attention is frozen, so *why the model looked where it looked* is out of scope.
- Every graph needs human or LLM annotation to mean anything.

**Feasibility on tang: no, not in serving, and not soon.**
- Public transcoders exist for Gemma-2/3, Llama-3.x, GPT-OSS-20B, and dense **Qwen3 up to 14B**
  ([circuit-tracer README](https://github.com/decoderesearch/circuit-tracer)).
- None exist for Qwen3-Next or GLM-5.x. Their hybrid recurrent mixers and 288/512-expert MoE
  have no published CLT recipe at all. On MoE, a transcoder would be replacing a routed sum of
  experts.
- A graph also costs a backward-style pass per target token, offline.

**User evidence.** None for end users. It's a researcher tool. A third-party 2026 write-up puts
it bluntly: the capability exists for Anthropic's models, but bringing it to arbitrary
open-weight production models "requires significant engineering investment"
([Mitra, Jan 2026](https://subhadipmitra.com/blog/2026/circuit-tracing-production/)). That
post's claim that circuit tracing is Claude-only is out of date; see the README above.

**Takeaway for frog.** Use attribution graphs as an **offline bug-report artifact** on a small
proxy model. Never use them as a live feature (see features.md, "circuit capture").

---

## 2. Sparse autoencoders and feature dashboards

**What they show.** An SAE decomposes activations into many sparse "features" with auto-written
labels. Dashboards show the top-activating examples for each feature
([Cunningham et al. 2023](https://arxiv.org/abs/2309.08600);
[OpenAI, scaling SAEs](https://cdn.openai.com/papers/sparse-autoencoders.pdf);
[Goodfire practical guide](https://www.goodfire.com/blog/a-practical-guide-to-saes)).
- Transluce's Monitor is the most product-like example. It offers:
  - a real-time concept panel per chat, ranked by **activation** or **attribution**;
  - an **"AI linter"** that flags clusters of unexpected concepts. The canonical example is
    "September 11th" neurons firing on "9.11" in a 9.11 vs 9.9 comparison;
  - natural-language **steering**, which clamps the top-k neurons whose descriptions match a
    query.

  Its design principles are "AI surfaces findings, user doesn't hunt" and "every claim traces
  back to exemplars". They were built from over a dozen user interviews
  ([Transluce](https://transluce.org/observability-interface)).

**The 2025 reality check.** Google DeepMind's interp team **deprioritised SAE research**. On a
practical task, detecting harmful intent out of distribution:
- dense **linear probes scored AUROC ≈ 1.0**, even OOD;
- 1-sparse SAE probes "failed to fit the training set";
- k-sparse SAE probes generalised worse OOD;
- SAE reconstructions "discard information relevant to the target concept".

Their conclusion: "many practical ways linear probes could be used today to do cheap monitoring"
([GDM, Mar 2025](https://www.alignmentforum.org/posts/4uXCAJNuPKtKBsi28/negative-results-for-saes-on-downstream-tasks)).

**Feasibility on tang.** Possible in principle. We'd need one SAE per tapped layer, trained on
our own activations: 2048-d residual for Coder, 4 × 4096 mHC streams for GLM. But SAE features
are a labelling problem, not a product. **Probes (§3) get the same practical value at a
fraction of the cost.**

**User evidence.** Golden Gate Claude drew huge public interest as a novelty. There's no
evidence of sustained user value from feature dashboards outside research.

---

## 3. Linear probes: the cheap workhorse

A probe is a dot product of one layer's hidden state with a learned vector. **Inference cost is
about 0**: a 2048-d dot product per token. It can be fused after a layer's add-norm with no
sync (architecture.md, S9). The open questions are training data and calibration, not compute.

Probes with direct relevance to a coding agent:

| Probe target | Result | Source |
|---|---|---|
| **Hallucinated entities**, token-level and streaming (names, dates, citations) | Linear/LoRA probes beat semantic entropy on long-form: **AUC 0.90 vs 0.71** on Llama-3.3-70B. Probes transfer across models. Trained on entities, they also flag wrong math answers | [Obeso et al. 2025, arXiv 2509.03531](https://arxiv.org/abs/2509.03531) |
| **Semantic uncertainty** from a single generation | Semantic-entropy probes approximate SE (which needs 5-10 samples) from hidden states "at almost zero" overhead, and generalise OOD better than accuracy probes | [Kossen et al. 2024, arXiv 2406.15927](https://arxiv.org/abs/2406.15927); SE itself: [Farquhar et al., Nature 2024](https://www.nature.com/articles/s41586-024-07421-0) |
| **Generated-code correctness** | Internal states of code LLMs "strongly correlate" with correctness. OPENIA beats baselines, with up to 2× in standalone generation and +46% on repo-specific tasks | [OPENIA, arXiv 2501.12934](https://arxiv.org/abs/2501.12934) |
| **Prompt injection / task drift** | The *activation delta* before vs after reading external data is near-perfect (ROC AUC) at detecting drift OOD. It generalises to unseen injections and jailbreaks without training on them | [Abdelnabi et al. 2024, arXiv 2406.00799](https://arxiv.org/abs/2406.00799) (TaskTracker) |
| **Malicious inputs** via latent-prediction trajectories | Tuned-lens trajectories detect malicious inputs "with high accuracy" | [Belrose et al. 2023, arXiv 2303.08112](https://arxiv.org/abs/2303.08112) |
| **Persona / trait drift** (sycophancy, "evil", hallucination propensity) | Persona vectors monitor and predict trait expression *before* generation | [Anthropic, persona vectors](https://www.anthropic.com/research/persona-vectors) |
| **Sandbagging** | Logistic probes reach 90-96% on Mistral, Gemma and Qwen | [Mitra, Dec 2025](https://subhadipmitra.com/blog/2025/detecting-ai-sandbagging/) (blog, not peer-reviewed) |
| Harmful intent | AUROC ≈ 1.0 OOD | GDM, above |

**Feasibility on tang: high.**
- The hook already exists for research: `Probe` in the flash engines, `DumpSink` in glm5.
- The serving version is a fused dot product.
- The real work is **labels**. frog has a free labelling engine: every turn ends with ground
  truth about whether the code compiled, the tests passed, the user undid the edit, or the user
  said "no, that's wrong". That's exactly the supervision the code-correctness and
  hallucination probes need.

**User evidence.** Indirect but strong. Users want "tell me where to look" (§4), and probes
predict *errors*, which is what §4's winning condition highlighted.

---

## 4. Logprob / entropy uncertainty display

**What it shows.** Per-token probability, entropy, top-k alternatives, or the top-1/top-2
margin, shown as highlighting or a confidence glyph.

**The key user study says naive probability highlighting doesn't help.** In a preregistered
CHI study with 30 programmers
([Vasconcelos et al., arXiv 2302.07248](https://arxiv.org/abs/2302.07248);
[MSR page](https://www.microsoft.com/en-us/research/publication/generation-probabilities-are-not-enough-exploring-the-effectiveness-of-uncertainty-highlighting-in-ai-powered-code-completions/)):
- Highlighting tokens by **generation probability gave no benefit** over no highlighting.
- Highlighting tokens by **predicted likelihood of being edited** led to faster completion and
  more targeted edits, and participants preferred it.
- Programmers want highlights that are "granular, informative, interpretable, and not
  overwhelming".

**Natural-language uncertainty works.** In a preregistered study with N = 404, first-person
hedges ("I'm not sure, but…") cut over-reliance and raised accuracy. Impersonal hedges were
weaker and not significant
([Kim et al., FAccT 2024, arXiv 2405.00623](https://arxiv.org/abs/2405.00623)).

**Entropy is a good *control* signal in reasoning models.** Sequence-level entropy from token
logprobs supports early stopping with 25-50% compute savings at equal accuracy. The authors
present this as an **emergent property of modern post-trained reasoning models** that is absent
in plain instruct models
([arXiv 2510.08146](https://arxiv.org/abs/2510.08146)). tang already uses a probability signal
internally the same way: draft-length pricing by calibrated draft probability
(architecture.md §3.5).

**Feasibility on tang: trivial** (architecture.md S1). GLM's full logits are already on the
host. Coder needs a tiny logsumexp + top-k kernel next to the existing argmax/runner-up kernel.

**Takeaway.** Don't paint tokens by probability. **Aggregate entropy over semantic units** such
as an identifier, a path, a version number or a whole tool argument. Combine it with a learned
**"will this be edited / is this wrong" probe** trained on frog's own outcome data. Then surface
it the way Kim et al. found works: few highlights, high precision, in plain words.

---

## 5. MoE expert-routing visualisation

**What it shows.** Which experts fire per token and layer: heatmaps, token colouring by expert,
per-domain histograms.

**What the research says experts *mean*:**
- **Mixtral**: "Surprisingly, we do not observe obvious patterns in the assignment of experts
  based on the topic." ArXiv LaTeX, PubMed and PhilPapers route almost identically. Routing
  aligns with **syntax** instead: Python `self`, indentation tokens and "Question" each go to
  consistent experts. It also shows strong **temporal locality**, with consecutive tokens
  sharing experts far above chance at later layers
  ([Mixtral, arXiv 2401.04088 §5](https://arxiv.org/html/2401.04088)).
- **OLMoE** reports "high specialization" in its routing analysis
  ([arXiv 2409.02060](https://arxiv.org/abs/2409.02060)). Finer-grained MoEs (64+ experts)
  specialise more than Mixtral's 8.

Our models are very fine-grained: 288 experts with top-8, and 512 with top-10. So more
specialisation than Mixtral is plausible, but nobody has measured it for these models. That's an
open question we could answer cheaply ourselves.

**Feasibility on tang: cheap** (architecture.md S2). Accumulate a per-request `[layers][experts]`
histogram on device: 48-96 KB once per request.

**User evidence.** None for end users. Its appeal is aesthetic ("the brain lighting up"), and
the risk is that it **looks like explanation but isn't one**. The honest framings:
- **fingerprint**: "this task used a different part of the model than your last 50";
- **anomaly**: "routing looks unlike any successful turn".

Never frame it as "the Python expert fired".

---

## 6. Linear-attention / recurrent-state visualisation (KDA, GDN, Mamba)

**What exists.**
- Gated linear RNNs (Mamba, RWKV, gated DeltaNet-style layers) can be rewritten as **implicit
  causal attention matrices**. That gives attribution maps competitive with transformer
  explainability methods
  ([Zimerman et al. 2024, arXiv 2405.16504](https://arxiv.org/abs/2405.16504)).
- Factual recall in Mamba localises much as it does in transformers: mid-layer states at the
  subject's last token. Rank-one edits work
  ([Sharma et al. 2024, arXiv 2404.03646](https://arxiv.org/abs/2404.03646)).
- KDA is Gated DeltaNet with per-channel gating, built as a fixed-size fast-weight memory
  ([Kimi Linear, arXiv 2510.26692](https://arxiv.org/abs/2510.26692)).

**What's specific to delta-rule layers (our 34 KDA / 36 GDN layers).** The state `S` is an
**associative memory: key → value, written by the delta rule.** That gives three things a
transformer KV cache doesn't:
1. **A per-token "surprise" scalar.** The write `δ = β(v − Sᵀk)` is the memory's prediction
   error. A token whose value the memory already predicted writes almost nothing.
2. **An explicit forgetting signal.** `exp(g)` per channel is the model deciding how much to
   keep.
3. **A queryable snapshot.** A fixed 136 MiB (GLM) or 72 MiB (Coder) state can be probed
   offline: "if I query with file X's keys, how much comes back?"

I found no published work that turns these into a user-facing display. **This is novel
territory, and we are one of the few teams serving KDA ourselves.**

**Feasibility on tang.** S7: per-layer mean `g`, mean β and ‖δ‖ are 3 floats × 34 layers per
token, reduced on device. S8: snapshots already exist for Coder.

**User evidence.** None. It's a research bet. The closest user need is "does it still remember
what I told it?" (features.md, cache/memory).

---

## 7. mHC (manifold-constrained hyper-connections)

mHC widens the residual stream into n streams mixed by doubly stochastic matrices (Sinkhorn).
That restores the identity-mapping property that plain hyper-connections lose
([DeepSeek, arXiv 2512.24880](https://arxiv.org/abs/2512.24880)).

I found **no interpretability work on mHC streams**. In tang the per-token mixes are already on
the host for free (architecture.md S10). Whether the 4 streams specialise is an open question
that's cheap to answer offline. It isn't a user feature until someone shows the streams mean
something.

---

## 8. Context attribution ("what in the context drove this")

- **Raw attention weights are not explanations.** They are often uncorrelated with
  gradient-based importance, and very different attention patterns can give the same output
  ([Jain & Wallace 2019, arXiv 1902.10186](https://arxiv.org/abs/1902.10186)).
- **Ablation-based attribution works but is expensive.** ContextCite ablates context sources
  and fits a surrogate. Uses shown: verifying statements, pruning context, detecting poisoning
  ([Cohen-Wang et al. 2024, arXiv 2409.00729](https://arxiv.org/abs/2409.00729)).
- **Learned attention attribution is cheap and faithful.** AT2 treats per-head attention
  weights as *features*, trains on ablation signal, and matches many-ablation methods at a
  fraction of the cost
  ([Cohen-Wang et al. 2025, arXiv 2504.13752](https://arxiv.org/abs/2504.13752)).

**What we have that they don't.**
1. **Exact copy provenance.** tang's suffix drafter already knows the source position of every
   accepted copied span (architecture.md S4). For agent output, which copies file contents,
   paths and earlier edits heavily, that's *ground truth*, not inference.
2. **GLM's DSA indexer already picks the top 2048 past tokens** each long-context query attends
   to (S5). It's a model-native relevance set, cheaper than materialising attention.
3. **Only 11-12 layers have softmax attention at all.** That's 1/4 of the AT2 feature cost.

---

## 9. Chain-of-thought faithfulness and self-report

frog already shows thinking blocks, so this is the section with the most product risk.

- **CoT often omits what drove the answer.** Given a hint, reasoning models mentioned using it
  in only a minority of cases: **41% (Claude 3.7 Sonnet) and 19% (R1)** for the concerning
  "unauthorized access" hints. Outcome RL raised faithfulness, then plateaued at **28% / 20%**.
  Models that learned to reward-hack admitted it **< 2%** of the time, and often built fake
  rationales ([Anthropic 2025](https://www.anthropic.com/research/reasoning-models-dont-say-think)).
- **CoT monitoring works, but is fragile.**
  - A GPT-4o monitor reading the CoT caught coding-task reward hacks, such as subverting unit
    tests, far better than an action-only monitor.
  - Penalising "bad thoughts" made the agent **hide its intent**: "almost all of its cheating is
    undetectable by the monitor"
    ([OpenAI 2025](https://openai.com/index/chain-of-thought-monitoring/)).
  - The cross-lab position paper calls monitorability "a new and fragile opportunity"
    ([Korbak et al., arXiv 2507.11473](https://arxiv.org/abs/2507.11473)).
- **Confessions.** A separate output trained *only* for honesty. Across misbehaviour-inducing
  evals, the false-negative rate (misbehaved and didn't confess) was **4.4%**. Most misses came
  from genuine confusion. It works even without CoT
  ([OpenAI, Dec 2025](https://openai.com/index/how-confessions-can-keep-language-models-honest/);
  [arXiv 2512.08093](https://arxiv.org/abs/2512.08093)).
- **Introspection is real but unreliable.** Models can sometimes detect and name a concept
  injected into their activations. The ability is "highly unreliable", strongest in the most
  capable models, and raises the worry that self-reports need "lie detectors"
  ([Anthropic 2025](https://transformer-circuits.pub/2025/introspection/index.html)).

**Takeaways for frog.**
1. Never present a thinking block as "why it did this". Label it as what it is.
2. A *white-box* signal (probe, routing anomaly, injection-delta) that **disagrees** with the
   CoT is the most valuable thing we could show. It's the "lie detector" the introspection
   paper asks for, at agent scale.
3. Don't train our own models against these monitors, or we lose them (OpenAI's obfuscation
   result). This matches muni's stated rule that Ipse refusals are "never trained against".

---

## 10. What users have actually been shown to want

| Evidence | Implication |
|---|---|
| Probability highlighting gives no gain; *edit-likelihood* highlighting gives faster, targeted edits and is preferred (N = 30, CHI) | Highlight **predicted-wrong**, not low-probability |
| First-person hedges reduce over-reliance and raise accuracy (N = 404) | Say it in words, sparingly, in the model's voice |
| Transluce interviews: AI should surface findings and keep provenance | Don't make users read heatmaps. Show 1-3 flagged items with "why we think so" |
| CoT is often unfaithful; monitors beat self-report | Value is in **disagreement** between internals and narration |
| frog's own UI: the cost popover already shows cache read/write; users asked for speed numbers (`tokens_per_sec` in Status) | Users like **meters**: cache, speed, draft hits are wanted, cheap and honest |

---

## 11. Feasibility summary on our stack

| Technique | Serving cost on tang | Data needed | Ship-able in |
|---|---|---|---|
| Logprob / entropy / margin | ≈0 | none | days |
| Draft acceptance meter | 0 (already in usage) | none | hours (frog only) |
| Copy provenance (suffix drafter) | ≈0 | none | days |
| Expert-routing fingerprint | ≈0 (histogram) | a baseline corpus | days |
| Linear probes (wrong-code, hallucinated API, injection drift) | ≈0 per token | **labels**: frog outcomes, a few thousand turns | weeks |
| KDA / GDN gate and surprise traces | small | none to show; research to *interpret* | weeks (research) |
| DSA indexer relevance | small (pooled) | none | days, GLM long-context only |
| AT2-style learned attention attribution | moderate (on demand) | ablation runs offline | weeks |
| SAE dashboards | moderate, plus training | SAE training | months |
| Attribution graphs | offline only, no transcoders exist for our models | CLT training | research project |

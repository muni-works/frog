# Interpretability features for frog: ranked recommendations

Research note, 2026-10-26. It builds on:
- `architecture.md`: the signals S1–S12, with tang file:line for each;
- `survey.md`: the research and user evidence, with sources.

tang paths are relative to `~/Developer/tang/crates/tang-llm/`. frog paths are relative to the
repo root.

**The thesis.**
- Nobody ships interpretability to people who use coding agents. The research says the obvious
  version, a token heatmap by probability, **doesn't help** (survey §4).
- What does help is **few, precise flags about what's likely wrong or not grounded**, said in
  plain words, with provenance.
- We control tang, so three of those signals are close to free for us:
  - the logits,
  - the drafter's copy positions,
  - hidden states for probes.

  No hosted-API agent can do that. Our edge is not a prettier picture of the model's brain. It's
  that **we can tell a user, from inside the model, which three things in this diff to check.**

## Ranking

Impact is for a daily user of a coding agent. Feasibility is on our stack today. Both are scored
1–5.

| # | Feature | Impact | Feasibility | Score | Build |
|---|---|---|---|---|---|
| 1 | **Receipts**: where every path, name and line came from | 5 | 5 | 25 | **first** |
| 2 | **Guess marks**: the model shows where it's guessing | 5 | 4 | 20 | **first** |
| 3 | **Tripwire**: activation-level injection alarm | 5 | 3 | 15 | **first** |
| 4 | Speedometer with draft hits | 3 | 5 | 15 | rides along with #1 |
| 5 | Memory meter: "how much of me do you remember" | 3 | 4 | 12 | next |
| 6 | Circuit capture: one-click weirdness report | 3 | 3 | 9 | next (internal value) |
| 7 | Think-just-enough: entropy-cut thinking | 3 | 3 | 9 | GLM only |
| 8 | Honesty check: claims vs evidence vs internals | 4 | 2 | 8 | later |
| 9 | Brain fingerprint: expert-routing glyph and anomaly | 2 | 4 | 8 | fun; ship as texture |
| 10 | Focus lens: what in the context drove this | 3 | 2 | 6 | research first |

**Build order.** Build #1, #2 and #3. #4 costs a few hours once #1's plumbing exists, so ship it
in the same PR. All of them share one plumbing change:
1. an optional `tang` object per SSE chunk, plus per-call aggregates in `usage`;
2. frog parsing it (`crates/frog-engine/src/provider/openai.rs:263-277,343-361`);
3. a `StreamEvent::TokenMeta` (`provider/mod.rs:54-73`);
4. aggregates stored on the completed `Item`, since deltas aren't durable
   (`crates/frog-engine/src/protocol.rs:801-833`).

---

## 1. Receipts ★ build first

**Pitch:** every file path, symbol, flag and copied line in the agent's output carries a receipt
pointing to the tool result it came from. Anything without a receipt is flagged as "came from the
model, not the repo".

**Signal:**
- **S4, copy provenance.** tang's suffix drafter keeps a first end position for each automaton
  state (`src/draft.rs:68-79`, continuation at `:237`). When a suffix draft is accepted, we know
  the exact source token position in the prompt.
- Fallback for MTP mode and for non-tang providers: **frog-side exact string matching** against
  earlier tool results in the session.

**Hook in tang:**
- In `FlashServe`'s suffix path (`src/flash/serve.rs:503-508`, accept loop near `:1578`), map
  the source position to a `(message index, char offset)` with the chat template's message
  boundaries. Emit it as `tang.copy` on the chunk.
- The dense engine already checks draft hits per row (`src/engine.rs:1572`). Same hook.

**UI:**
- In edits and diffs (`apps/FrogKit/UI/Transcript/TurnView.swift`, `FileChange`), copied spans
  get a faint left rule. Hovering shows the source, for example "Read src/auth.rs, turn 3, line
  88".
- **Unsourced references** get a small dotted underline. These are identifiers, paths, URLs,
  versions and CLI flags that appear in no prior tool result.
- On approval cards (`apps/FrogKit/UI/Transcript/ItemViews.swift:538-571`): "2 of 3 paths in
  this command were never read this session."

**Cheap version (days, any provider):**
- frog tokenises references out of output and tool arguments. It checks each one against the
  session's tool results, which are already in memory.
- No tang change at all. It works on Claude and on local models.

**Full version:**
- tang provides exact token-level copy spans, including partial and edited copies that string
  matching misses. GLM's DSA indexer selection (S5, `src/flash/glm5/mla.rs:378`) adds "read but
  not copied" support.

**Precedent:**
- Context attribution: ContextCite, which verifies statements and detects poisoning
  ([2409.00729](https://arxiv.org/abs/2409.00729)).
- SuffixDecoding-style drafting is tang's own (`src/draft.rs:1-14`).
- The novel part is using the drafter as a **provenance oracle**. I found no published system
  that does.

**Why it's #1:** in a coding agent, the most expensive failure is a confident reference to
something that doesn't exist. Examples: a hallucinated API, a made-up flag, a path never read.
Receipts catch that class structurally, with **zero false negatives on exact copies and no ML**.
It also makes the 80% of output that *is* grounded visibly trustworthy.

---

## 2. Guess marks ★ build first

**Pitch:** the model marks the specific spans where it was guessing. It only marks the ones that
matter, in plain words.

**Signal:**
- **S1:** token logprob, entropy and top-1/top-2 margin.
- Aggregated over **semantic units**, not tokens: an identifier, a string literal, a number, a
  whole tool argument.
- Later, a **"will be edited / is wrong" linear probe** (S9) trained on frog's own outcomes:
  - the user undid the edit;
  - the next test run failed on that line;
  - the user replied "no".

**Hook in tang:**
- **GLM:** full logits are already on the host after `window()` (`src/flash/glm5/engine.rs:711`).
  Compute entropy and top-3 next to `argmax` (`:966`). It's about 0 cost.
- **Coder:** add a logsumexp + top-k reduction beside the head argmax (`src/flash/coder.rs:
  3143-3170`). The `cx_mtp_pick` kernel already does argmax, probability and runner-up
  (`coder.rs:226-290`), so reuse it. That's 48 B per token D2H.
- **Dense / Mac:** `Logits::Top` already returns the top 64 (`src/model.rs:1006,1085`). Add one
  full-vocab logsumexp so they can be normalised. Hook at `src/engine.rs:1563-1568`.
- **Tool arguments:** aggregate per argument *in tang*. The Qwen XML tool parser
  (`chat::parse_xml_call`, referenced at `src/flash/serve.rs:18`) knows which generated tokens
  belong to which argument. Emit `tool_calls[i].tang.arg_conf`.

**UI:**
- At most ~3 guess marks per turn. Each is a soft amber underline on the span.
- Hover shows the runner-up: "guessed `--frozen-lockfile`; also considered `--immutable`
  (38%)".
- Approval cards get one line: "Guessed: the branch name." Auto mode (`crates/frog-engine/src/
  auto.rs:340-350`) gets the score as an input, so a guessed argument escalates to ask.
- In the first person, sparingly (Kim et al.): "I'm not sure about the port number."

**Cheap version:** entropy only, over identifiers and tool arguments, with a fixed threshold per
model. Calibrate the threshold on a frog-bench run.

**Full version:** a probe trained on frog outcome labels. Fire on *predicted-wrong*, not on
low-probability. This is exactly the condition that worked in the CHI study.

**Precedent:**
- Probability highlighting doesn't help; edit-likelihood highlighting does
  ([2302.07248](https://arxiv.org/abs/2302.07248)).
- First-person hedges reduce over-reliance ([2405.00623](https://arxiv.org/abs/2405.00623)).
- Hallucination probes beat semantic entropy, AUC 0.90 vs 0.71
  ([2509.03531](https://arxiv.org/abs/2509.03531)).
- Code-correctness probes ([2501.12934](https://arxiv.org/abs/2501.12934)).

**Explicit non-goal:** a heatmap of every token. The evidence says it adds noise and no value.

**Combined with #1, this is the killer pair.** A reference that is **unsourced *and*
low-confidence** is almost certainly invented. That intersection deserves a red flag. Each signal
alone gets an amber one.

---

## 3. Tripwire ★ build first

**Pitch:** frog notices when something the agent *read* changed what it is *trying to do*. It
pauses before the next tool call, and the alarm comes from inside the model, not from a regex.

**Signal:**
- **S9, an activation-delta probe.** Take the residual at one mid layer at the end of the user's
  message (the "task"). Take it again at the end of each tool result.
- A linear classifier on the difference detects **task drift**. The TaskTracker work reports
  near-perfect ROC AUC out of distribution, generalising to unseen injections and jailbreaks
  without training on them ([2406.00799](https://arxiv.org/abs/2406.00799)). Its 500k-example
  dataset is public.

**Hook in tang:**
- **Train offline** on our models with the existing research hooks:
  - Coder: `Probe.post_moe` (`src/flash/coder.rs:3205-3234`; struct at `src/flash/engine.rs:
    526`).
  - GLM: `DumpSink` (`src/flash/glm5/dump.rs`) or `glm5-ref --dump`. Fix the `entries`
    accumulation first (architecture.md §2.7).
- **Serve** with a fused dot product after the chosen layer's add-norm, read only at
  message-boundary positions. The server already knows them: `serve.rs` renders the chat
  template and splices messages (`src/flash/serve.rs:6-9`).
- Cost: one 2048-d (Coder) or 16384-d (GLM) dot product per tool result. Emit the score in
  `usage` as `tang.drift: [{msg, score}]`.

**UI:**
- When the score crosses a threshold, the *next* tool call becomes an approval card even in auto
  mode. The card's risk line (`crates/frog-engine/src/approval.rs:363-384`) reads: "After
  reading `https://…`, my plan shifted. Check this is still what you asked for."
- The orange Degraded-style pill (`apps/macos/Frog/Views/ActivityViewer.swift:240-264`) marks
  the session.
- It **never silently blocks**. It only escalates to the human.

**Cheap version:** the probe is trained on the public TaskTracker data and run only on untrusted
results: web, MCP and IRC. Those are already tagged `untrusted="true"` (`crates/frog-engine/src/
tools/web.rs:564-568`; `docs/quarantine.md`).

**Full version:**
- Run it on every tool result, file reads included, since repo files can carry injections.
- Calibrate per model on frog sessions.
- Feed the score to the `auto.rs` classifier.

**Precedent:**
- TaskTracker ([2406.00799](https://arxiv.org/abs/2406.00799)).
- Tuned-lens malicious-input detection ([2303.08112](https://arxiv.org/abs/2303.08112)).
- GDM: linear probes are AUROC ≈ 1.0 OOD for harmful intent and are "practical today"
  ([AF post](https://www.alignmentforum.org/posts/4uXCAJNuPKtKBsi28/negative-results-for-saes-on-downstream-tasks)).

**Why build first:** "quarantines tools that look like injection" is already frog's stated
differentiator (muni master plan, frog product line). Today quarantine is text heuristics only
(`crates/frog-engine/src/mcp.rs:1255`; `docs/quarantine.md:22-38`), and **tool results aren't
filtered at all** (`quarantine.md:38`). A white-box tripwire is the feature a hosted-API agent
*can't* copy. It's also the one most likely to make a launch headline.

---

## 4. Speedometer with draft hits (rides along with #1)

**Pitch:** "41 tok/s, 58% predicted ahead." This shows how much of the reply the drafter
guessed right, and therefore how much was routine copying versus new thought.

**Signal:** S3. `draft_n` / `draft_n_accepted` are **already in every tang usage object**
(`src/server.rs:2236-2243`). frog drops them (`crates/frog-engine/src/provider/openai.rs:
343-361`).

**Hook:** none in tang. In frog, extend `read_usage`, add the fields to `Usage`
(`crates/frog-engine/src/message.rs:82`), and carry them through `CallTiming`
(`crates/frog-engine/src/protocol.rs:1198-1228`).

**UI:**
- Next to the speed readout (`apps/macos/Frog/Views/ActivityViewer.swift:234-238`) and in the
  cost popover (`apps/FrogKit/UI/Transcript/TurnCosts.swift`).
- Full version: per-span acceptance shading in the transcript. That's the same data as
  Receipts.

**Cheap version:** hours. **Full version:** per-token accept bits (1 bit/token) from
`Policy::observe` (`src/flash/serve.rs:467-478`). Also the live probability → acceptance
calibration curve (`serve.rs:404-478`), a "the model's own confidence calibration" chart for
the curious.

**Precedent:** llama.cpp exposes these exact field names. frog-bench already reports cache stats
(`crates/frog-bench/src/cache.rs`). Users demonstrably like speed numbers (survey §10).

---

## 5. Memory meter: "how much of me do you remember"

**Pitch:** an honest gauge of what the model is holding:
- exact context (KV),
- compressed memory (the recurrent state),
- and what it had to recompute.

**Signal:**
- S11: live extend vs snapshot restore vs cold, restore ms.
- S8: the fixed-size recurrent state.
- Later, S7: KDA/GDN forget gates `exp(g)`.

**Hook in tang:**
- The `Line` fields (`src/flash/serve.rs:482-498`) to usage, for example
  `tang.cache: {live, snapshot, cold, restore_ms}`.
- **First fix GLM's over-report.** `restore_running` re-prefills but is counted as `reused`
  (`src/flash/glm5/serve_glue.rs:77-85`; `serve.rs:1222-1248,1401`). Wire real snapshots via
  `DevKda::read_state` (`src/flash/glm5/kda_cuda.rs:565`).

**UI:**
- The cost popover already splits fresh, cached and written (`apps/FrogKit/UI/Transcript/
  TurnCosts.swift:184-207`). Add the *kind* of reuse plus the restore time.
- A context ring shows "exact: 24 KB/token × N" versus "compressed: 72 MiB fixed".

**Full version (research):**
- Integrate the recurrent layers' decay since each message ended. That's a running product of
  mean `exp(g)` per layer: `src/flash/glm5/kda.rs:264-289` for GLM, the GDN step at
  `src/flash/coder.rs:2584` for Coder.
- Render older transcript messages as "fading" on the timeline rail
  (`apps/macos/Frog/Views/TimelineRail.swift`).
- Caveat: the 11–12 softmax-attention layers still see every token exactly. Only the cheap
  memory fades. Label it that way, or it lies.

**Precedent:** Kimi Linear's fixed-state framing ([2510.26692](https://arxiv.org/abs/2510.26692)).
Delta-rule state as an associative memory (survey §6). No user-facing precedent: this is novel.

---

## 6. Circuit capture: one-click "that was weird"

**Pitch:** when the agent does something bizarre, one click files a bug report that contains the
model's internals, not just the transcript.

**Key insight:**
- Capture can be **deferred**, because tang serving is deterministic. The output is "the engine's
  sampling at `Philox(seed, position)` whatever the drafts" (`src/flash/serve.rs:15-17`), and
  GLM is greedy.
- So frog stores only the request body and seed. The capture is a **deterministic replay** in
  tang with every research hook on:
  - `Probe` for per-layer residuals and router ids (`src/flash/coder.rs:3205-3234`);
  - `DumpSink` / `glm5-ref --dump` (`src/flash/glm5/dump.rs`, `forward.rs:500-581`);
  - top-k logprobs per position (`src/flash/reference.rs:846,1837`).
- Serving pays nothing.

**UI:**
- A "Report weirdness" item on the turn menu (`apps/FrogKit/UI/Transcript/TurnView.swift`,
  `TurnActions`).
- The user sees "captured, replaying". Later they get a one-line finding, for example "it
  attended mostly to an old error message", plus a link.

**Cheap version:** request + seed + frog session slice, replayed with logit-lens-style per-layer
top tokens.

**Full version:** an attribution graph on a **dense proxy**, Qwen3-14B with the public
transcoders ([circuit-tracer](https://github.com/decoderesearch/circuit-tracer)). This only
applies when the proxy reproduces the behaviour. No transcoders exist for Qwen3-Next or GLM
(survey §1).

**Value:** mostly to us. It turns user weirdness into tang and model bugs. The GLM DSA GPU issue
in architecture.md §1.3 is exactly the kind of thing this would surface. Impact for the user is
moderate: they feel heard. It's a strong launch-blog artifact.

---

## 7. Think-just-enough (GLM)

**Pitch:** the model stops deliberating once its own entropy says it has decided. The UI shows
"decided early, saved 1.4k tokens".

**Signal:** S1 sequence entropy over the reasoning stream. The research says this calibration is
**emergent in post-trained reasoning models and absent in plain instruct models**, with 25–50%
savings at equal accuracy ([2510.08146](https://arxiv.org/abs/2510.08146)). So it applies to
GLM's thinking mode. It probably does **not** apply to Qwen3-Coder-Next. The Qwen3-Coder line
ships as non-thinking instruct models; confirm this for Coder-Next before relying on it.

**Hook:** GLM host logits (`src/flash/glm5/engine.rs:711`). frog's `thinking_budget` extension
already exists (`crates/frog-engine/src/provider/openai.rs:188-192`), as does `thinking.rs`'s
heuristic budget (`crates/frog-engine/src/thinking.rs:1-15`).

**UI:** a chip on the thinking block ("decided early").

**Cheap version:** display only. **Full version:** tang ends thinking server-side at a
calibrated entropy threshold.

---

## 8. Honesty check: claims vs evidence vs internals

**Pitch:** when the final message says "tests pass" or "I updated the config", frog checks the
claim. It flags any claim that the tool results don't support, or that the model's internals
disagree with.

**Signal:**
- Cheap version: text claims matched against tool results. This works with any model.
- Full version: a probe (S9) for "asserting unverified success", trained on frog outcomes. It's
  checked for **disagreement with the CoT**.

**Hook:** a probe served like the Tripwire probe. UI as a chip on the claim sentence in
`ItemViews.swift`.

**Precedent:**
- CoT omits hints most of the time; reward hackers confess in their CoT < 2% of the time
  ([Anthropic](https://www.anthropic.com/research/reasoning-models-dont-say-think)).
- CoT monitors catch test subversion, but optimisation pressure hides intent
  ([OpenAI](https://openai.com/index/chain-of-thought-monitoring/)).
- Confessions reach a 4.4% false-negative rate
  ([OpenAI](https://openai.com/index/how-confessions-can-keep-language-models-honest/)).
- Introspection is unreliable, so "lie detectors" are needed
  ([Anthropic](https://transformer-circuits.pub/2025/introspection/index.html)).

**Rule:** never train frog's models against this monitor (survey §9).

**Why later:** the probe needs labelled data. The cheap text version may belong to the
`frog review` work (`docs/research/local-code-review.md`) rather than here.

---

## 9. Brain fingerprint: expert-routing glyph

**Pitch:** each turn gets a small, unique glyph of which experts lit up. "The model's brain
lighting up", honestly framed.

**Signal:** S2. Accumulate a per-request `[layers][experts]` count on device:
- GLM: 42 × 288, after `g5_router_select` (`src/flash/glm5/moe_gpu.rs:270-286`); CPU `route`
  at `moe.rs:280-333`.
- Coder: 48 × 512, after the `route` kernel (`src/flash/coder.rs:2862-2869`).

Read it once per request: 48–96 KB.

**UI:**
- The glyph sits on chapter markers (`apps/macos/Frog/Model/Chapters.swift`, `TimelineRail.swift`)
  and in the sidebar.
- Full version adds an **anomaly flag**: "this turn's routing is unlike any turn that succeeded
  in this repo", using frog outcome labels.

**Precedent and caveat:**
- Mixtral experts specialise by **syntax, not topic** ([2401.04088 §5](https://arxiv.org/html/2401.04088)).
- OLMoE's finer-grained experts specialise more ([2409.02060](https://arxiv.org/abs/2409.02060)).
- Nobody has measured our 288- and 512-expert models. That's worth an afternoon *before*
  building any UI.

**Never label an expert** ("the Python expert"). Ship it as texture and identity, not as an
explanation.

---

## 10. Focus lens: what in the context drove this

**Pitch:** hover a tool call and the messages it leaned on glow.

**Signal:**
- GLM: DSA indexer top-2048 selections pooled per message (S5, `src/flash/glm5/mla.rs:378`;
  `engine.rs:928-944`). It's active once the context passes 2048 tokens, which is always true
  for agent sessions.
- Coder: an AT2-style learned combination of the 12 attention layers' head weights (S6). This
  needs an in-kernel accumulator near the split-K launch (`src/flash/coder.rs:2625-2700`), run
  on demand.

**Caveat:** raw attention is not explanation ([1902.10186](https://arxiv.org/abs/1902.10186)).
AT2 fixes that by learning from ablations ([2504.13752](https://arxiv.org/abs/2504.13752)).
Validate against ablation on frog-bench before shipping, or label it "looked at", not "because".

**Why last:** the expensive signal and the faithfulness risk make it a research project. Receipts
(#1) answers 80% of "where did this come from" exactly.

---

## What not to build

- **Token-probability heatmaps.** The evidence shows no benefit (survey §4).
- **Named experts or features without validation.** They look like explanation but aren't (survey
  §2, §5).
- **"Here's why it did that" built from the thinking block.** CoT is often unfaithful (survey
  §9).
- **Live attribution graphs.** No transcoders exist for our models, and the replacement model
  matches only about 50% of the time (survey §1).
- **SAE dashboards for users.** Probes do the practical jobs better (GDM, survey §2).

## Open research questions that are cheap for us to answer

1. Do Coder-Next's 512 or GLM's 288 experts specialise by language or task? Answer with an S2
   histogram over a frog-bench corpus.
2. Does the KDA/GDN delta error ‖v − Sᵀk‖ spike on the tokens the user later edits? If it does,
   it's a free surprise signal for Guess marks.
3. Do GLM's 4 mHC streams specialise? The mixes are already on the host (S10).
4. How well does a Tripwire probe trained on TaskTracker transfer to Qwen3-Next's hybrid stack?
   No one has tested a delta-rule model.

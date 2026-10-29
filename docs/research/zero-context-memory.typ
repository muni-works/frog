// Zero-context compiled memory in tang: a research note.
// Build: typst compile docs/research/zero-context-memory.typ

#set document(
  title: "Zero-context compiled memory",
  author: "frog",
  date: datetime(year: 2026, month: 10, day: 29),
)
#set page(paper: "us-letter", margin: (x: 1.1in, y: 1in), numbering: "1")
#set text(font: ("Helvetica Neue", "Helvetica"), size: 10pt, lang: "en")
#set par(justify: true, leading: 0.62em)
#set heading(numbering: "1.1")
#show heading.where(level: 1): it => block(above: 1.6em, below: 0.8em, text(size: 13pt, weight: "semibold", it))
#show heading.where(level: 2): it => block(above: 1.2em, below: 0.6em, text(size: 11pt, weight: "semibold", it))
#show raw: set text(font: "Menlo", size: 8.6pt)
#show link: set text(fill: rgb("#2f5d8a"))
#set table(stroke: (x, y) => if y == 0 { (bottom: 0.6pt) } else { none }, inset: (x: 6pt, y: 4pt))
#show table.cell.where(y: 0): set text(weight: "semibold")

#let note(body) = block(
  fill: rgb("#f4f4f2"), inset: 10pt, radius: 3pt, width: 100%, text(size: 9.4pt, body),
)

#align(center)[
  #text(size: 19pt, weight: "semibold")[Zero-context compiled memory]
  #v(0.2em)
  #text(size: 11.5pt)[Exact, persistent memory in a hybrid model's recurrent state, served by tang]
  #v(0.6em)
  #text(size: 9.5pt, fill: rgb("#555"))[frog research · draft · 29 October 2026]
]

#v(1em)

#note[
  *Summary.* Divyansh Agrawal's _qwenputer_ showed that a Gated DeltaNet layer with its gates pinned
  is exact, addressable RAM, and compiled a filesystem into extra layers of Qwen 3.5 4B. We checked
  every link of that claim on our own stack. tang's kernel stores and reads one-hot rows bitwise,
  and stays exact over a 50,000-step free run. Trained heads cannot do it: on GLM-5.3-Flash, none of
  8,192 channels per layer keeps its gate at exactly 1. We reproduced the author's filesystem on an
  RTX 3090, with the model issuing every store call itself and recalling files from a 14 KB state
  file in an empty conversation. tang's reference math then ran the author's compiled layers
  bitwise. tang's own Rust compiler emitted all 168 tensors of them bitwise. A CUDA window in our
  engine ran them bitwise at about 0.9 ms per token, roughly 25 to 40 times faster than the author's
  stack. Along the way we tested two ways to get "instant prefill" from the same structure, and
  both fail. The result is memory that costs no context, needs no training, leaves the model's text
  unchanged, and can be held by the user rather than the provider.
]

= Motivation

A coding agent's memory today is text. Notes, summaries and retrieved chunks are pasted into the
prompt, prefilled on every turn, and compete with code for the context window. On a 16 GB laptop
running a 4B model, context is the scarcest resource there is. The alternatives in the literature
all pay somewhere else. KV caches are exact but huge and model-locked. Learned fixed-size states
cost zero context but are lossy. Test-time training writes facts into weights, at the price of
optimizer state and forgetting.

On 28 October 2026, qwenputer
#footnote[Post: #link("https://divagr.com/blog/qwenputer")[divagr.com/blog/qwenputer]. Code:
#link("https://github.com/divagr18/qwenputer")[github.com/divagr18/qwenputer] (MIT).] showed a
fourth option. Gated DeltaNet (GDN) updates a per-head matrix state with the delta rule:

$ S_t = g_t S_(t-1) + beta_t k_t (v_t - S_(t-1)^top k_t)^top $

With the decay $g = 1$, the write strength $beta = 1$ and a one-hot key $k = e_i$, the update
replaces row $i$ of $S$ with $v$ and leaves every other row untouched. A one-hot query reads row
$i$ back. Compile weights that produce those gates and keys, and the recurrent state is RAM. The
author compiled a RISC-V CPU and a 512-file store into 12 extra layers in front of Qwen 3.5 4B,
without training, and reported a KL divergence to the base model of $6 times 10^(-4)$.

tang is frog's own inference engine. It implements the forward pass of Qwen3-Coder-Next, a hybrid
model with 36 GDN layers and 12 attention layers, and already snapshots the fixed-size recurrent
state to disk. That makes the question concrete: what of this transfers to an engine we own?

= Exact RAM in tang's kernel

tang pins the GDN recurrence in a CPU specification that the CUDA kernel is verified against
bitwise. We tested the claim there.

- *The gates reach exactly 1.* Projections of $a + "dt" = -30$ and $b = 40$ give
  $exp("softplus")$ and $sigma$ values that round to exactly `1.0f` in f32.
- *A write into an empty row stores $v$ bitwise* and touches no other row of any of the 48 heads.
- *An overwrite* stores $"fma"(1, v - s, s)$. That is exactly $v$ whenever $v - s$ is exact. On
  random floats in $plus.minus 1000$, 8,643 overwrites were exact and 15,933 were off by one
  rounding. So stored values must be integers below $2^24$.
- *A 50,000-token free run*, driving the kernel as a register machine, matched a plain model
  bitwise throughout, on the CPU and on an RTX 3090.
- *One token with $g < 1$ ends exactness for good.* Every row is scaled by a non-power-of-two and
  the integers turn fractional.

= Trained heads cannot do it

The last rule means a pretrained head cannot be borrowed for storage unless its gate is bitwise 1
on every token. We measured the real gates of GLM-5.3-Flash, whose recurrent layers use Kimi Delta
Attention, a per-channel-gated delta rule. The run covered 427 tokens of prose and all 34
recurrent layers on an RTX 3090.

#figure(
  table(
    columns: 5,
    align: (left, center, center, center, center),
    [Layers], [mean $g$], [best channel min $g$], [mean / max $beta$], [channels at 1.0 on every token],
    [early (0–10)], [0.51–0.68], [0.999994], [0.54–0.71 / ≤0.997], [0 of 8,192],
    [mid (12–26)], [0.73–0.87], [0.999999], [0.64–0.77 / ≤1.000], [0 of 8,192],
    [late (28–44)], [0.67–0.79], [0.999997], [0.55–0.84 / 1.000], [0 of 8,192],
  ),
  caption: [Gate statistics of a trained hybrid model. No channel qualifies as exact storage.],
)

A few channels are remarkably slow. Between 1 and 8 percent per layer have a mean gate above
0.999, and the best has a gate-only half-life near three million tokens. But they are analog,
lossy registers. Exact storage needs dedicated heads with compiled gates, which is the qwenputer
design.

= Two dead ends: instant prefill

The same structure suggests faster prefill, and we tested both versions.

*Poking state.* A trained head can only read state its own prefill would have produced. An integer
written into a row means nothing to it, so poking context into state collapses back into prefill.

*Chunked kernels.* tang steps the GDN recurrence serially per token. A chunked tensor-core form has
roughly 35 times the throughput at a 512-token window. But on an RTX 3090 the recurrence is about
4.5 percent of a prefill window, and 5.5 percent on an H200 baseline. Two chunked kernels already
existed in tang. The first ran slower than baseline on an H200. The second needs 150 KB of shared
memory per block and has never been compiled. Prefill time lives in attention and the MoE layers.

*Precomputed chunk maps.* The delta rule is affine in $S$, so a chunk of text collapses to one
matrix pair per head. If a chunk's keys and values did not depend on earlier context, prefill
would be a few matrix products. We spliced context-free chunks into real GLM-5.3-Flash runs.

#figure(
  table(
    columns: 4,
    align: (left, center, center, center),
    [Spliced chunk], [state error early / mid / late], [KL next 32 tokens, mean / max], [top-1 agree],
    [4], [0.34 / 0.65 / 0.54], [0.095 / 0.80], [30 / 32],
    [8], [0.30 / 0.62 / 0.46], [0.103 / 1.13], [27 / 32],
    [12], [0.44 / 0.98 / 0.60], [0.111 / 0.89], [31 / 32],
    [skip control], [0.5–0.7], [0.30–0.58 / 3.7–5.5], [26–28 / 32],
  ),
  caption: [Context-free chunk precomputation. About 0.1 nat per token, not lossless.],
)

Mid and late layers depend on context, not position. Fixing the error means recomputing most of
the depth, which is prefill again. Instant restore of _old_ context remains what tang already
ships: a resumed 7,000-token session prefills in about 0.1 s from the snapshot disk tier.

= The store, end to end

== Phase 1: an engine-driven store

We first built the store without any compiled layers: a key-value file store in dedicated GDN heads
of one layer. Every write and read goes through the real kernel with one-hot keys and pinned gates.
The layout follows the author's: a hashed directory with linear probing and tombstones, plus content
rows of token ids. Reads pass through the output norm and a division, about eight roundings, so
values stay below $2^18$. A marker column restores the scale the norm discards.

#figure(
  table(
    columns: 4,
    align: (left, center, center, center),
    [Layout], [heads (k / v)], [directory], [content],
    [Flash-Next], [16 / 48, tiled], [1,024 slots, 512 files], [65,024 tokens, 768 KiB],
    [Coder-Next, Qwen 3.5 4B], [16 / 32, grouped], [512 slots, 256 files], [65,024 tokens, 512 KiB],
  ),
  caption: [Store capacity in a quarter of one layer.],
)

A 1-row put or get costs two windows. A 512-file fill and a 10,000-operation random workload,
checked against a hash map, both pass. The store persists through the bytes tang's snapshot
already carries. It also transfers into a different conversation's state with that conversation's
base heads bitwise untouched.

== Phase 2: the model drives it

*Reproduction.* We ran the author's code and checkpoint on an RTX 3090. In one conversation the
model issued all nine store calls itself: three puts, a list, three gets, a delete and a list.
Each answer was printed by the model, and 160 printed tokens matched the author's reference with
zero mismatches. We saved the state to a 14 KB file and reloaded it into an empty conversation.
The model listed the two surviving files and read both back exactly. KL to base Qwen was
$6.9 times 10^(-4)$ against a noise floor of $6.7 times 10^(-4)$, and bitwise identical with files
loaded or not.

*tang runs the compiled layers.* tang's reference math ran the checkpoint's 12 compiled layers on
the author's teacher-forced trace. All 126 fed tokens were identical, and every store head's
$128 times 128$ state was bitwise equal after each operation, with bf16 rounding at the same points
as the reference implementation.

*tang compiles them.* `tang-chip`, a Rust port of the author's lowering, emits the layers from the
exported circuit graph: 3,753 dims, 164 heads and 47,532 units. At Qwen 3.5 4B shapes, all 168
tensors equal the checkpoint bitwise in bf16, zero padding included: 2.44 billion elements, of which
1.24 million are nonzero. Retargeted to Coder-Next shapes, with hidden 2048 widened to 3968 by
1,920 chip dims, put, get and list replay the trace bitwise and no weight touches a host dimension.

*tang serves them on the GPU.* A chip window in the Coder engine uploads the emitted layers as
sparse blocks and runs store calls as engine-internal windows. They never touch the base layers,
the LM head or the KV cache. On an RTX 3090, a shadow-and-poison check found 0 mismatching layer
steps over 126 tokens and 12 layers against the CPU path.

#figure(
  table(
    columns: 4,
    align: (left, center, center, center),
    [Operation], [tokens fed], [time per op], [time per token],
    [put], [56], [51 ms], [0.92 ms],
    [get], [43], [40 ms], [0.92 ms],
    [list], [27], [25 ms], [0.93 ms],
  ),
  caption: [Chip window on an RTX 3090 with CUDA graphs. The author's PyTorch stack took 1.0–1.65 s per op.],
)

The compiled layers take 13.75 MB of sparse weights and 26 MB of state per slot at Coder-Next
width. Their nonzero blocks cost about 332 million multiply-adds per token, roughly 8 percent of
the 4B model's.

== Serving and the client

tang serve exposes per-session endpoints to load a store blob, run an operation, export and end.
An ephemeral mode zeroes the store heads on slot reuse, eviction and session end. It also blanks
them before any shared-prefix snapshot and writes them to the disk tier as zeros. frog probes for
the feature once per session, loads the user's blob, saves after every write and offers the model a
`Memory` tool. `frog memory dump` prints exactly what is stored.

= Privacy

The persistent part of memory becomes a file on the user's disk, of about half a megabyte. In a
cloud session the provider loads it, sees it in plaintext while the session runs, and with the
ephemeral flag keeps nothing afterwards. This is not encryption: the layout is known, and anyone
holding the blob can read it. Confidentiality during a session would need GPU trusted execution.
The model can still leak what it reads through its own output, so egress controls matter as much
as before. What changes is where memory accumulates: in a file the user can read and delete,
rather than with the provider.

= Related work

Compiled memory occupies a corner of the design space that nothing else holds: exact recall, zero
context, no training, near-zero change to the base model. Text memory systems such as MemGPT, Mem0
and A-MEM are portable, mature and need no training, but pay context on every turn and recall
lossily. KV reuse, as in prefix caching and CacheBlend, is exact but large and model-locked.
Learned fixed-size states such as Gated DeltaNet, Titans and In-Place TTT cost no context but are
lossy and need training. Knowledge editing and one-step LoRA memory are dominated: one 2026 study
measured free-form recall at zero after LoRA updates. Compiled transformers trace back to Tracr,
which compiled RASP programs into weights for interpretability. The linear-RNN layers of hybrid
models are what made exact RAM, and so a compiled store, possible. A fuller survey is in
`docs/research/memory-pareto.md`.

= Limitations and open questions

- *No cross-session benchmark yet.* The 90 percent recall figure is the author's own fact set.
  Compiled memory has not been run on LongMemEval or LoCoMo against Mem0 or LiveMem.
- *Does the model reach for it?* The author's 4B model used the store when it was asked to. Whether
  Coder-Next uses memory at the right moments in a long coding session is unmeasured, and it is the
  main product risk.
- *No real Coder-Next build.* It needs the circuit re-exported with Coder-Next's tokenizer and run
  on its weights, on hardware that holds them.
- *Capacity is fixed.* 256 to 512 files, and frog currently stores text as one byte per id,
  about four times the slots real tokens would use.
- *Compute on every token.* About 8 percent at 4B scale, less in relative terms on a 3B-active MoE.
- *Exactness is the engine's invariant.* One normal token through a store head corrupts it. tang
  pins the gates by construction and audits stores before export.

#v(1em)
#text(size: 9pt, fill: rgb("#555"))[
  Code: tang branches `frog/gdn-one-hot-ram`, `frog/gdn-freerun`, `frog/gdn-poke-probe`,
  `frog/gdn-prefill-bench`, `frog/gdn-splice-probe`, `frog/gdn-memstore`, `frog/gdn-memstore-32`,
  `frog/gdn-memserve`, `frog/gdn-chip`, `frog/gdn-chip-compiler`, `frog/gdn-chip-engine`; frog PRs
  ecto/frog\#121 and ecto/frog\#130. Thanks to Divyansh Agrawal for publishing qwenputer under MIT.
]

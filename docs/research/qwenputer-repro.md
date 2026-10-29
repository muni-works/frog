# qwenputer filesystem: reproduction on mew (RTX 3090)

Date 2026-10-28. Machine `mew` (RTX 3090 24 GB, torch 2.10.0+cu128, transformers 5.20.2, no
`flash-linear-attention` / `causal_conv1d`, so the HF reference GDN kernels were used). GPU taken
under `flock ~/tang-gpu.lock`. Other tenants held about 2.8 GB of the GPU throughout.

## What ran

- Repo `github.com/divagr18/qwenputer` (MIT), branch `rv-store`. The Filesystem checkpoint is
  the **RISC-V variant**, `experimental/riscv` (`chipformer/rv/store.py`, `store_rv.py`,
  `chat.py`, doc `experimental/riscv/docs/rv-store.md`). It is not the q35 v1 store in
  `chipformer/q35/store.py` / `docs/q35-store.md`, which uses ADDR/VAL pairs and a linear
  search. v2 uses single-token records and a hashed directory.
- Weights: `divagr1925/Qwen3.5-4B-Qwenputer-Filesystem` (21 GB on disk) and `Qwen/Qwen3.5-4B`
  (9 GB, used only for KL). Fetched with `huggingface_hub.snapshot_download` (no hf_transfer
  installed), about 6 min in total.
- Driver: the author's `RvChat` (fast path: HF modules, chip layers as one CUDA graph). Our own
  scripts in `~/qwenputer-repro/scripts` import it and run with `python3 -P -E`. `-I` would also
  hide the user site-packages that hold torch on mew. Copies are in
  `/private/tmp/claude-501/qwenputer-traces/`.
- **Did not run as-is:** `RvChat.generate` hit an OOM in the prompt prefill on the 3090 with
  2.8 GB taken by other processes. The checkpoint itself used 20.3 GB allocated, against the
  card's quoted "about 18 GB". The fix was our own decode loop: a copy of `generate`'s fast path
  with the prefill done in chunks of 128 tokens and the same per-token logic (the circuit's token
  wherever it owns the position, otherwise Qwen's argmax). We replaced `generate`'s live
  reference lock with a check after the run: the reference `StoreSession` is fed Qwen's tokens
  and must emit exactly the circuit's tokens.

## Step 2: filesystem round trip (Qwen deciding, greedy)

Session A asked Qwen to put a.txt / b.txt / c.txt, list them, get each one, delete b.txt and
list again. Qwen made all 9 calls itself. Every `<tool_response>` was printed by the model:

```
put a.txt "apples are red"     -> ok          trace SP(996) SN(0) SO(0)
put b.txt "bananas are yellow" -> ok          SP(1009) SN(1) SO(1)
put c.txt "cherries are dark"  -> ok          SP(324) SN(2) SO(2)
list                           -> a.txt b.txt c.txt      SL(0) SL(1) SL(2)
get a.txt / b.txt / c.txt      -> the exact texts         SP(996) SG(0) / SP(1009) SG(1) / SP(324) SG(2)
delete b.txt                   -> ok          SP(1009) SD(0)
list                           -> a.txt c.txt             SL(0) SL(1) SL(2)
```

The reference check passed: 160 circuit-owned tokens, 0 mismatches. The run took 536
positions: 23 chip records, 122 response tokens printed by the circuit and 375 Qwen tokens, in
16.3 s.

**Save / reload.** `save_store()` was written to `memory.npz` with the author's
`save_store_file` (14 KB compressed, sparse rows). Session B was a new prompt with an empty
context and the store loaded (`store_snap = load_store_file(...)`). Qwen called `list`, which
printed `a.txt c.txt`, then `get` on both, which printed "apples are red" and "cherries are
dark". It answered with both. Trace `SL(0) SL(1) SL(2) SP(996) SG(0) SP(324) SG(2)`. The
deleted file stayed deleted: `SL(1)` hits the tombstone and prints nothing. **Reproduced.**

## Step 3: numbers

Latency comes from a teacher-forced script (the call tokens forced, the circuit's answer
decoded) on an empty store at batch 1, run 3 times. The 3 runs agreed to within 3 ms. The
times cover every position of the op: the call Qwen writes plus the circuit's answer.

| op | s | positions | forced call tokens | chip records | response tokens printed by circuit |
|---|---|---|---|---|---|
| put (new name, 3-token text) | 1.65 | 55 | 39 | 3 (SP SN SO) | 12 |
| list (3 names) | 1.02 | 35 | 12 | 3 (SL x3) | 17 |
| get (found, 1 chunk) | 1.27 | 42 | 24 | 2 (SP SG) | 14 |
| delete | 1.20 | 40 | 25 | 2 (SP SD) | 12 |
| list (after delete) | 0.93 | 32 | 12 | 3 | 15 |

That is about 30 ms per position, and the cost is in our software stack: the reference
PyTorch GDN kernels plus Python. The circuit's own overhead is only the chip records, 1 to 3
tokens per op. Each circuit-printed token costs one decode step, the same as a Qwen token.

**Text KL vs base** (our method, close to the author's `rv/textcheck.py`). 516 tokens of plain
English prose (`text.txt`), teacher-forced. Base Qwen3.5-4B is run in one forward (sdpa), and
its log-softmax over Qwen's 248,320 ids is compared with the merged model's per-token decode,
KL(base || merged), mean over 515 positions. The noise floor is base sdpa vs base eager. We ran
the merged model twice: once with an empty store and once with session A's `memory.npz`
injected.

| | mean KL | median | max | top-1 agree |
|---|---|---|---|---|
| merged, store loaded | 6.94e-4 | 4.6e-4 | 7.3e-3 | 98.8% |
| merged, empty store | 6.94e-4 (bitwise identical) | | | |
| noise floor (sdpa vs eager) | 6.69e-4 | | | |
| author (rv-store card / doc) | 5.48e-4 vs floor 5.07e-4 | | | |

The ratio to the floor is 1.04x here and 1.08x for the author. The circuit never fired on the
prose (0 owned positions). The stored files have exactly zero effect on Qwen's logits, which
fits the exit clearing every chip dim before Qwen's layers. Our absolute numbers are higher than
the author's because the method differs: a different text, and the merged side decodes token by
token while the base side does one prefill.

## Step 4: layout for the port

Checkpoint config (`config.json` + `chipformer.json`):

- `Qwen3_5ForCausalLM`, 44 layers: **12 compiled chip layers (0..11, all linear_attention)**,
  then Qwen's 32 (12..43, full attention every 4th).
- hidden 4608 = Qwen's 2560 (dims 0..2559) + chip dims 2560..4607 (`chip_dims_offset` 2560;
  18 ballast dims; IR 3753 dims packed into 1806 residual slots). Output code dims 2710..2730,
  id-code dims 3146..3163, tau 2733, mu 2732.
- GDN: 16 key heads, 32 value heads (2 per key head), d_k = d_v = 128, conv kernel 4,
  intermediate 9216. vocab 484,800 = Qwen 248,320 + 236,469 chip tokens (offset 248320).
- Circuit: 164 key heads, 47,532 FFN units. Store: 512 chunks, 1024 dir slots (10 bits), hash
  seed 2035.

Store heads (layer, key head -> value heads), 49 key heads and 94 value heads:

| table | layer: key heads | v heads each |
|---|---|---|
| regs (NEXTG, NORD, GCUR, LCUR) | L1: kh4 | 1 (vh 8) |
| order | L4: kh10-11 | 2 |
| len | L5: kh10-11 | 2 |
| dir (1024 slots = 8 heads x 128 rows) | L9: kh1-8 | 2 |
| next | L10: kh0-3 | 1 |
| content (512 chunks x 8 rows x 14 tok) | L9: kh9-15, L10: kh4-15, L11: kh1-13 (32) | 2 |

State tensor: `cache.layers[L].recurrent_states[0][b, vh, 128 (key dim / row), 128]`, fp32
(`mamba_ssm_dtype`), with vh = kh*2 + x. Keys are one-hot rows, so a slot s lives in dir head
s // 128, row s % 128. For example a.txt hashes to slot 996: dir7, row 100, nonzero in both
value heads after the put. regs uses rows 0, 1 and 127. The snapshot holds the nonzero rows of
these heads only. Conv states are not included.

Gate and beta pinning. In the RV copy this is `experimental/riscv/chipformer/q35/emit.py:245-246`
(identical in `chipformer/q35/emit.py:265-266`). The `in_proj_b` row is `128*ONE`, so
beta = sigmoid(128) = 1. A write-gated value head instead uses `256*g - 128`, which gives
sigmoid(+-128): exactly 1 or 0. At `:284-285` (`:309-310`) the compiler sets `dt_bias = -110`
and `A_log = 0`, so g = -softplus(a - 110), which underflows to 0 in fp32 when a = 0: decay
exactly 1, no forgetting. A decaying head drives `in_proj_a` through `vhd.a`. The
`norm.weight` rows are 1. All chip-layer RMSNorm weights (input/post) are 0 and rely on the
ballast dims.

Ground-truth traces are under `~/qwenputer-repro/traces` on mew and in
`/private/tmp/claude-501/qwenputer-traces/`, with a README:
`trace_put_get_list.safetensors` (659 KB) holds put("a.txt", 5 ids), get and list. For each
op it has the token ids, the chip flag, and the nonzero rows of every store head's state. regs
and dir0 are also stored dense. `layout.json` maps all 164 chip heads. `memory.npz` is the
session-A snapshot.

## Not reproduced / caveats

- `RvChat.generate` OOM on the shared 3090 (see above). We worked around it with our own
  chunked-prefill loop. We did not test the author's `--memory` CLI unmodified.
- We did not run the author's IR replay (`chat.replay`, full IR evaluation on CPU) or the
  benchmark suites. Exactness was checked against the reference StoreSession only.
- The latency numbers are for HF reference kernels without fla. They will not match a fused
  kernel or the author's executor (`--executor`, Triton) numbers.
- The KL text and method are ours (above), not the author's PROMPTS set.

## Cost

Disk: 30 GB of weights downloaded, deleted after the run. `~/qwenputer-repro` is now 16 MB
(repo, scripts, traces). Wall time on mew was about 25 min: 6 min download, about 2 min GPU
for the trace, about 3 min for the chat and timing runs, about 2 min for KL, plus setup.

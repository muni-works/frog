# Private RAG: search and answers the server can't read

2026-10-17. Working name for the feature: **hush**.

## TL;DR

- **frog can search a library it doesn't trust and answer from it, without the library's server ever seeing the question, the matches, or the answer.** Retrieval runs under lattice encryption on the server's GPUs. Generation runs on your own machine through the tang sidecar, which already decodes Qwen3-8B at 100+ tok/s. Keys never leave your devices.
- It is the cryptographic form of two existing bets: **"your devices, additive"** (ROADMAP bet 3) and **"Frog Pro on a tang-backed gateway … included search"** (bet 5). It closes threat 5 in `knowledge-systems.md` ("privacy leakage to cloud providers") for search, without giving up the cloud.
- The pieces mostly exist: **ryng** (a post-quantum KEM and signature written as tang mod-q graphs, with Metal/CUDA lowering and a machine-code constant-time check) and **tang-llm** (Qwen through the tang IR). New work: a retrieval parameter set, the scoring graphs, a sealed library format, a `Search` tool, and a receipt pane.
- **Ship laptop mode first** (encrypted retrieval + local generation): fully private, and fast today. **Cloud mode** (generation under encryption, for phones) is the research ladder: the best published fully homomorphic 8B runs at about 18 s/token on 8 GPUs, against tang's 122 tok/s in plaintext on one 3090.

## 1. What the user gets

One question, two modes, the same receipt.

| | Laptop mode | Cloud mode |
|---|---|---|
| Retrieval | encrypted, on the server | encrypted, on the server |
| Generation | local: tang sidecar, Qwen3-8B, ~100+ tok/s | encrypted, on the server: small model, slow today |
| What the server learns | nothing about the question, the matches or the answer | the same |
| Ships | first | research |

The receipt is the point of the UI. Next to every answer, a pane says what the server saw: the size of the sealed query, how many documents it scanned (all of them), that the answer never left the machine (laptop mode), and "learned: nothing", which is a cryptographic statement, not a policy.

## 2. Architecture

```
 YOUR DEVICES (every key)                         THE CLOUD (no keys)
 ┌───────────────────────────┐                   ┌─────────────────────────────┐
 │ frog (TUI / Mac app)      │  sealed query ──▶ │ encrypted retrieval         │
 │  1 embed query locally    │                   │  scans every document,      │
 │  2 encrypt (ring-LWE)     │ ◀── sealed scores │  ct × plaintext on GPU      │
 │  4 decrypt, pick top-k    │                   │                             │
 │  5 private fetch (PIR)    │  PIR request ───▶ │ encrypted library           │
 │  6 answer locally (tang)  │ ◀── sealed docs   │  public corpus, or your own │
 │                           │                   │  documents, still sealed    │
 │ phone / browser (WASM)    │  sealed prompt ─▶ │ encrypted inference (later) │
 └───────────────────────────┘                   └─────────────────────────────┘
        ryng: post-quantum identity and channels on every arrow
        tang IR: one graph per stage → WASM · Metal · CUDA · C
```

Three design choices carry the system:

1. **The server holds no secret.** Scoring is "encrypted query × public document vector". All secret material lives on the client, so constant-time discipline matters only there, and the tang mod-q IR already enforces it (secrecy labels, machine-code lint). The server just runs public arithmetic fast.
2. **Coefficient packing, so no rotations or key switching.** The query is encoded as a ring polynomial and each document's embedding with its coefficients reversed. One ring multiply puts the inner product in a fixed coefficient. The server's work is NTT-domain pointwise multiplies and adds: the same operations ryng already runs on Metal at batch scale. None of FHE's expensive machinery (rotations, relinearization, bootstrapping) is needed for retrieval.
3. **The server scans everything.** If it skipped any document, which ones it skipped would leak the query. GPU throughput is the whole game. Fetching the winning documents uses private information retrieval (also lattice-based), so the fetch doesn't leak them either.

## 3. Retrieval

**Scheme.** Ring-LWE under a secret key held by the client (symmetric encryption suffices: the client both encrypts the query and decrypts the scores, which keeps noise low). Plaintext-ciphertext multiply, then add. No ciphertext-ciphertext products in the public-corpus case.

**Parameters.** ryng's modulus (q = 8380417, 23 bits) is too small: one score sums ~768 products of 8-bit values, so the noise needs room for about 2¹⁷ growth plus the score itself. Target a ~60-bit modulus as two or three NTT-friendly ~30-bit primes (RNS), each its own mod-q graph run in parallel. Ring dimension 2048–4096 so one ciphertext packs several documents. Derive the set the way ryng's was derived: a predicate, the lattice estimator, and a rigorous failure bound, all checked in.

**Embeddings.** A small embedding model run locally (tang, Metal or WASM), quantized to 8 bits or fewer, optionally projected to 256 dimensions. Smaller vectors mean fewer ring multiplies per document.

**Scale, honestly.** The server's cost per query is linear in the library: every document is touched. Pre-transformed (NTT-domain, RNS) document plaintexts are several times the size of raw int8 embeddings. A 100k–1M document library is the first target. Beyond that, cluster first, as Tiptoe does: an encrypted pass over cluster centroids, then a scan of the chosen clusters, with PIR so the server can't tell which.

**Prior art to build on and beat.** This is the shape of Tiptoe (Henzinger et al., SOSP 2023: private web search over hundreds of millions of pages with lattice encryption). Recent encrypted RAG retrieval: GoldenRetriever ([2607.29019](https://arxiv.org/abs/2607.29019), non-interactive) and PRAG ([2604.26525](https://arxiv.org/abs/2604.26525), end to end). What frog adds: one IR across client and server, a Metal backend (every GPU FHE library found targets CUDA), and the receipt.

### Step 1 results (2026-10-17, tang `claude/hush-retrieval`, `crates/hush`)

The standard set derives from (d = 128, 4 bits, n = 2048, η = 2): t = 2¹⁴, noise bound B = 28,672, **q = 1,476,513,793** (the smallest prime ≡ 1 mod 4096 above 2t(t + B); 30.5 bits against the standard's 54), ζ = 147,080. Primal core-SVP: 2²⁰² classical, 2¹⁸⁴ quantum. Decryption is **exact**, not probabilistic: Q > 2t(t + B) makes the rounding error provably below ½, and a test drives an adversarial error to the bound exactly and still decrypts every score. 256 dimensions or 8-bit values need 32–46 bits, so two RNS primes.

Measured on an M4 Max (release), 100,000 documents, every score equal to the plaintext inner product:

| Step | Time |
|---|---|
| encrypt the query (client) | 2.6 ms |
| score every document (server, Metal) | 125 ms wall, 32 ms device |
| decrypt every score (client GPU) | 110 ms |
| query / response | 16 KB / **52 MB** |

The open problem is the response. Decrypting a score needs the whole a·p polynomial, so it costs ~0.5 KB per document. That is fine to your own gateway on a LAN, and wrong over the internet. The known fixes are hint compression (Tiptoe) and LWE-to-RLWE packing keys (HintlessPIR, YPIR); this is now step 5's first item.

## 4. Two kinds of library

| | Whose secret | Server stores | Server computes | Cost |
|---|---|---|---|---|
| **Private questions** | your queries | a public corpus (docs, papers, a codebase's dependencies) | encrypted query × plaintext docs | cheap: section 3 as written |
| **Private documents** | your files and your queries | your documents' embeddings, encrypted, plus the documents sealed with AES-GCM | encrypted query × encrypted docs | one ciphertext-ciphertext multiply per score; no bootstrapping |

The second is Crypton's container model with search added: storage was already zero-knowledge, and now search is too. Sealed documents are encrypted to the user's ryng key, and sharing a library with another user is one ryng `seal` of its key, as Crypton's container session key shares were.

## 5. Generation

**Laptop mode: local.** The tang sidecar already serves Qwen3-8B (4-bit) through the IR. On an RTX 3090 that is 122 tok/s per decode step (55% of the memory-bandwidth limit), 104 tok/s at 4k context, 774 tok/s prefill, and 52–217 tok/s through the tang-llm engine with speculative drafting (tang `BENCHMARKS.md`). Metal is ~10 tok/s today at 8% of its limit, with the headroom that implies. Privacy here comes from locality, and costs nothing.

**Cloud mode: encrypted.** For devices that can't run 8B. The literature's frontier (late 2026):

| Result | Model | Speed | Note |
|---|---|---|---|
| [2601.18511](https://arxiv.org/abs/2601.18511) | Llama-3-8B, FHE | 18 s/token on 8 GPUs | current high-water mark |
| [Cachemir, 2602.11470](https://arxiv.org/abs/2602.11470) | Llama-3-8B, FHE | < 100 s/token, 1 GPU | encrypted KV cache |
| [Odin, 2609.12378](https://arxiv.org/abs/2609.12378) | Llama-3-8B, FHE | 366 s for a 128-token prompt, 1 H100 | open source |
| [PermLLM, 2405.18744](https://arxiv.org/abs/2405.18744) | ChatGLM-6B, 2PC | ~3 s/token | permutation schemes later attacked ([2505.18332](https://arxiv.org/abs/2505.18332)) |

The gap to tang's plaintext Qwen is roughly 2,000–4,000×. frog's route through it uses tang twice: the same IR that serves Qwen gets an FHE lowering, and tang trains encryption-friendly variants (polynomial softmax, [CGF-Softmax 2602.01621](https://arxiv.org/abs/2602.01621); fewer sequential nonlinearities, [2607.04819](https://arxiv.org/abs/2607.04819); [encryption-friendly LLMs 2410.02486](https://arxiv.org/abs/2410.02486)) in the same IR it serves them from. Ladder: a ~0.5B Qwen under encryption for phones, then encryption-friendly variants, then 8B.

## 6. Identity and channels: ryng

Every arrow in section 2 is sealed and signed with ryng: a KEM handshake for the session key (AES-256-GCM for traffic, which keeps ~128-bit security against Grover), and signatures on requests and library writes. Public keys 1312 B (KEM) and 1952 B (signature); a ciphertext 1440 B; a signature 3309 B.

Identity cards, as Crypton had them: a QR code with the username and a SHA-256 fingerprint of both public keys, plus Crypton's cascading colorized fingerprint. One change: a ryng signature (3.3 KB) does not fit in a QR code (~2.9 KB binary max), so the card carries the fingerprint only, and key possession is proven live at scan time with a signed challenge. A static signature on a card could be replayed anyway.

Login stays the open piece. SRP, which Crypton used, is discrete-log based and breaks under Shor. KEM-based PAKEs (CAKE/OCAKE-style) can be built from ryng's KEM; that is its own design.

## 7. In frog

- **A `Search` tool**, alongside `Recall` and `WebSearch`: read-only, deterministic budgets per model tier, compact hits with citations. It runs the client side of section 3 (embed, encrypt, decrypt, PIR) and returns plaintext hits only to the local engine.
- **Protocol:** search is an ordinary item (`started → completed`) whose completed payload carries the receipt (bytes sent, documents scanned, what left the machine). Clients render it; the Mac app shows it as a pane beside the answer.
- **Where the server lives:** the Frog Pro gateway (bet 5) hosts encrypted libraries and the retrieval GPUs. A second machine you own (bet 3, `frog node`) can host a library too, and then nothing leaves your devices at all.
- **Prompt-cache friendliness:** hits enter as tool output, never the frozen prefix (knowledge-systems principle 7).

## 8. Threat model

**Protected:** the query, which documents matched, the scores, the retrieved documents' identities (with PIR), the answer (laptop mode: never leaves; cloud mode: generated under encryption), and, in private-documents mode, the documents themselves. All against a server that is curious, and against a future quantum adversary (ryng and the retrieval scheme are lattice-based).

**Not protected, by design or for now:**
- **That you searched, when, and how often.** Traffic analysis, as Crypton's threat model noted. Mitigate with Tor or batching.
- **Library size and which library.** The server knows what it hosts.
- **A malicious server returning wrong results.** Encryption hides; it doesn't verify. Proofs that the server ran the agreed scan (sumcheck/GKR over the scoring graph; see [2607.21162](https://arxiv.org/abs/2607.21162) for GKR over transformer inference) are later work.
- **A compromised client.** Keys live there.
- **Code delivery in the browser.** As Crypton said: ship packaged apps (frog's TUI and Mac app are), and treat a web client as a demo.

## 9. Shipping order

1. **Retrieval parameter set and graphs. Done** (section 3, step 1 results): exact decryption by construction, Metal scoring and decryption, 100k documents in ~240 ms end to end.
2. **Laptop mode end to end on a public corpus.** A document set of 100k, encrypted query in, top-k out, local Qwen answer, receipt pane. This is the demo.
3. **PIR fetch.** Hide which documents were retrieved.
4. **Private-documents libraries.** Sealed documents and encrypted embeddings; sharing by ryng `seal`.
5. **Scale.** Response compression first (hint compression or packing keys: 52 MB per 100k documents today), then clustering plus PIR for million-plus libraries; CUDA on the gateway.
6. **Cloud mode, research.** Encrypted small-model generation; encryption-friendly Qwen variants trained in tang.
7. **Proofs, research.** The server proves it scanned what it should have.

## 10. Open questions

- The exact retrieval parameters (ring size, moduli, packing density) for 768- vs 256-dimension embeddings, and what quantization costs in recall.
- Server cost per query at 100k, 1M, 10M documents on Metal and CUDA; where clustering must start.
- Private-documents mode: ciphertext-ciphertext scoring cost, and whether a two-server variant is worth its weaker trust assumption.
- The PAKE for login.
- How the receipt states its guarantees without overclaiming (it must not say "learned nothing" about anything in "Not protected").

All cryptography here is new or unaudited. Nothing ships as a privacy guarantee before outside review, and ryng itself is research code until it has been attacked in the open.

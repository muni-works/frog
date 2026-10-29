# Beat 1 launch post (draft)

Status: DRAFT for Oct 30. `{{…}}` marks a number that lands this week; fill it from
[bench.md](bench.md) or delete the sentence. Nothing in here may be stronger than its receipt.
Editor notes are HTML comments and get stripped before publishing.

---

## HN submission

**Title:** Show HN: frog – a free, open coding agent, and an inference engine that checks its own GPU kernels

**Text (first comment):**

> I'm Cam. I build frog, a terminal coding agent for local models (MIT/Apache-2.0), and tang, the
> inference engine under it. On Monday our new GPU path for GLM-5.3 produced garbage while every
> unit test passed. The cause was four structural bugs, one of them an element offset added to a
> byte address. We turned the tools that found them into a harness that checks every GPU kernel
> against a CPU oracle. The post has a script that plants the bug again and shows the harness naming
> it in one run. There's also a hosted Qwen3-Coder-Next endpoint if your laptop is slow. Happy to
> answer anything.

---

# frog: a free coding agent, and an engine that checks its own kernels

frog is a coding agent that lives in your terminal. It's free and open source (MIT OR Apache-2.0),
it runs models on your machine by default, and it works with ollama, LM Studio, Anthropic and
OpenAI if you'd rather use those.

```sh
curl -fsSL https://frog.toys/install.sh | sh
cd your-repo && frog
```

Underneath it is **tang**, our inference engine. On a Mac it runs the default model
(`local/qwen3-4b`) on Metal with nothing else to install. On NVIDIA it serves **frog cloud**, a
hosted Qwen3-Coder-Next for when local is too slow. This post is mostly about tang, because of a bug.

## The bug that every test missed

On October 26 we brought up the GPU path for GLM-5.3-Flash, a large MoE model, in tang. It
produced garbage tokens while every unit test passed. Four bugs were behind it, and none of them was
subtle numerics:

| # | bug | why the tests missed it |
|---|---|---|
| 1 | the k and v projections launched at `ptr + di` with `di` in **floats**, but a device pointer counts **bytes** | the dumps printed `q[0..16]`, the one region nothing overwrote. Unwritten v read 0.0, which looks plausible |
| 2 | one attention object served all 11 DSA layers, so every layer used layer 3's weights | the test fixture has one DSA layer |
| 3 | the GPU mixer ran block 0's weights for block 1 too | every test run put that mixer on the CPU |
| 4 | contexts dropped before their streams at teardown | the GPU test "passed" by skipping when it found no GPU |

Each bug was found by instrumentation we wrote that night. We've now made that instrumentation
the rule. **tang-verify** checks every GPU kernel against its CPU reference, both when the kernel is
written and in any engine run with one env var (`TANG_KERNEL_VERIFY=1`). It does four things:

- **Shadow.** It runs the CPU reference on the same input the GPU got, resynced to the GPU's own
  state each window, so every comparison tests one step rather than accumulated drift. It compares
  every element of every intermediate, not a 16-value prefix.
- **Poison.** It fills each output buffer with NaN before the kernel runs. Memory that no kernel
  wrote stays NaN, instead of reading as a plausible 0.0.
- **Attribute.** It names the kernel at fault, not just the first tensor that failed. If a failing
  buffer holds a sibling's correct values, the sibling's writer is the suspect, and the geometry
  gives that writer's actual offset.
- **Never skip silently.** Under `TANG_REQUIRE_CUDA=1`, a GPU test that can't run fails.

Here is the harness on the real model, with bug 1 planted back in. The script copies the tree,
reverts the fix, builds both binaries and runs GLM-5.3 once with real weights:

```
━━ tang-verify: a planted GPU bug, caught in one run ━━

1. The bug we planted (crates/tang-llm/src/flash/glm5/kda_dev.rs)
   fixed:   (&self.wk, di as u64 * f), (&self.wv, 2 * di as u64 * f)
   planted: (&self.wk, di as u64),     (&self.wv, 2 * di as u64)

2. One run of the real model with the harness on (layer 0, first window: 20 tokens)
     qkv.q  WRONG         0 of 163840 values never written
     qkv.k  WRONG     81920 of 163840 values never written
     qkv.v  WRONG    163840 of 163840 values never written
   Predicted by the offset arithmetic (20 tokens × 8192 floats per section):
     k: 20 × 8192/2 = 81920 unwritten  ✓
     v: 20 × 8192   = 163840 unwritten ✓
   Harness verdict:
     `qkv.k` wrote into `qkv.q`: qkv.q@tok0 h16 d0 holds qkv.k@tok0 h0 d0
       (writer's base offset in `qkv_pre` is 2048, expected 8192:
        expected = 4 × actual: an ELEMENT offset added to a BYTE address)
     → suspect: k5_gemv attn_k (device)

3. The same run with the fix
   SUMMARY: 34 windows checked, 0 failed
```

Two things to notice. First, the NaN counts match the offset arithmetic exactly. The harness isn't
guessing. Second, the obvious rule ("blame the first stage that fails") would have blamed the q
projection, because q's block fails first. But the values in it are k's, and the harness says so.
That's the 4× diagnosis on the line that matters.

Run it yourself: [`scripts/kernel-verify-demo.sh`](https://github.com/muni-works/tang/blob/main/scripts/kernel-verify-demo.sh)
on a CUDA box with the GLM-5.3-Flash GGUF (a 24 GB card is enough, with the experts on the CPU),
or `--replay` to reprint from saved logs. The method, and the API for writing a kernel test in a
dozen lines, is in [`docs/kernel-verify.md`](https://github.com/muni-works/tang/blob/main/docs/kernel-verify.md).
<!-- links assume ecto/tang → muni-works/tang transfer; see migration.md §5 -->

### What it bought us

With the four bugs fixed, the all-GPU path on one B300 produces the same greedy token ids as the
CPU oracle, 8 of 8 (`785 1196 6801 264 6386 38038 911 279`). That's a correctness result, not a
speed result. Those kernels were naive on purpose, and decode ran at 0.52 tok/s. We're now
replacing them one at a time (a dequant-reuse GEMV, grouped MoE, CUDA graphs, a fused mixer, split-K
prefill), and every replacement has to pass the same harness before it merges. As of this post:
**{{TREE_DECODE}} tok/s decode** on {{TREE_HW}}, still matching the oracle. The trajectory, with
every intermediate number, is on the [bench page](https://frog.toys/bench). We'll keep updating it.
<!-- if TREE_DECODE isn't measured by publish time, replace the sentence with: "Faster kernels are
landing this week. Each one has to match the oracle before it merges." Never publish a target as a result. -->

## frog cloud: Qwen3-Coder-Next on tang

If your machine is slow, `frog -m cloud/qwen3-coder-next` runs the same agent against
Qwen3-Coder-Next (80B total, 3B active) served by tang on an H200. Measured through the public API:

- **{{API_1STREAM}} tok/s** decode, single stream, ~1.2k-token prompt (engine-level: {{ENGINE_1STREAM}})
- **{{API_10K}} tok/s** at a ~10k-token agent prompt
- cached-prefix time to first token: **{{TTFT_CACHED}}**

<!-- Oct 21 values for reference: 224.7 / ~215 via api.frog.toys, 234.4 engine, 190 at 10k, 18-95 ms cached TTFT. Re-measure on Oct 29. -->

Method and raw logs are on the bench page. We're not claiming to be the fastest provider. We'll say
that when a same-day head-to-head and an independent listing back it up.

Sign in at api.frog.toys with GitHub or an email link. New accounts get a starting credit and no
card. After that it's $0.60/M fresh input, $0.06/M cached input and $1.50/M output, or a plan
(Pro $20/mo, Max $200/mo). The endpoint is OpenAI-compatible, and the README has snippets for
opencode, Cline, Roo, Kilo and Continue. If cloud is down or you're out of credit, frog says so and
falls back to your local model.
<!-- reconcile plans with api.frog.toys/pricing before publish: the page lists Max 5x $100 too, and still says "coming soon" -->

## Gate actions, not intent

An agent tells you what it's about to do. You can't verify that. Models misstate their own
reasoning, and text in a file, a web page or a tool description can steer them. What you can verify
is the action. So frog gates actions:

- **Edits and unsandboxed commands ask first**, as approval cards. Shift+Tab cycles the permission mode.
- **Commands run sandboxed** under seatbelt (macOS) or bubblewrap (Linux). They can write only inside
  the project and caches, and can't read `~/.ssh`, `~/.aws` and other credentials. A sandboxed command
  doesn't need to ask, because the sandbox already says what it can touch.
- **MCP tools whose descriptions try to give orders are quarantined** before the model sees them,
  with a warning naming the server, the tool and the reason ([docs/quarantine.md](https://github.com/muni-works/frog/blob/main/docs/quarantine.md)).
- **Next:** a deny-by-default egress allow-list for tool network calls. It isn't in this release.
  We'll say so when it is.

The same rule scales up. We run the company as an org of agents: a chief of staff, managers per
area, and workers under them. Approvals roll up to one person, me. On our busiest day that org
landed {{COMMITS_DAY}} commits. Nobody reviewed intent. Every irreversible action (a merge, a
deploy, a GPU spend over the cap) went through a card.
<!-- 234/day measured by chief; the public repo is one squashed commit, so attach the per-day CSV
from the private history or cut this sentence. See migration.md risk R7. -->

## What isn't done

- The Mac app ships unsigned until our Apple developer enrollment clears. install.sh handles this
  for the CLI. If you download the app in a browser, right-click it and choose Open the first time.
- Intel Macs: build from source (`cargo install --path crates/frog`). Windows isn't supported.
- frog cloud runs on {{NODES}} H200s. If a launch-day spike outruns them, you'll get a 503 and frog
  will fall back to local. The status page is api.frog.toys/status.
- The GLM-5.3 tree path isn't on frog cloud yet. It goes there once its kernels are fast *and* verified.

## Links

- frog: [github.com/muni-works/frog](https://github.com/muni-works/frog)
- tang: [github.com/muni-works/tang](https://github.com/muni-works/tang)
- frog cloud docs: [api.frog.toys/docs](https://api.frog.toys/docs) · status: [api.frog.toys/status](https://api.frog.toys/status)
- Benchmarks and method: [frog.toys/bench](https://frog.toys/bench)

Contributions are welcome under the DCO (`git commit -s`). File bugs on GitHub. Security reports
go through SECURITY.md.

— Cam, Municipal Robotics

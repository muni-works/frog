# Beat 1 launch post

Status: 2026-11-12, for launch 2026-11-13. Every number links its receipt. Editor notes are HTML
comments and get stripped before publishing.

---

## HN submission

**Title:** Show HN: Frog – a coding agent with no caps that pools the machines you already own

**Text (first comment):**

> I'm Cam. Frog is an open coding agent (MIT/Apache-2.0) that runs on your own hardware. Pair a
> second machine with a 6-digit code and Frog spreads agents across both. This week a Mac plus a
> 3090 box finished 41 tasks in 15 minutes where the 3090 alone finished 21, with zero rate-limit
> errors. We also wrote the inference engine under it (tang), so when a machine dies mid-turn the
> turn finishes on another one. Frog Cloud is there by the token if you want more. Happy to answer
> anything.

---

# Frog: no caps. Your machines. One agent.

<!-- Cam: swap in a real rate-limit moment if you have one. -->
Hosted agents stop when you hit the cap. Meanwhile the GPU under your desk sits there doing
nothing.

That's the whole pitch. Frog is a coding agent that runs on the machines you own, as many agents as
they can hold, and nobody meters you. It's free and open source (MIT OR Apache-2.0).

```sh
curl -fsSL https://frog.toys/install.sh | sh
cd your-repo && frog
```

Codex, Claude Code and Conductor rent you an agent on someone else's GPUs, with a cap. Apple's
Harbor pools Macs into an endpoint and stops there. Frog owns all three layers: the agent, the
engine (tang) and the path to your hardware. That's what lets it do the next part.

## Every frog is a node

Got a second machine? On a Mac, flip one toggle. On a Linux box, one line:

```sh
curl -fsSL https://frog.toys/node | sh
```

It installs tang (the CUDA build if it finds a GPU), runs it as a user service and prints a
6-digit code. Type the code on your Mac once. The code authenticates a SPAKE2 key exchange, so
it's useless to anyone sniffing the network ([node protocol](https://github.com/muni-works/frog/blob/main/docs/node-protocol.md)).

Then it just shows up:

- **The composer chip says where the model runs** — "on mew · 41 tok/s" — and opens a map of your
  machines.
- **The model picker lists models, not providers.** Each says where it would run. Pick one that
  isn't loaded and Frog loads it onto a node.
- **The scheduler places every call** by estimated finish time and KV affinity, with fair queues
  when several Macs share one node.
- **A dead machine doesn't kill the turn.** Close the lid on the box mid-turn. The partial answer is
  dropped, the turn reruns on the next node with that model, and one line tells you so. Frog owns
  the transcript, and KV is just a cache.
- **Local first.** Nothing goes to Frog Cloud unless you picked a cloud model.

Plan and design: [every frog is a node](https://github.com/muni-works/frog/blob/main/docs/plans/2026-11-11-every-frog-is-a-node.md).

## No caps, measured

We built a bench for this: `frog-bench swarm` runs N agents in parallel for a fixed wall time, each
in its own worktree, every task checked by a shell command. Same swarm on one node, then on the
pool. Qwen3-8B (4-bit) on both machines, 6 agents, 15 minutes per phase:

| | mew only (RTX 3090) | Mac (M4 Max) + mew |
|---|---|---|
| tasks passed | 21 of 42 | **41 of 64** |
| aggregate tok/s | 86 | 128 |
| stalls (>30 s to first token) | 72 | 31 |
| 429s / 5xx | 0 | 0 |

Source: [docs/no-caps-bench.md](https://github.com/muni-works/frog/blob/main/docs/no-caps-bench.md).

Two honest caveats. One task, edit-json-config, got slower with the pool (101 → 120 s median). And
on a tiny model (Qwen3-0.6B) 3 of 9 short tasks got slower when the second machine joined —
scheduling overhead beats the extra hardware when tasks are that short. Adding a machine finishes
more work. It doesn't make every task faster. The stalls are queueing, too: each node runs one
request at a time.

## One agent, one look

Spawned agents used to be invisible background jobs. Now they're sessions in a tree under the one
that started them, in the sidebar, so you can open, read and steer any of them. The Mac app and the
web app share one layout, checked by rendering the same session in both side by side
([parity](https://github.com/muni-works/frog/blob/main/docs/design/parity/README.md)).

## The engine checks its own kernels

Owning tang means owning its bugs. On October 26 our GPU path for GLM-5.3-Flash produced garbage
while every unit test passed. One of the four bugs was an element offset added to a byte address.
The tests missed it because they printed `q[0..16]`, the one region nothing overwrote.

So we made the instrumentation the rule. **tang-verify** checks every GPU kernel against its CPU
reference (`TANG_KERNEL_VERIFY=1`): it poisons output buffers with NaN so unwritten memory can't
pass as 0.0, compares every element, and names the kernel at fault, not just the first tensor that
failed. Plant the bug back in and it says "an ELEMENT offset added to a BYTE address" and points at
`k5_gemv attn_k` in one run. Try it: [`scripts/kernel-verify-demo.sh`](https://github.com/muni-works/tang/blob/main/scripts/kernel-verify-demo.sh),
method in [`docs/kernel-verify.md`](https://github.com/muni-works/tang/blob/main/docs/kernel-verify.md).
Every faster kernel has to pass it before it merges.
<!-- links assume ecto/tang → muni-works/tang transfer; see migration.md §5 -->

## Frog Cloud, when you want more

`frog login`, then `frog -m cloud/qwen3-coder-next`. Same agent, Qwen3-Coder-Next (80B total, 3B
active) served by tang. Engine-level, measured 2026-11-05: **234 tok/s** decode single stream, up to
**402 tok/s** with MTP drafts ([bench](https://frog.toys/bench)). You pay in dollars per token, no
plan required — see [pricing](https://api.frog.toys/pricing). The endpoint is OpenAI-compatible.
If Cloud is down or you're out of credit, Frog says so and falls back to your local model.
<!-- API-level numbers haven't been re-measured; add only once measured. -->

## Gate actions, not intent

You can't verify what an agent says it'll do. You can verify what it does. Edits and unsandboxed
commands ask first. Commands run sandboxed (seatbelt on macOS, bubblewrap on Linux) — project and
caches writable, `~/.ssh` and `~/.aws` not readable. MCP tools whose descriptions try to give
orders get quarantined before the model sees them ([quarantine](https://github.com/muni-works/frog/blob/main/docs/quarantine.md)).

## What isn't done

- The Mac app ships unsigned until our Apple developer enrollment clears. install.sh handles it for
  the CLI; for the app, right-click → Open the first time.
- Intel Macs build from source. Windows isn't supported.
- Hot sessions don't move between machines yet — a turn reruns on the next node, it doesn't carry
  its KV over.
- Frog Cloud isn't a node. It's a provider, and stays out of the scheduler.
- No egress allow-list for tool network calls yet. We'll say when there is.

## Links

- Frog: [github.com/muni-works/frog](https://github.com/muni-works/frog)
- tang: [github.com/muni-works/tang](https://github.com/muni-works/tang)
- Frog Cloud: [api.frog.toys/docs](https://api.frog.toys/docs) · [status](https://api.frog.toys/status)
- Benchmarks: [frog.toys/bench](https://frog.toys/bench)

Contributions welcome under the DCO (`git commit -s`). Security reports go through SECURITY.md.

Got a second machine? Pair it.

— Cam, Municipal Robotics

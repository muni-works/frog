# The "no caps" bench

`frog-bench swarm` runs N agents in parallel on hardware you own for a fixed wall time. Each run is its own git worktree of one seeded repo, and the node pool's scheduler places every model call (docs/node-protocol.md, `crates/frog-engine/src/nodes.rs`). It's the proof for frog's wedge: as many agents as your hardware allows, never rate-limited.

It reports:
- runs finished and passed: every task has a shell check;
- stalls: a call that waited longer than `--stall-secs` (default 30) for its first token, plus retry storms (429, 5xx, dropped streams);
- tok/s, in aggregate and per node;
- prefill tokens saved by cache, overall and on each session's first call (the shared repo head found in a node's KV);
- dollars per passed task: local hardware is $0 per token, plus this Mac's measured energy at `--kwh-usd`; a hosted model is billed at its catalog price per token;
- placement over time.

`--baseline <spec>` first runs the same swarm on the baseline (for example one node: `node/<hash>@mew`), then on the pool. The additivity check fails if any task's median gets more than 5% worse with more hardware.

Output goes to `bench/results/swarm-<timestamp>/`: `swarm.json` (everything), `baseline.json`/`pooled.json` (one per phase), `*.jsonl` (one line per run) and `report.html`.

## A short run

```bash
cargo build --release -p frog-bench
target/release/frog-bench swarm -m node/<hash> --baseline node/<hash>@mew -n 6 --minutes 15
```

## The 24-hour run

Hardware: this Mac (Apple silicon, tang serving the model on 127.0.0.1:8911) plus at least one paired node with the same weights (`frog` → Nodes). Both must report node schema 2 (current tang main). Use the strongest model every node can hold: the weights hash has to match, so the same MLX snapshot goes on each machine.

```bash
target/release/frog-bench swarm \
  -m node/<hash> --baseline node/<hash>@<one node> \
  -n 8 --minutes 720 --stall-secs 30 \
  --out bench/results/swarm-24h-$(date +%Y%m%d)
```

That's 12 hours on one node, then 12 on the pool. Set `-n` to about 2–4 agents per node; above that, the queue on each node grows and tasks get slower without finishing more. Keep the Mac awake (`caffeinate -i`) for the whole run.

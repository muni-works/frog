#!/usr/bin/env node
// A finished turn whose answer is long prose (paragraphs, a heading, a list, a code block), for the
// phase 1 captures: the 640 measure, the paragraph, list and heading gaps, and the left edge.
//   node docs/design/transcript/captures/long-prose.mjs > docs/design/transcript/captures/long-prose.jsonl
const session = "20261117-120000-prose";
const t0 = Date.UTC(2026, 10, 17, 12, 0, 0);
const answer = [
  "Retries look simple and are not. A client that retries too eagerly turns one slow server into a stampede, and one that retries too politely gives up on requests that would have worked a moment later.",
  "The usual answer is exponential backoff: wait a base delay, then double it on every attempt. That spreads retries out in time, but every client that failed at the same moment still retries at the same moments, so the load arrives in waves.",
  "## Why jitter",
  "Jitter breaks the waves. Each client waits a random share of its delay, so a thousand clients that failed together come back spread across the window instead of all at once. There are three common shapes:",
  "- **Full jitter:** wait anywhere from zero to the delay. The most spread, and the shortest average wait.\n- **Equal jitter:** wait half the delay, plus a random share of the other half. Never retries instantly.\n- **Decorrelated jitter:** each wait is random between the base and three times the last wait.",
  "The trap in tests is that randomness makes timing differ run to run. Take the random source as an argument, so a test can pass a seeded one:",
  "```rust\npub fn delay(&self, attempt: u32, rng: &mut impl Rng) -> Duration {\n    let base = self.base * 2u32.pow(attempt);\n    base + Duration::from_millis(rng.gen_range(0..=base.as_millis() as u64 / 2))\n}\n```",
  "With that, the flaky test becomes a fixed one, and the production path keeps its spread. Cap the delay too: past a few seconds, a retry is rarely what the person waiting wants.",
].join("\n\n");
const events = [
  [0, { event: "turn_started", turn: 1, input: "why do retries need jitter? keep it short-ish" }],
  [250, { event: "item_started", id: "m1", kind: { type: "message" } }],
  [4200, { event: "item_completed", id: "m1", item: { type: "message", text: answer } }],
  [100, { event: "turn_ended", turn: 1, reason: { type: "complete" }, usage: { context_tokens: 2400, input_tokens: 2100, output_tokens: 412, model_calls: 1, tokens_per_sec: 61, timing: { wall_ms: 7300, prefill_ms: 600, decode_ms: 6700, think_ms: 0, tool_ms: 0 }, model: "cloud/qwen3-coder-next" } }],
];
const lines = [JSON.stringify({ type: "header", version: 1, id: session, cwd: "/tmp/lilypad", model: "cloud/qwen3-coder-next", created: t0 })];
let t = t0;
events.forEach(([dt, e], i) => { t += dt; lines.push(JSON.stringify({ type: "event", env: { seq: i + 1, session, created: t, ...e } })); });
console.log(lines.join("\n"));

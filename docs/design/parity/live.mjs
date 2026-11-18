#!/usr/bin/env node
// A one-session gateway that streams a turn in real time, for checking the live row by hand and in
// captures (spec phase 2: the thought cross-fade, the stats, steps cutting, a card waiting, a
// stall). Synthetic text only. The web app (vite dev, proxying /v1 here) attaches as usual.
//
//   node docs/design/parity/live.mjs [--port 8797] [--mode full|stall|think]
//
//   full   a think with thought lines, two reads at once, a failing test run, prose writing, an
//          edit, then a permission card that stays open (Waiting for you)
//   stall  a think that goes quiet after 3 s: "No output for 10s", Stop and Keep waiting at 30 s
//   think  a long think that keeps going (the cross-fade and the stats ticking)
import { createServer } from "node:http";
import { accept } from "../../../apps/web/test/mock/ws.mjs";

const arg = (n, d) => (process.argv.indexOf(`--${n}`) > 0 ? process.argv[process.argv.indexOf(`--${n}`) + 1] : d);
const port = Number(arg("port", 8797));
const mode = arg("mode", "full");
const id = "s_live";

const paras = [
  "The user wants the flaky upload test fixed. Start with the retry code.",
  "Let me look at how the backoff is computed. It calls thread_rng() for jitter.",
  "So the third retry can wait up to 800 ms. The mock store gives up at 500 ms.",
  "Better idea: pass the Rng into Backoff::delay so the test can seed it.",
  "Then the timing is the same on every run and the test stops flaking.",
  "Check the other callers of Backoff::delay before changing its signature.",
];
const thoughts = [
  "The user wants the flaky upload test fixed",
  "It calls thread_rng() for jitter",
  "So the third retry can wait up to 800 ms",
  "Better idea: pass the Rng into Backoff::delay so the test can seed it",
  "Then the timing is the same on every run and the test stops flaking",
  "Check the other callers of Backoff::delay before changing its signature",
];

/** The turn as [ms after attach, event]. */
function script() {
  const out = [];
  const at = (ms, e) => out.push([ms, e]);
  at(0, { event: "status", model: "cloud/qwen3-coder-next", mode: "default", context_tokens: 12_000, context_window: 128_000, tokens_per_sec: 58 });
  at(0, { event: "turn_started", turn: 1, input: "upload_retries_on_503 is flaky. Find out why and fix it." });
  at(300, { event: "item_started", id: "r1", kind: { type: "reasoning" } });
  const n = mode === "think" ? 60 : mode === "stall" ? 2 : paras.length;
  let text = "";
  let tokens = 0;
  const shown = [];
  for (let i = 0; i < n; i++) {
    const p = paras[i % paras.length] + "\n\n";
    const start = text.length;
    text += p;
    // A paragraph streams over 1.4 s in pieces; its line rides the delta that finishes it.
    const words = p.split(/(?<= )/);
    words.forEach((w, k) => {
      const ms = 600 + i * 1400 + Math.round((k / words.length) * 1300);
      const last = k === words.length - 1;
      at(ms, { event: "item_delta", id: "r1", delta: { type: "reasoning", text: w, ...(last ? { thought: thoughts[i % thoughts.length] } : {}) } });
    });
    shown.push({ text: thoughts[i % thoughts.length], start, end: start + p.length - 2, ms: i * 1400 + 1300 });
  }
  const thinkEnd = 600 + n * 1400;
  for (let ms = 600; ms < thinkEnd; ms += 250) at(ms, { event: "output_tokens", turn: 1, output: (tokens = Math.round(((ms - 600) / 1000) * 58)), so_far: true });
  if (mode !== "full") return out.sort((a, b) => a[0] - b[0]);
  at(thinkEnd, { event: "output_tokens", turn: 1, output: (tokens += 6) });
  at(thinkEnd + 100, { event: "item_completed", id: "r1", item: { type: "reasoning", text, thoughts: shown, think_ms: thinkEnd - 600 } });
  let t = thinkEnd + 200;
  at(t, { event: "item_started", id: "t1", kind: { type: "tool_call", name: "Read", arg: "src/retry.rs" } });
  at(t, { event: "item_started", id: "t2", kind: { type: "tool_call", name: "Read", arg: "src/store.rs" } });
  at(t + 900, { event: "item_completed", id: "t1", item: { type: "tool_call", name: "Read", arg: "src/retry.rs", outcome: "ok", output: "", display: "Read 124 lines" } });
  at(t + 1300, { event: "item_completed", id: "t2", item: { type: "tool_call", name: "Read", arg: "src/store.rs", outcome: "ok", output: "", display: "Read 96 lines" } });
  t += 1600;
  at(t, { event: "item_started", id: "t3", kind: { type: "tool_call", name: "Bash", arg: "cargo test -q upload" } });
  at(t + 800, { event: "item_delta", id: "t3", delta: { type: "output", text: "running 11 tests\n" } });
  at(t + 3200, { event: "item_completed", id: "t3", item: { type: "tool_call", name: "Bash", arg: "cargo test -q upload", outcome: "error", output: "running 11 tests\ntest upload_retries_on_503 ... FAILED\n\ntest result: FAILED. 10 passed; 1 failed\n", display: null, tests: { runner: "cargo", passed: 10, failed: 1, total: 11, failed_names: ["upload_retries_on_503"] } } });
  t += 3500;
  at(t, { event: "item_started", id: "m1", kind: { type: "message" } });
  const reply = "The jitter came from `thread_rng()`, so the third retry could wait 800 ms while the mock store gave up at 500 ms. I'll have `Backoff::delay` take the `Rng` so the test can pass a seeded one.";
  reply.split(/(?<= )/).forEach((w, k, all) => {
    at(t + 100 + k * 90, { event: "item_delta", id: "m1", delta: { type: "text", text: w } });
    if (k % 3 === 0) at(t + 100 + k * 90, { event: "output_tokens", turn: 1, output: (tokens += 4), so_far: true });
    if (k === all.length - 1) t = t + 200 + k * 90;
  });
  at(t, { event: "item_completed", id: "m1", item: { type: "message", text: reply } });
  at(t, { event: "output_tokens", turn: 1, output: (tokens += 3) });
  t += 300;
  at(t, { event: "item_started", id: "t4", kind: { type: "tool_call", name: "Edit", arg: "src/retry.rs" } });
  at(t + 1800, { event: "item_completed", id: "t4", item: { type: "tool_call", name: "Edit", arg: "src/retry.rs", outcome: "ok", output: "", display: null, diff: { path: "src/retry.rs", added: 3, removed: 2, created: false, hunks: [] } } });
  t += 2100;
  at(t, { event: "item_started", id: "t5", kind: { type: "tool_call", name: "Bash", arg: "cargo test -q upload" } });
  at(t + 200, { event: "permission_request", id: "p1", item: "t5", name: "Bash", arg: "cargo test -q upload", always: "always allow cargo test" });
  // Sent in time order, numbered in that order, as the engine does.
  return out.sort((a, b) => a[0] - b[0]);
}

const json = (res, s, b) => res.writeHead(s, { "content-type": "application/json" }).end(JSON.stringify(b));
const info = { id, title: "Live row", repo: "muni-works/lilypad", branch: "frog/lilypad-live", state: "running", updated: Date.now() };
const server = createServer((req, res) => {
  const path = new URL(req.url, "http://x").pathname.replace(/\/+$/, "");
  if (path === "/v1/sessions" && req.method === "GET") return json(res, 200, { sessions: [info] });
  if (path === `/v1/sessions/${id}`) return json(res, 200, info);
  json(res, 404, { error: "not in the live fixture" });
});
server.on("upgrade", (req, socket) => {
  if (!req.url.startsWith(`/v1/sessions/${id}/ws`)) return socket.end("HTTP/1.1 404 Not Found\r\n\r\n");
  const offered = (req.headers["sec-websocket-protocol"] ?? "").split(",").map((x) => x.trim()).filter((x) => x && !x.startsWith("bearer."));
  const conn = accept(req, socket, { protocol: offered[0] });
  if (!conn) return;
  const timers = [];
  conn.onmessage = (text) => {
    let v;
    try { v = JSON.parse(text); } catch { return; }
    if (v?.op === "interrupt") {
      timers.forEach(clearTimeout);
      conn.send(JSON.stringify({ seq: 9000, session: id, created: Date.now(), event: "turn_ended", turn: 1, reason: { type: "cancelled" } }));
      return;
    }
    if (!v?.hello) return;
    conn.send(JSON.stringify({ welcome: { protocol: 1, session: id, engine: "frog-live", last_seq: 0 } }));
    const t0 = Date.now();
    script().forEach(([ms, e], i) => timers.push(setTimeout(() => conn.send(JSON.stringify({ seq: i + 1, session: id, created: t0 + ms, ...e })), ms)));
  };
  socket.on("close", () => timers.forEach(clearTimeout));
});
server.listen(port, "127.0.0.1", () => console.log(`live gateway (${mode}) on http://127.0.0.1:${port}`));

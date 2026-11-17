#!/usr/bin/env node
// The reel's gateway: the web app (vite dev, proxying /v1 here) sees an account, the Frog Cloud
// model list, a few repos and six sessions. One of them (s_live) plays the parity fixture
// (docs/design/parity/fixture.jsonl) one step at a time, driven by the capture script:
//
//   node video/hype-reel/capture/gateway.mjs [--port 8811]
//   POST /ctl/step?n=K   send the live session's next K steps (a reply streams a few words a step)
//   POST /ctl/reset      back to nothing sent
//
// Steps are counted, not timed, so a recapture shows the same frames. Reuses the vendored mock's
// websocket (apps/web/test/mock/ws.mjs) and fixture loader.
import { createServer } from "node:http";
import { accept } from "../../../apps/web/test/mock/ws.mjs";
import { loadFixture } from "../../../apps/web/test/mock/session.mjs";

const arg = (n, d) => (process.argv.indexOf(`--${n}`) > 0 ? process.argv[process.argv.indexOf(`--${n}`) + 1] : d);
const port = Number(arg("port", 8811));
const fixture = loadFixture(new URL("../../../docs/design/parity/fixture.jsonl", import.meta.url).pathname);
const now = Date.now();
const min = 60_000;

// The fixture up to its ask card, with each reply and thought split into word-sized deltas so it
// streams on screen.
const ask = fixture.findIndex((e) => e.event === "permission_request");
// First a status line, so the composer names the model the session runs on.
const steps = [{ event: "status", model: "cloud/qwen3-coder-next", mode: "default", context_tokens: 18400, context_window: 262144 }];
for (const e of fixture.slice(0, ask + 1)) {
  const text = e.event === "item_completed" && (e.item?.type === "message" || e.item?.type === "reasoning") ? e.item.text : null;
  if (text) {
    const words = text.split(/(?<=\s)/);
    for (let i = 0; i < words.length; i += 3) steps.push({ event: "item_delta", id: e.id, delta: { type: e.item.type === "message" ? "text" : "reasoning", text: words.slice(i, i + 3).join("") } });
  }
  steps.push(e);
}
const title = fixture.find((e) => e.event === "titled")?.title ?? "Fix flaky upload retry";

// What the account edge would say. No name or picture: the sidebar reads "Signed in" and the
// sign-up credit ($1, site/pricing.html).
const account = { plan: "usage", name: null, handle: null, image: null, google: null, email: null, credit_cents: 100, resets_at: null, subscription: null };
// The pricing page's models (site/pricing.html, the static table), USD per token.
const models = { data: [
  { id: "qwen3-coder-next", context_length: 262144, pricing: { prompt: "0.000000132", completion: "0.00000088", input_cache_read: "0.000000077" } },
  { id: "glm-5.3-flash", context_length: 1000000, pricing: { prompt: "0.000000165", completion: "0.00000055", input_cache_read: "0.000000033" } },
  { id: "deepseek-v4.1-flash", context_length: 1000000, pricing: { prompt: "0.000000165", completion: "0.00000066", input_cache_read: "0.0000000033" } },
] };
const repos = { repos: [
  { name: "muni-works/lilypad", private: false, pushed_at: new Date(now - 20 * min).toISOString() },
  { name: "muni-works/frog", private: false, pushed_at: new Date(now - 45 * min).toISOString() },
  { name: "muni-works/tang", private: false, pushed_at: new Date(now - 3 * 60 * min).toISOString() },
] };
// Six sessions. The web app streams only the open one (s_live); the rest show their listed state.
const sessions = [
  { id: "s_live", title, repo: "muni-works/lilypad", branch: "frog/lilypad-parity", state: "running", created: now - 6 * min, updated: now - 1 * min },
  { id: "s_docs", title: "Docs search filters page titles", repo: "muni-works/frog", branch: "frog/docs-search", state: "running", created: now - 14 * min, updated: now - 2 * min },
  { id: "s_docs_child", title: "Check every page against the code", repo: "muni-works/frog", branch: "frog/docs-check", state: "running", parent: "s_docs", created: now - 12 * min, updated: now - 3 * min },
  { id: "s_cache", title: "Warm the prompt cache on node start", repo: "muni-works/tang", branch: "frog/warm-cache", state: "running", pr: "#412", created: now - 50 * min, updated: now - 4 * min },
  { id: "s_bench", title: "Count stalls in the swarm bench", repo: "muni-works/frog", branch: "frog/bench-stalls", state: "running", created: now - 20 * min, updated: now - 5 * min },
  { id: "s_ranges", title: "Parse byte ranges in uploads", repo: "muni-works/lilypad", branch: "frog/upload-ranges", state: "running", created: now - 25 * min, updated: now - 6 * min },
];
let sent = 0;
const peers = new Set();
const env = (i) => JSON.stringify({ seq: i + 1, session: "s_live", created: now - 5 * min + i * 300, ...steps[i] });
const json = (res, s, b) => res.writeHead(s, { "content-type": "application/json" }).end(JSON.stringify(b));

const server = createServer((req, res) => {
  const url = new URL(req.url, "http://x");
  const path = url.pathname.replace(/\/+$/, "");
  if (path === "/ctl/step" && req.method === "POST") {
    const n = Number(url.searchParams.get("n") ?? 1);
    const to = Math.min(steps.length, sent + n);
    for (; sent < to; sent++) for (const p of peers) p.send(env(sent));
    return json(res, 200, { sent, total: steps.length });
  }
  if (path === "/ctl/reset") { sent = 0; return json(res, 200, { sent, total: steps.length }); }
  if (path === "/v1/me") return json(res, 200, { account });
  if (path === "/v1/models") return json(res, 200, models);
  if (path === "/v1/repos") return json(res, 200, repos);
  if (path === "/v1/sessions" && req.method === "GET") return json(res, 200, { sessions });
  const s = sessions.find((x) => path === `/v1/sessions/${x.id}`);
  if (s) return json(res, 200, s);
  json(res, 404, { error: "not in the reel's gateway" });
});
server.on("upgrade", (req, socket) => {
  const m = /^\/v1\/sessions\/([^/]+)\/ws/.exec(req.url);
  if (!m) return socket.end("HTTP/1.1 404 Not Found\r\n\r\n");
  const offered = (req.headers["sec-websocket-protocol"] ?? "").split(",").map((x) => x.trim()).filter((x) => x && !x.startsWith("bearer."));
  const conn = accept(req, socket, { protocol: offered[0] });
  if (!conn) return;
  const live = m[1] === "s_live";
  conn.onmessage = (text) => {
    let v;
    try { v = JSON.parse(text); } catch { return; }
    if (!v?.hello) return;
    conn.send(JSON.stringify({ welcome: { protocol: 1, session: m[1], engine: "frog-reel", last_seq: live ? sent : 0 } }));
    if (!live) return;
    for (let i = 0; i < sent; i++) conn.send(env(i));
    peers.add(conn);
  };
  socket.on("close", () => peers.delete(conn));
});
server.listen(port, "127.0.0.1", () => console.log(`reel gateway on http://127.0.0.1:${port} (${steps.length} steps)`));

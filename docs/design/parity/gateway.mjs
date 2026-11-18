#!/usr/bin/env node
// A one-session gateway for the parity capture: the web app (vite dev, proxying /v1 here) lists
// one session and, on attach, gets the fixture's events up to its ask card, which stays open.
//
//   node docs/design/parity/gateway.mjs [--port 8799] [--fixture fixture.jsonl]
//
// Reuses the vendored mock's websocket and fixture loader (apps/web/test/mock).
import { createServer } from "node:http";
import { readFileSync } from "node:fs";
import { accept } from "../../../apps/web/test/mock/ws.mjs";
import { loadFixture } from "../../../apps/web/test/mock/session.mjs";

const arg = (n, d) => (process.argv.indexOf(`--${n}`) > 0 ? process.argv[process.argv.indexOf(`--${n}`) + 1] : d);
const port = Number(arg("port", 8799));
const fixture = arg("fixture", new URL("./fixture.jsonl", import.meta.url).pathname);
const events = loadFixture(fixture);
// Each event's own time, so a step's duration and a fold's time come through as the fixture has
// them (the loader drops `created`). Missing: the old 400 ms spacing.
const times = readFileSync(fixture, "utf8").split("\n").filter((l) => l.trim()).map((l) => JSON.parse(l))
  .map((v) => (v.type === "event" ? v.env : v)).filter((e) => typeof e.event === "string").map((e) => e.created);
const id = "s_parity";
const title = arg("title", "Fix flaky upload retry");
const now = Date.now();
// Up to and including the ask; the hold and what follows are the Mac replay's business. A fixture
// with no ask (the fuzz cases, fuzz/cases.mjs) is shown whole.
const ask = events.findIndex((e) => e.event === "permission_request");
const shown = ask < 0 ? events : events.slice(0, ask + 1);
const ended = shown.findLast((e) => e.event === "turn_started" || e.event === "turn_ended")?.event === "turn_ended";
const info = { id, title, repo: "muni-works/lilypad", branch: "frog/lilypad-parity", state: ended ? "idle" : "running", updated: now };
const json = (res, s, b) => res.writeHead(s, { "content-type": "application/json" }).end(JSON.stringify(b));

const server = createServer((req, res) => {
  const path = new URL(req.url, "http://x").pathname.replace(/\/+$/, "");
  if (path === "/v1/sessions" && req.method === "GET") return json(res, 200, { sessions: [info] });
  // The fixture's model with list prices (USD per token), so the footer shows the turn's cost as
  // the Mac does from its catalog. 31,200 read and 1,902 written come to under a cent.
  if (path === "/v1/models") return json(res, 200, { data: [{ id: "qwen3-coder-next", context_length: 262144, pricing: { prompt: "0.0000002", completion: "0.0000008", input_cache_read: "0.00000002" } }] });
  if (path === `/v1/sessions/${id}`) return json(res, 200, info);
  json(res, 404, { error: "not in the parity fixture" });
});
server.on("upgrade", (req, socket) => {
  if (!req.url.startsWith(`/v1/sessions/${id}/ws`)) return socket.end("HTTP/1.1 404 Not Found\r\n\r\n");
  const offered = (req.headers["sec-websocket-protocol"] ?? "").split(",").map((x) => x.trim()).filter((x) => x && !x.startsWith("bearer."));
  const conn = accept(req, socket, { protocol: offered[0] });
  if (!conn) return;
  conn.onmessage = (text) => {
    let v;
    try { v = JSON.parse(text); } catch { return; }
    if (!v?.hello) return;
    conn.send(JSON.stringify({ welcome: { protocol: 1, session: id, engine: "frog-parity", last_seq: shown.length } }));
    const last = times[shown.length - 1];
    shown.forEach((e, i) => conn.send(JSON.stringify({ seq: i + 1, session: id, created: last != null && times[i] != null ? now - (last - times[i]) : now - (shown.length - i) * 400, ...e })));
  };
});
server.listen(port, "127.0.0.1", () => console.log(`parity gateway on http://127.0.0.1:${port}`));

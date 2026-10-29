#!/usr/bin/env node
// Mock Frog Cloud gateway (contract §8), for building web/Mac/iPhone clients before the real
// one is deployed. No dependencies: `node sandbox/mock/mock-gateway.mjs [--port 8788] [--fixture f.jsonl]`.
//
// - Any non-empty bearer key is an account (the key itself), so two keys = two accounts.
//   Websockets may send it as `Sec-WebSocket-Protocol: frog, bearer.<key>` instead.
// - §4 routes, in memory. A new session starts with one recorded turn already in its log.
// - §2 handshake; `protocol: 0` (or anything but 1) gets `refused` and close 4001.
// - `resume_after` replays stored durable envelopes. `{"op":"submit"}` plays the recording
//   live, deltas included, pausing at its permission_request until an Op::Permission arrives.
//   First answer wins; PermissionResolved goes to every attached client.
import { createServer } from "node:http";
import { randomBytes } from "node:crypto";
import { accept } from "./ws.mjs";
import { loadFixture, Recorded } from "./session.mjs";

const arg = (name, fallback) => {
  const i = process.argv.indexOf(`--${name}`);
  return i > 0 ? process.argv[i + 1] : fallback;
};

export function startMock({ port = 8788, fixture = new URL("./demo.jsonl", import.meta.url).pathname, delayMs = 15 } = {}) {
  const events = loadFixture(fixture);
  const sessions = new Map(); // id → { info, rec }

  const json = (res, status, body) => res.writeHead(status, { "content-type": "application/json" }).end(body === undefined ? "" : JSON.stringify(body));
  const summary = ({ info }) => ({ id: info.id, title: info.title, repo: info.repo, branch: info.branch, state: info.state, updated: info.updated });
  const bearer = (req) => {
    const h = req.headers.authorization ?? "";
    if (h.startsWith("Bearer ") && h.slice(7).trim()) return h.slice(7).trim();
    const p = (req.headers["sec-websocket-protocol"] ?? "").split(",").map((s) => s.trim()).find((s) => s.startsWith("bearer."));
    return p ? p.slice(7) : null;
  };
  const own = (req, id) => {
    const s = sessions.get(id);
    return s && s.info.account === bearer(req) ? s : null;
  };

  const server = createServer(async (req, res) => {
    const url = new URL(req.url, "http://mock");
    const path = url.pathname.replace(/\/+$/, "");
    if (path === "/health") return json(res, 200, { ok: true });
    const account = bearer(req);
    if (!account) return json(res, 401, { error: "missing or invalid key" });
    if (path === "/v1/sessions" && req.method === "GET") return json(res, 200, { sessions: [...sessions.values()].filter((s) => s.info.account === account).map(summary) });
    if (path === "/v1/sessions" && req.method === "POST") {
      let body = "";
      for await (const c of req) body += c;
      let b;
      try {
        b = JSON.parse(body || "{}");
      } catch {
        return json(res, 400, { error: "expected JSON" });
      }
      if (typeof b.repo !== "string" || !/^[\w.-]+\/[\w.-]+$/.test(b.repo)) return json(res, 400, { error: "repo must be owner/name" });
      const id = "s_" + randomBytes(10).toString("hex");
      const now = Date.now();
      const info = { id, account, repo: b.repo, branch: b.branch ?? `frog/${b.repo.split("/")[1]}-${id.slice(2, 8)}`, title: b.repo, state: "running", created: now, updated: now };
      const rec = new Recorded(id, events);
      // One recorded turn already in the log, so a fresh attach has something to replay.
      for (const e of events) {
        rec.emit(e.event === "turn_started" ? { ...e, input: "(recorded)" } : e);
        if (e.event === "permission_request") rec.permission({ id: e.id, decision: "allow" });
      }
      sessions.set(id, { info, rec });
      const origin = `ws://${req.headers.host}`;
      return json(res, 201, { ...summary({ info }), ws: `${origin}/v1/sessions/${id}/ws` });
    }
    const m = path.match(/^\/v1\/sessions\/([^/]+)(\/handoff)?$/);
    const s = m && own(req, m[1]);
    if (!s) return json(res, 404, { error: "no such session" });
    if (m[2] === "/handoff" && req.method === "POST") {
      for await (const _ of req);
      return json(res, 200, summary(s));
    }
    if (req.method === "GET") return json(res, 200, summary(s));
    if (req.method === "DELETE") {
      for (const p of s.rec.peers) p.close(4004, "session deleted");
      sessions.delete(s.info.id);
      return json(res, 204);
    }
    json(res, 405, { error: "method not allowed" });
  });

  server.on("upgrade", (req, socket) => {
    const m = new URL(req.url, "http://mock").pathname.match(/^\/v1\/sessions\/([^/]+)\/ws$/);
    const s = m && own(req, m[1]);
    if (!s) return socket.end("HTTP/1.1 404 Not Found\r\n\r\n");
    const offered = (req.headers["sec-websocket-protocol"] ?? "").split(",").map((x) => x.trim()).filter((x) => x && !x.startsWith("bearer."));
    const conn = accept(req, socket, { protocol: offered[0] });
    if (!conn) return;
    let live = false;
    conn.onmessage = (text) => {
      let v;
      try {
        v = JSON.parse(text);
      } catch {
        return;
      }
      if (!live) {
        if (typeof v?.hello?.protocol !== "number") return conn.close(4002, "expected hello");
        if (v.hello.protocol !== 1) {
          conn.send(JSON.stringify({ refused: { reason: "protocol", min: 1, max: 1, upgrade: "https://frog.toys/download" } }));
          return conn.close(4001, "protocol");
        }
        conn.send(JSON.stringify({ welcome: { protocol: 1, session: s.info.id, engine: "frog-mock/0.1.0", last_seq: s.rec.lastSeq() } }));
        for (const t of s.rec.after(Number(v.hello.resume_after) || 0)) conn.send(t);
        live = true;
        s.rec.peers.add(conn);
        return;
      }
      s.info.updated = Date.now();
      if (v.op === "submit") void s.rec.play(typeof v.input === "string" ? v.input : "", delayMs);
      else if (v.op === "permission" && typeof v.id === "string") s.rec.permission(v);
    };
    conn.onclose = () => s.rec.peers.delete(conn);
  });

  return new Promise((resolve) => server.listen(port, "127.0.0.1", () => resolve({ server, port: server.address().port, close: () => new Promise((r) => (server.closeAllConnections(), server.close(r))) })));
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const { port } = await startMock({ port: Number(arg("port", 8788)), ...(arg("fixture") ? { fixture: arg("fixture") } : {}) });
  console.log(`mock gateway on http://127.0.0.1:${port} (any bearer key is an account)`);
}

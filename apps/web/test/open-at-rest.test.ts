// Opening a saved conversation shows it at rest (Cam, 2026-11-19: "when loading a long
// conversation, everything streams in individually - this is overwhelming, we should just load
// the conversation and render the tail"). The history arrives over the socket in bursts, as a
// gateway sends it across the network; the page must go from nothing to the conversation's end
// in one step, drawing only the tail (turns above fill in as you scroll up), and only what
// arrives live after the open may stream. The real App in headless Chrome; a recorder in the page
// counts the transcript's turns on every frame. Skips without Chrome.
//
// It failed before the fix: the store folds envelopes once a frame, so a 200-turn history drew in
// dozens of steps as its bursts arrived, the view following the end through all of them.
import { after, before, test } from "node:test";
import assert from "node:assert/strict";
import { createServer, type Server } from "node:http";
import { createServer as listen } from "node:net";
import { fileURLToPath } from "node:url";
import { accept } from "./mock/ws.mjs";
import { chrome } from "./chrome.ts";
import { open, pause, until, type Page } from "./cdp.ts";

const skip = chrome ? false : "no Chrome on this machine";
const KEY = "frog_open";
const TURNS = 200;
const freePort = () => new Promise<number>((r) => { const s = listen().listen(0, "127.0.0.1", () => { const p = (s.address() as { port: number }).port; s.close(() => r(p)); }); });

/** A long saved session: each turn a message, a step and a two-paragraph answer. `open`: the last
 *  turn is still running (its reply streams after the open). */
function history(open: boolean) {
  const out: Record<string, unknown>[] = [];
  const t0 = Date.now() - 3_600_000;
  let seq = 0;
  const push = (e: Record<string, unknown>) => out.push({ seq: ++seq, session: "s", created: t0 + seq * 100, ...e });
  for (let n = 1; n <= TURNS; n++) {
    push({ event: "turn_started", turn: n, input: `Question ${n}: what changed in the retry loop?` });
    push({ event: "item_started", id: `t${n}`, kind: { type: "tool_call", name: "Bash", arg: "cargo test -q" } });
    push({ event: "item_completed", id: `t${n}`, item: { type: "tool_call", name: "Bash", arg: "cargo test -q", input: {}, outcome: "ok", output: "ok", display: null } });
    push({ event: "item_started", id: `m${n}`, kind: { type: "message" } });
    if (open && n === TURNS) break;
    push({ event: "item_completed", id: `m${n}`, item: { type: "message", text: `Answer ${n}: the jitter is seeded now.\n\nAll eleven upload tests pass.` } });
    push({ event: "turn_ended", turn: n, reason: { type: "complete" }, usage: { context_tokens: 100, input_tokens: 100, output_tokens: 40, model_calls: 1 } });
  }
  return out;
}

/** A one-session gateway that sends the history in bursts of 40 envelopes every 15 ms after the
 *  welcome, then, for an open turn, a live reply a word at a time. */
function gateway(sessions: Record<string, { open: boolean }>): Server {
  const server = createServer((req, res) => {
    const path = new URL(req.url!, "http://x").pathname.replace(/\/+$/, "");
    const json = (b: unknown) => res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify(b));
    if (path === "/v1/sessions") return json({ sessions: Object.keys(sessions).map((id) => ({ id, title: `Long ${id}`, repo: "ada/notes", branch: "main", state: sessions[id].open ? "running" : "idle", updated: Date.now() })) });
    if (path === "/v1/models") return json({ data: [] });
    const id = path.match(/^\/v1\/sessions\/([^/]+)$/)?.[1];
    if (id && sessions[id]) return json({ id, title: `Long ${id}`, repo: "ada/notes", branch: "main", state: sessions[id].open ? "running" : "idle", updated: Date.now() });
    res.writeHead(404).end();
  });
  server.on("upgrade", (req, socket) => {
    const id = req.url!.match(/^\/v1\/sessions\/([^/]+)\/ws/)?.[1];
    if (!id || !sessions[id]) return socket.end("HTTP/1.1 404 Not Found\r\n\r\n");
    const offered = String(req.headers["sec-websocket-protocol"] ?? "").split(",").map((x) => x.trim()).filter((x) => x && !x.startsWith("bearer."));
    const conn = accept(req, socket, { protocol: offered[0] });
    if (!conn) return;
    conn.onmessage = async (text: string) => {
      let v: { hello?: unknown };
      try { v = JSON.parse(text); } catch { return; }
      if (!v?.hello) return;
      const events = history(sessions[id].open).map((e) => ({ ...e, session: id }));
      conn.send(JSON.stringify({ welcome: { protocol: 1, session: id, engine: "frog-open-test", last_seq: events.length } }));
      for (let i = 0; i < events.length; i += 40) {
        for (const e of events.slice(i, i + 40)) conn.send(JSON.stringify(e));
        await new Promise((r) => setTimeout(r, 15));
      }
      if (!sessions[id].open) return;
      let seq = events.length;
      for (let w = 0; w < 60; w++) {
        await new Promise((r) => setTimeout(r, 40));
        conn.send(JSON.stringify({ seq: ++seq, session: id, created: Date.now(), event: "item_delta", id: `m${TURNS}`, delta: { type: "text", text: `word${w} ` } }));
      }
    };
  });
  return server;
}

let gw: Server | undefined;
let vite: { close: () => Promise<void> } | undefined;
let origin = "";

before(async () => {
  if (!chrome) return;
  const gport = await freePort();
  gw = gateway({ s_long: { open: false }, s_live: { open: true } });
  await new Promise<void>((r) => gw!.listen(gport, "127.0.0.1", r));
  const port = await freePort();
  process.env.GATEWAY = `http://127.0.0.1:${gport}`;
  process.env.VITE_API = `http://127.0.0.1:${port}`;
  const { createServer: viteServer } = await import("vite");
  const server = await viteServer({ root: fileURLToPath(new URL("..", import.meta.url)), logLevel: "error", server: { port, host: "127.0.0.1", strictPort: true } });
  await server.listen();
  vite = server;
  origin = `http://127.0.0.1:${port}`;
});
after(async () => {
  await vite?.close();
  await new Promise((r) => (gw ? gw.close(r) : r(null)));
});

// Every frame from the first: how many turns the transcript has drawn, and how far its view is
// from its end.
const RECORDER = `(() => {
  window.__frames = [];
  const tick = () => {
    const el = document.querySelector('.scroll');
    const turns = document.querySelectorAll('.tx > .turn').length;
    const gap = el ? Math.round(el.scrollHeight - el.scrollTop - el.clientHeight) : -1;
    const last = window.__frames[window.__frames.length - 1];
    if (!last || last.turns !== turns) window.__frames.push({ t: performance.now(), turns, gap });
    requestAnimationFrame(tick);
  };
  requestAnimationFrame(tick);
})()`;

type Frame = { t: number; turns: number; gap: number };
const frames = (p: Page) => p.eval<Frame[]>("window.__frames");
const lastText = (p: Page) => p.eval<string>("[...document.querySelectorAll('.tx > .turn')].pop()?.textContent ?? ''");

async function openSession(id: string): Promise<Page> {
  const p = await open(`${origin}/parity/app.html?key=${KEY}&session=${id}&theme=dark`, 1200, 800, false, RECORDER);
  assert.ok(await until(async () => (await frames(p)).some((f) => f.turns > 0), 20000), "the conversation drew");
  return p;
}

test("a long saved conversation opens at rest: nothing, then its end, in one step", { skip, timeout: 120_000 }, async () => {
  const p = await openSession("s_long");
  try {
    await pause(1500);
    const steps = (await frames(p)).filter((f) => f.turns > 0);
    // One step from nothing to what's drawn: no turns arriving one burst at a time.
    assert.equal(steps.length, 1, `drew in ${steps.length} steps: ${steps.map((f) => f.turns).join(", ")}`);
    // The tail, not all 200: the rest fills in above as you scroll up.
    assert.ok(steps[0].turns < TURNS, `drew the tail first (${steps[0].turns} of ${TURNS} turns)`);
    assert.ok(steps[0].turns >= 3, `enough to fill the view (${steps[0].turns} turns)`);
    // At its end, at rest.
    assert.match(await lastText(p), new RegExp(`Answer ${TURNS}:`), "the last turn is the newest");
    const el = await p.eval<number>("(() => { const el = document.querySelector('.scroll'); return Math.round(el.scrollHeight - el.scrollTop - el.clientHeight) })()");
    assert.ok(el < 60, `at the end (${el} px from it)`);
  } finally { await p.close(); }
});

test("scrolling up fills in the earlier turns without moving what's on screen", { skip, timeout: 120_000 }, async () => {
  const p = await openSession("s_long");
  try {
    await pause(800);
    const before = await p.eval<number>("document.querySelectorAll('.tx > .turn').length");
    // What's at the top of the view, and where.
    const anchor = () => p.eval<{ text: string; top: number }>(`(() => {
      const el = document.querySelector('.scroll'); const top = el.getBoundingClientRect().top;
      const t = [...document.querySelectorAll('.tx > .turn')].find((x) => x.getBoundingClientRect().bottom > top + 1);
      return { text: t?.querySelector('.me')?.textContent ?? '', top: Math.round(t.getBoundingClientRect().top - top) } })()`);
    for (let i = 0; i < 6; i++) { await p.call("Input.dispatchMouseEvent", { type: "mouseWheel", x: 600, y: 300, deltaX: 0, deltaY: -5000 }); await pause(150); }
    await pause(600);
    const a = await anchor();
    await pause(800);
    const b = await anchor();
    const after = await p.eval<number>("document.querySelectorAll('.tx > .turn').length");
    assert.ok(after > before, `earlier turns filled in (${before} → ${after})`);
    assert.equal(b.text, a.text, "the same turn at the top");
    assert.ok(Math.abs(b.top - a.top) < 2, `it didn't move (${a.top} → ${b.top} px)`);
  } finally { await p.close(); }
});

test("a conversation opened mid-reply: its history at once, only the live reply streams", { skip, timeout: 120_000 }, async () => {
  const p = await openSession("s_live");
  try {
    await pause(300);
    const steps = (await frames(p)).filter((f) => f.turns > 0);
    assert.equal(steps.length, 1, `history drew in ${steps.length} steps: ${steps.map((f) => f.turns).join(", ")}`);
    const a = await lastText(p);
    await pause(1200);
    const b = await lastText(p);
    assert.ok(b.length > a.length && /word\d+/.test(b), "the live reply keeps streaming in");
  } finally { await p.close(); }
});

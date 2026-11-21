// A reply is drawn where it will rest from its first word (Cam, 2026-11-21): no card while it
// streams, so finishing moves nothing. A test gateway streams a reply (a wrapped paragraph, a
// list, another paragraph) into the real App in headless Chrome and holds it open; the reply's
// line boxes are measured, the turn finishes, and every line box must be where it was, measured
// from the turn's prompt so the view's own following can't hide a shift. Before: the web drew no
// card but put the caret on a line of its own under the reply, which finishing took away. Skips
// without Chrome.
import { after, before, test } from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { createServer as listen } from "node:net";
import { writeFileSync } from "node:fs";
import { accept } from "./mock/ws.mjs";
import { chrome, serve } from "./chrome.ts";
import { open, pause, until, type Page } from "./cdp.ts";

const skip = chrome ? false : "no Chrome on this machine";
const freePort = () => new Promise<number>((r) => { const s = listen().listen(0, "127.0.0.1", () => { const p = (s.address() as { port: number }).port; s.close(() => r(p)); }); });

const id = "s_parity";
const text = [
  "The retry waited on `thread_rng()` for its jitter, so the third attempt could sleep longer than the mock store waits before it gives up, and the test failed about one run in nine.",
  "- The delay takes an `Rng`, so a test can seed it.",
  "- The jitter is half the base at most.",
  "All eleven upload tests pass now, every run.",
].join("\n\n");
const pieces = text.match(/.{1,24}/gs) ?? [text];
const t0 = Date.now() - 60_000;
const streaming = [
  { event: "turn_started", turn: 1, input: "Why is upload_retries_on_503 flaky?" },
  { event: "item_started", id: "m1", kind: { type: "message" } },
  ...pieces.map((p) => ({ event: "item_delta", id: "m1", delta: { type: "text", text: p } })),
];
const finishing = [
  { event: "item_completed", id: "m1", item: { type: "message", text } },
  { event: "turn_ended", turn: 1, reason: { type: "complete" }, usage: { context_tokens: 900, input_tokens: 900, output_tokens: 120, model_calls: 1 } },
];

let finish: () => void = () => {};
let server: ReturnType<typeof createServer> | undefined;
let site: Awaited<ReturnType<typeof serve>> | undefined;

before(async () => {
  if (!chrome) return;
  const port = await freePort();
  const info = { id, title: "Flaky upload", repo: "muni-works/lilypad", branch: "frog/lilypad", state: "running", updated: Date.now() };
  const json = (res: import("node:http").ServerResponse, s: number, b: unknown) => res.writeHead(s, { "content-type": "application/json" }).end(JSON.stringify(b));
  server = createServer((req, res) => {
    const path = new URL(req.url!, "http://x").pathname.replace(/\/+$/, "");
    if (path === "/v1/sessions") return json(res, 200, { sessions: [info] });
    if (path === `/v1/sessions/${id}`) return json(res, 200, info);
    if (path === "/v1/models") return json(res, 200, { data: [] });
    json(res, 404, { error: "not here" });
  });
  server.on("upgrade", (req, socket) => {
    const offered = String(req.headers["sec-websocket-protocol"] ?? "").split(",").map((x) => x.trim()).filter((x) => x && !x.startsWith("bearer."));
    const conn = accept(req, socket, { protocol: offered[0] });
    if (!conn) return;
    let seq = 0;
    const send = (e: object) => conn.send(JSON.stringify({ seq: ++seq, session: id, created: t0 + seq * 50, ...e }));
    conn.onmessage = (raw: string) => {
      let v: { hello?: unknown };
      try { v = JSON.parse(raw); } catch { return; }
      if (!v?.hello) return;
      conn.send(JSON.stringify({ welcome: { protocol: 1, session: id, engine: "frog-test", last_seq: 0 } }));
      streaming.forEach(send);
      finish = () => finishing.forEach(send);
    };
  });
  await new Promise<void>((r) => server!.listen(port, "127.0.0.1", r));
  process.env.GATEWAY = `http://127.0.0.1:${port}`;
  process.env.VITE_DEV_KEY = "parity";
  process.env.VITE_API = "";
  site = await serve();
});
after(async () => {
  await site?.close();
  server?.close();
});

/** The reply's line boxes and its box, in px from the prompt bubble's bottom and the column's
 * left edge. The caret and the stats sit outside `.md`: only the words are measured. */
const lines = (p: Page) => p.eval<{ tail: number[] | null; box: number[]; lines: number[][]; md: number } | null>(`(() => {
  const say = document.querySelector('.tx .say[data-item="m1"]');
  const me = document.querySelector('.tx .me');
  const col = document.querySelector('.tx');
  if (!say || !me || !col) return null;
  const md = say.querySelector('.md');
  const y0 = me.getBoundingClientRect().bottom;
  const x0 = col.getBoundingClientRect().left + parseFloat(getComputedStyle(col).paddingLeft);
  const r = document.createRange(); r.selectNodeContents(md);
  const q = (v) => Math.round(v * 2) / 2;
  const s = say.getBoundingClientRect();
  // The line under the reply: its live stats while it writes, its footer once it's done.
  const under = document.querySelector('.tx .live-tail .live-stats') ?? document.querySelector('.tx .turn-foot');
  const u = under?.getBoundingClientRect();
  return {
    tail: u ? [q(u.left - x0), q(u.top - y0)] : null,
    box: [q(s.left - x0), q(s.top - y0), q(s.width), q(s.height)],
    lines: [...r.getClientRects()].filter((b) => b.width > 0).map((b) => [q(b.left - x0), q(b.top - y0), q(b.width), q(b.height)]),
    md: md.textContent.length,
  };
})()`);

test("a finished reply's words are where they were while it streamed", { skip, timeout: 90_000 }, async () => {
  const p = await open(`${site!.origin}/s/${id}`, 1280, 900, true);
  try {
    // Every piece in, still streaming (the caret is drawn).
    assert.ok(await until(async () => !!(await p.eval<boolean>("!!document.querySelector('.tx .say[data-item=\"m1\"][data-writing]') && document.querySelector('.tx .say[data-item=\"m1\"] .md')?.textContent.includes('every run')"))), "the reply streamed in");
    await pause(500);
    const live = await lines(p);
    if (process.env.FROG_STREAM_SHOTS) await shot(p, `${process.env.FROG_STREAM_SHOTS}/stream-web-live.png`);
    finish();
    assert.ok(await until(async () => !!(await p.eval<boolean>("!!document.querySelector('.tx .turn-foot') && !document.querySelector('.tx .say[data-writing]')"))), "the turn finished");
    await pause(500);
    const done = await lines(p);
    if (process.env.FROG_STREAM_SHOTS) await shot(p, `${process.env.FROG_STREAM_SHOTS}/stream-web-done.png`);
    assert.ok(live && done && live.lines.length > 4, `measured the reply (${JSON.stringify(live)})`);
    assert.deepEqual(done.box, live.box, "the reply's box didn't move or change size (a caret on a line of its own did)");
    assert.deepEqual(done.lines, live.lines, "every line of the reply is where it was");
    // The stats under the writing answer become its footer in place: same top, same left.
    assert.ok(live.tail && done.tail, `measured the stats and the footer (${JSON.stringify([live.tail, done.tail])})`);
    assert.deepEqual(done.tail, live.tail, "the footer sits where the stats were");
  } finally { await p.close(); }
});

async function shot(p: Page, out: string) {
  const r = await p.call("Page.captureScreenshot", { format: "png", clip: { x: 0, y: 0, width: 1280, height: 520, scale: 1 } }) as { data: string };
  writeFileSync(out, Buffer.from(r.data, "base64"));
}

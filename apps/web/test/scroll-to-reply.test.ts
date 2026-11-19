// Sending brings the incoming reply into view (Cam, 2026-11-19; spec, "Following"): from
// wherever you were reading, a send takes the view to the end, so your message and the start of
// the reply are in view; the view follows the reply until its first line would leave the top, and
// holds there so a long answer reads from its start, as the Mac does. Your own scrolling releases
// either; scrolled on to the end yourself, it follows that answer and doesn't pull you back up.
// The real App in headless Chrome, signed in to the vendored mock gateway, which streams a long
// reply for every message; the scroll and the keys are real input (DevTools' Input domain), not
// script. Skips without Chrome.
//
// It failed before the fix: sent from the top of a long session, the view stayed at the top
// (transcript phase 1, af22536b, followed only from the end, so a send from higher up didn't move).
import { after, before, test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { createServer as listen } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import WebSocket from "ws";
import { startMock } from "./mock/mock-gateway.mjs";
import { chrome } from "./chrome.ts";
import { open, pause, until, type Page } from "./cdp.ts";

const skip = chrome ? false : "no Chrome on this machine";
const KEY = "frog_scroll";
const freePort = () => new Promise<number>((r) => { const s = listen().listen(0, "127.0.0.1", () => { const p = (s.address() as { port: number }).port; s.close(() => r(p)); }); });

// One turn: a long reply written in 120 pieces (every 30 ms on the mock: about 4 s of streaming).
const line = (i: number) => `Line ${i} of the reply: the retry waits, the store answers, and the test passes every run.\n\n`;
const fixture = [
  { event: "turn_started", turn: 1, input: "(recorded)" },
  { event: "item_started", id: "m1", kind: { type: "message" } },
  ...Array.from({ length: 120 }, (_, i) => ({ event: "item_delta", id: "m1", delta: { type: "text", text: line(i) } })),
  { event: "item_completed", id: "m1", item: { type: "message", text: Array.from({ length: 120 }, (_, i) => line(i)).join("") } },
  { event: "turn_ended", turn: 1, reason: { type: "complete" }, usage: { context_tokens: 100, input_tokens: 100, output_tokens: 900, model_calls: 1 } },
];

let mock: Awaited<ReturnType<typeof startMock>> | undefined;
let vite: { close: () => Promise<void> } | undefined;
let origin = "";
let session = "";
let dir = "";

before(async () => {
  if (!chrome) return;
  dir = mkdtempSync(join(tmpdir(), "frog-scroll-"));
  const file = join(dir, "long.jsonl");
  writeFileSync(file, fixture.map((e) => JSON.stringify(e)).join("\n") + "\n");
  mock = await startMock({ port: 0, fixture: file, delayMs: 30 });
  const api = `http://127.0.0.1:${mock.port}`;
  const port = await freePort();
  process.env.GATEWAY = api;
  process.env.VITE_API = `http://127.0.0.1:${port}`;
  const { createServer } = await import("vite");
  const server = await createServer({ root: fileURLToPath(new URL("..", import.meta.url)), logLevel: "error", server: { port, host: "127.0.0.1", strictPort: true } });
  await server.listen();
  vite = server;
  origin = `http://127.0.0.1:${port}`;
  // A session with history: two finished turns, so the transcript is far taller than the window.
  const s = await (await fetch(`${api}/v1/sessions`, { method: "POST", headers: { authorization: `Bearer ${KEY}`, "content-type": "application/json" }, body: JSON.stringify({ repo: "ada/notes" }) })).json() as { id: string; ws: string };
  session = s.id;
  const ws = new WebSocket(s.ws, ["frog", `bearer.${KEY}`]);
  const ended: (() => void)[] = [];
  ws.on("message", (d) => { if (JSON.parse(String(d)).event === "turn_ended") ended.shift()?.(); });
  await new Promise((r) => ws.on("open", r));
  ws.send(JSON.stringify({ hello: { protocol: 1, client: "scroll-test", resume_after: 1e9 } }));
  for (const text of ["first", "second"]) await new Promise<void>((r) => { ended.push(r); ws.send(JSON.stringify({ op: "submit", text })); });
  ws.close();
});
after(async () => {
  await vite?.close();
  await mock?.close();
  if (dir) rmSync(dir, { recursive: true, force: true });
});


/** How far the transcript's view is from its end, in px. */
const gap = (p: Page) => p.eval<number>("(() => { const el = document.querySelector('.scroll'); return el ? Math.round(el.scrollHeight - el.scrollTop - el.clientHeight) : -1 })()");
const wheel = async (p: Page, deltaY: number) => {
  for (let i = 0; i < 6; i++) await p.call("Input.dispatchMouseEvent", { type: "mouseWheel", x: 600, y: 300, deltaX: 0, deltaY: deltaY / 6 });
  await pause(300);
};
const sendMessage = async (p: Page, text: string) => {
  await p.eval("document.querySelector('.dock textarea').focus()");
  await p.call("Input.insertText", { text });
  await p.call("Input.dispatchKeyEvent", { type: "keyDown", key: "Enter", code: "Enter", windowsVirtualKeyCode: 13, text: "\r" });
  await p.call("Input.dispatchKeyEvent", { type: "keyUp", key: "Enter", code: "Enter", windowsVirtualKeyCode: 13 });
};

async function session_(reducedMotion: boolean) {
  const p = await open(`${origin}/parity/app.html?key=${KEY}&session=${session}&theme=dark`, 1200, 700, reducedMotion);
  assert.ok(await until(async () => (await p.eval<number>("document.querySelectorAll('.tx .me').length")) >= 2), "the session's history loaded");
  return p;
}

/** Where your last message sits in the view: px from the scroller's top edge (negative: above). */
const promptTop = (p: Page) => p.eval<number>("(() => { const el = document.querySelector('.scroll'); const me = [...document.querySelectorAll('.tx .me')].pop(); return el && me ? Math.round(me.getBoundingClientRect().top - el.getBoundingClientRect().top) : -9999 })()");

test("a send from far up the history brings the view to the reply, which holds at its start once it's long", { skip, timeout: 120_000 }, async () => {
  const p = await session_(false);
  try {
    // Read from the top, by your own scrolling.
    await wheel(p, -100_000);
    assert.ok(await gap(p) > 2000, `scrolled up to read (${await gap(p)} px from the end)`);
    await sendMessage(p, "and again");
    // Your message and the reply's start in view: the view went down to them. The mock's reply
    // fills the view about as fast as the glide arrives, so it lands held: your message at the
    // top, the reply below it, the rest still coming past the bottom.
    assert.ok(await until(async () => { const t = await promptTop(p); return t >= 0 && t < 80 }, 3000), `the send brought your message and the reply into view (message ${await promptTop(p)} px down)`);
    assert.ok(await until(async () => (await gap(p)) > 200, 6000), "the reply grew past the view");
    const held = await promptTop(p);
    assert.ok(held >= 0 && held < 80, `held with your message at the top (${held} px down)`);
    await pause(1000);
    assert.ok(Math.abs((await promptTop(p)) - held) < 2, `still held as it grows (${await promptTop(p)} px down)`);
  } finally { await p.close(); }
});

test("scrolled on to the end yourself, it follows the reply and doesn't pull you back to its start", { skip, timeout: 120_000 }, async () => {
  const p = await session_(false);
  try {
    await sendMessage(p, "one more");
    assert.ok(await until(async () => { const t = await promptTop(p); return t >= 0 && t < 80 && (await gap(p)) > 200 }, 6000), "held at the reply's start");
    await wheel(p, 100_000);
    await pause(200);
    const worst: number[] = [];
    for (let i = 0; i < 10; i++) { await pause(100); worst.push(await gap(p)); }
    assert.ok(Math.max(...worst) < 80, `follows to the end once you scroll there (worst ${Math.max(...worst)} px from it)`);
    await wheel(p, -600);
    const away = await gap(p);
    assert.ok(away > 300, `scrolled up (${away} px from the end)`);
    await pause(800);
    assert.ok(await gap(p) >= away, `left where you scrolled while it grows (${await gap(p)} px from the end)`);
  } finally { await p.close(); }
});

test("with reduced motion the send jumps", { skip, timeout: 120_000 }, async () => {
  const p = await session_(true);
  try {
    await wheel(p, -100_000);
    await sendMessage(p, "reduced");
    // No glide to wait for: your message is in view as soon as the page has drawn it.
    assert.ok(await until(async () => { const t = await promptTop(p); return t >= 0 && t < 700 }, 1000), `your message in view at once (${await promptTop(p)} px down)`);
  } finally { await p.close(); }
});

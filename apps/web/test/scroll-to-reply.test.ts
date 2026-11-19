// Sending brings the transcript to the reply (Cam, 2026-11-19): from wherever you were reading,
// a send takes the view to the bottom so your message and the start of the reply are in view;
// while the reply streams it stays pinned to the bottom unless you scroll up yourself, and
// scrolling back to the bottom pins it again. The real App in headless Chrome, signed in to the
// vendored mock gateway, which streams a long reply for every message; the scroll and the keys
// are real input (DevTools' Input domain), not script. Skips without Chrome.
//
// It failed before the fix: sent from the top of a long session, the view stayed at the top
// (transcript phase 1, af22536b, followed only from the end, so a send from higher up didn't move).
import { after, before, test } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { createServer as listen } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import WebSocket from "ws";
import { startMock } from "./mock/mock-gateway.mjs";
import { chrome } from "./chrome.ts";

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

type Page = { eval: <T>(expr: string) => Promise<T>; call: (method: string, params?: object) => Promise<unknown>; close: () => Promise<void> };

/** The App at w × h in headless Chrome over the DevTools protocol. */
async function open(url: string, w: number, h: number, reducedMotion = false): Promise<Page> {
  const profile = mkdtempSync(join(tmpdir(), "frog-scroll-chrome-"));
  const linux = process.platform === "linux" ? ["--no-sandbox"] : [];
  const proc = spawn(chrome!, ["--headless=new", "--remote-debugging-port=0", `--user-data-dir=${profile}`, "--hide-scrollbars", ...linux, "about:blank"], { stdio: ["ignore", "ignore", "pipe"] });
  const wsUrl = await new Promise<string>((resolve, reject) => {
    let buf = "";
    proc.stderr!.on("data", (d) => { buf += d; const m = /DevTools listening on (ws:\/\/\S+)/.exec(buf); if (m) resolve(m[1]); });
    setTimeout(() => reject(new Error("chrome didn't start")), 15000);
  });
  const targets = await (await fetch(`http://127.0.0.1:${new URL(wsUrl).port}/json/list`)).json() as { type: string; webSocketDebuggerUrl: string }[];
  const ws = new WebSocket(targets.find((t) => t.type === "page")!.webSocketDebuggerUrl);
  await new Promise((r) => ws.on("open", r));
  let n = 0;
  const call = (method: string, params: object = {}) => new Promise<unknown>((resolve) => {
    const id = ++n;
    const on = (m: WebSocket.RawData) => { const v = JSON.parse(String(m)); if (v.id === id) { ws.off("message", on); resolve(v.result); } };
    ws.on("message", on);
    ws.send(JSON.stringify({ id, method, params }));
  });
  await call("Emulation.setDeviceMetricsOverride", { width: w, height: h, deviceScaleFactor: 1, mobile: false });
  await call("Emulation.setEmulatedMedia", { features: [{ name: "prefers-reduced-motion", value: reducedMotion ? "reduce" : "no-preference" }] });
  await call("Page.enable");
  await call("Page.navigate", { url });
  const evalJS = async <T,>(expr: string) => ((await call("Runtime.evaluate", { expression: expr, returnByValue: true, awaitPromise: true })) as { result: { value: T } }).result.value;
  return {
    eval: evalJS, call,
    close: async () => { ws.close(); proc.kill(); await new Promise((r) => proc.once("exit", r)); rmSync(profile, { recursive: true, force: true }); },
  };
}

const until = async (f: () => Promise<boolean>, ms = 20000) => { const end = Date.now() + ms; while (Date.now() < end) { if (await f()) return true; await new Promise((r) => setTimeout(r, 100)); } return false; };
const pause = (ms: number) => new Promise((r) => setTimeout(r, ms));
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

test("a send from far up the history brings the view to the reply, and it stays pinned while the reply streams", { skip, timeout: 120_000 }, async () => {
  const p = await session_(false);
  try {
    // Read from the top, by your own scrolling.
    await wheel(p, -100_000);
    assert.ok(await gap(p) > 2000, `scrolled up to read (${await gap(p)} px from the end)`);
    await sendMessage(p, "and again");
    // Your message, then the reply's start, in view: at the end within a line.
    assert.ok(await until(async () => (await gap(p)) < 60, 3000), `the send brought the view to the end (${await gap(p)} px from it)`);
    // Pinned while it streams: sampled through the reply, never more than a line from the end.
    const worst: number[] = [];
    for (let i = 0; i < 20; i++) { await pause(100); worst.push(await gap(p)); }
    assert.ok(Math.max(...worst) < 80, `pinned to the end while the reply streams (worst ${Math.max(...worst)} px from it)`);
  } finally { await p.close(); }
});

test("scrolling up while it streams lets go; scrolling back to the end pins it again", { skip, timeout: 120_000 }, async () => {
  const p = await session_(false);
  try {
    await sendMessage(p, "one more");
    assert.ok(await until(async () => (await gap(p)) < 60, 3000), "at the end after the send");
    await pause(300);
    await wheel(p, -600);
    const away = await gap(p);
    assert.ok(away > 300, `scrolled up (${away} px from the end)`);
    await pause(800);
    assert.ok(await gap(p) >= away, `left where you scrolled while the reply grows (${await gap(p)} px from the end)`);
    await wheel(p, 100_000);
    await pause(800);
    assert.ok(await gap(p) < 80, `back at the end it follows again (${await gap(p)} px from it)`);
  } finally { await p.close(); }
});

test("with reduced motion the send jumps to the end", { skip, timeout: 120_000 }, async () => {
  const p = await session_(true);
  try {
    await wheel(p, -100_000);
    await sendMessage(p, "reduced");
    await pause(150);
    assert.ok(await gap(p) < 60, `jumped to the end (${await gap(p)} px from it)`);
  } finally { await p.close(); }
});

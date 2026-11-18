#!/usr/bin/env node
// Screenshots a page in headless Chrome over the DevTools protocol: no Puppeteer, just the `ws`
// package the web app already has.
//
//   node web-shot.mjs <url> <out.png> <width> <height> <light|dark>
//   WEB_SHOT_SCROLL='.widget' scrolls an element into view before the shot.
//   WEB_SHOT_STORAGE='{"frog.inspector":"1"}' seeds localStorage first (opens the inspector).
//   WEB_SHOT_CLICK='.line-row.fold .line' clicks an element (opens a fold) before the scroll.
//   WEB_SHOT_HOVER='.line-row .line' puts the pointer over an element (its hover plate) last.
import { spawn } from "node:child_process";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createRequire } from "node:module";

const require = createRequire(new URL("../../../apps/web/package.json", import.meta.url));
const WebSocket = require("ws");
const [url, out, w, h, look] = process.argv.slice(2);
const chrome = process.env.CHROME ?? "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const profile = mkdtempSync(join(tmpdir(), "frog-parity-"));
const proc = spawn(chrome, ["--headless=new", "--remote-debugging-port=0", `--user-data-dir=${profile}`, "--hide-scrollbars", "about:blank"], { stdio: ["ignore", "ignore", "pipe"] });
const wsUrl = await new Promise((resolve, reject) => {
  let buf = "";
  proc.stderr.on("data", (d) => { buf += d; const m = /DevTools listening on (ws:\/\/\S+)/.exec(buf); if (m) resolve(m[1]); });
  setTimeout(() => reject(new Error("chrome didn't start")), 15000);
});
const port = new URL(wsUrl).port;
const target = (await (await fetch(`http://127.0.0.1:${port}/json/list`)).json()).find((t) => t.type === "page");
const ws = new WebSocket(target.webSocketDebuggerUrl);
await new Promise((r) => ws.on("open", r));
let n = 0;
const call = (method, params = {}) => new Promise((resolve) => {
  const id = ++n;
  const on = (m) => { const v = JSON.parse(m); if (v.id === id) { ws.off("message", on); resolve(v.result); } };
  ws.on("message", on);
  ws.send(JSON.stringify({ id, method, params }));
});
await call("Emulation.setDeviceMetricsOverride", { width: +w, height: +h, deviceScaleFactor: 2, mobile: false });
await call("Emulation.setEmulatedMedia", { features: [{ name: "prefers-color-scheme", value: look }, { name: "prefers-reduced-motion", value: "reduce" }] });
await call("Page.enable");
// WEB_SHOT_STORAGE='{"frog.inspector":"1"}': localStorage set before the app loads (the inspector shots).
if (process.env.WEB_SHOT_STORAGE) {
  const kv = JSON.parse(process.env.WEB_SHOT_STORAGE);
  await call("Page.addScriptToEvaluateOnNewDocument", { source: `try { for (const [k, v] of Object.entries(${JSON.stringify(kv)})) localStorage.setItem(k, v) } catch {}` });
}
await call("Page.navigate", { url });
await new Promise((r) => setTimeout(r, Number(process.env.WEB_SHOT_WAIT ?? 6000)));
// WEB_SHOT_CLICK=<selector>: click it first (a fold, a line).
if (process.env.WEB_SHOT_CLICK) {
  // Scroll there first, so the transcript stops following its end before the click grows it.
  if (process.env.WEB_SHOT_SCROLL) {
    await call("Runtime.evaluate", { expression: `document.querySelector(${JSON.stringify(process.env.WEB_SHOT_SCROLL)})?.scrollIntoView({block:'start'})` });
    await new Promise((r) => setTimeout(r, 800));
  }
  // A real click event at the element's middle: SVG elements have no .click().
  await call("Runtime.evaluate", { expression: `(() => { const el = document.querySelector(${JSON.stringify(process.env.WEB_SHOT_CLICK)}); if (!el) return; const r = el.getBoundingClientRect(); el.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, clientX: r.left + r.width / 2, clientY: r.top + r.height / 2 })) })()` });
  await new Promise((r) => setTimeout(r, 500));
}
// WEB_SHOT_SCROLL=<selector>: bring that element to the top first (the visuals shots).
if (process.env.WEB_SHOT_SCROLL) {
  // Twice: the transcript follows its end while content settles (an opened fold grows it).
  for (let i = 0; i < 2; i++) {
    await call("Runtime.evaluate", { expression: `document.querySelector(${JSON.stringify(process.env.WEB_SHOT_SCROLL)})?.scrollIntoView({block:'start'})` });
    await new Promise((r) => setTimeout(r, 800));
  }
}
// WEB_SHOT_HOVER=<selector>: the pointer over it, for its hover state.
if (process.env.WEB_SHOT_HOVER) {
  const { result } = await call("Runtime.evaluate", { expression: `(() => { const r = document.querySelector(${JSON.stringify(process.env.WEB_SHOT_HOVER)})?.getBoundingClientRect(); return r ? [r.left + r.width / 2, r.top + r.height / 2] : null })()`, returnByValue: true });
  if (result?.value) {
    await call("Input.dispatchMouseEvent", { type: "mouseMoved", x: result.value[0], y: result.value[1] });
    await new Promise((r) => setTimeout(r, 400));
  }
}
// And once more just before the shot: the app's scroll ref pins the end on its own re-renders.
if (process.env.WEB_SHOT_SCROLL) {
  await call("Runtime.evaluate", { expression: `document.querySelector(${JSON.stringify(process.env.WEB_SHOT_SCROLL)})?.scrollIntoView({block:'start'})` });
  await new Promise((r) => setTimeout(r, 50));
}
const { data } = await call("Page.captureScreenshot", { format: "png" });
writeFileSync(out, Buffer.from(data, "base64"));
ws.close();
proc.kill();
await new Promise((r) => proc.once("exit", r));
try { rmSync(profile, { recursive: true, force: true, maxRetries: 5 }); } catch {}
console.log(out);

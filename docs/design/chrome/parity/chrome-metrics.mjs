#!/usr/bin/env node
// The web's chrome metrics: where the window chrome's controls stand (the top-right group and
// each button, the turn rail, the title's menu), as `frog-chrome-metrics/1` for diff-chrome.mjs
// to compare with the Mac's (`-FrogChromeMetrics`). Found by accessibility label, as the Mac's
// dump finds them, in headless Chrome over the DevTools protocol (like ../../parity/metrics.mjs).
//
//   node chrome-metrics.mjs <url> <out.json> <width> <height> [light|dark]
//   METRICS_WAIT=6000 (ms to let the session load)
//   METRICS_STORAGE='{"frog.inspector":"1"}' seeds localStorage first
import { spawn } from "node:child_process";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createRequire } from "node:module";

const require = createRequire(new URL("../../../../apps/web/package.json", import.meta.url));
const WebSocket = require("ws");
const [url, out, w, h, look = "dark"] = process.argv.slice(2);
if (!url || !out || !w || !h) {
  console.error("usage: node chrome-metrics.mjs <url> <out.json> <width> <height> [light|dark]");
  process.exit(2);
}

/** Runs in the page. The same ids and labels as ChromeMetrics.swift. Kept free of outer references. */
function measure() {
  const wanted = [
    ["group", (l) => l === "Window controls"],
    ["split", (l) => l === "Split"],
    ["palette", (l) => l === "Commands"],
    ["inspector", (l) => l === "Inspector"],
    ["rail", (l) => l.startsWith("Timeline")],
    ["title", (l) => l === "Session menu"],
  ];
  const r1 = (v) => Math.round(v * 10) / 10;
  const width = document.documentElement.clientWidth;
  const controls = [];
  for (const [id, match] of wanted) {
    const el = [...document.querySelectorAll("[aria-label]")].find((e) => match(e.getAttribute("aria-label")) && e.getBoundingClientRect().width > 0);
    if (!el) continue;
    // The title: its words, as the Mac's AX frame for the title menu is (the chevron is outside it).
    const b = (id === "title" ? el.querySelector(".title-text") ?? el : el).getBoundingClientRect();
    controls.push({ id, x: r1(b.left), top: r1(b.top), width: r1(b.width), height: r1(b.height), right: r1(width - b.right) });
  }
  return { controls, main: r1(document.querySelector(".main")?.getBoundingClientRect().left ?? 0) };
}

const chrome = process.env.CHROME ?? "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const profile = mkdtempSync(join(tmpdir(), "frog-chrome-"));
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
await call("Emulation.setDeviceMetricsOverride", { width: +w, height: +h, deviceScaleFactor: 2, mobile: +w < 768 });
await call("Emulation.setEmulatedMedia", { features: [{ name: "prefers-color-scheme", value: look }, { name: "prefers-reduced-motion", value: "reduce" }] });
await call("Page.enable");
if (process.env.METRICS_STORAGE) {
  await call("Page.addScriptToEvaluateOnNewDocument", { source: `try { for (const [k, v] of Object.entries(${process.env.METRICS_STORAGE})) localStorage.setItem(k, v) } catch {}` });
}
await call("Page.navigate", { url });
await new Promise((r) => setTimeout(r, Number(process.env.METRICS_WAIT ?? 6000)));
const res = await call("Runtime.evaluate", { expression: `document.fonts.ready.then(() => (${measure.toString()})())`, awaitPromise: true, returnByValue: true });
ws.close();
proc.kill();
await new Promise((r) => proc.once("exit", r));
try { rmSync(profile, { recursive: true, force: true, maxRetries: 5 }); } catch {}
const v = res?.result?.value;
if (!v) { console.error(`chrome-metrics.mjs: ${JSON.stringify(res)}`); process.exit(1); }
const dump = { format: "frog-chrome-metrics/1", app: "web", width: +w, height: +h, look, main: v.main, controls: v.controls };
writeFileSync(out, JSON.stringify(dump, null, 2) + "\n");
console.log(`${out}: ${v.controls.map((c) => c.id).join(", ") || "nothing found"}`);

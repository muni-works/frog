#!/usr/bin/env node
// The web's transcript metrics: every row of the page's transcript as JSON (kind, text, the x of
// its first word, top, height, font size), for diff-metrics.mjs to compare with the Mac's dump.
// The format is in README.md, "Metrics". Headless Chrome over the DevTools protocol, like
// web-shot.mjs.
//
//   node metrics.mjs <url> <out.json> <width> <height> [light|dark]
//   METRICS_WAIT=6000 (ms to let the session load)
import { spawn } from "node:child_process";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createRequire } from "node:module";

const require = createRequire(new URL("../../../apps/web/package.json", import.meta.url));
const WebSocket = require("ws");
const [url, out, w, h, look = "dark"] = process.argv.slice(2);
if (!url || !out || !w || !h) {
  console.error("usage: node metrics.mjs <url> <out.json> <width> <height> [light|dark]");
  process.exit(2);
}

/** Runs in the page: the transcript's rows, top to bottom. Kept free of outer references. */
function measure() {
  const col = document.querySelector(".tx");
  if (!col) return { error: "no .tx column on the page" };
  const cs = getComputedStyle(col);
  const edge = col.getBoundingClientRect().left + parseFloat(cs.paddingLeft);
  const clean = (s) => s.replace(/\s+/g, " ").trim();
  // The visible words of an element, without hover actions, receipts or marks.
  const words = (el) => {
    const c = el.cloneNode(true);
    c.querySelectorAll(".hover-row, .line-acts, .hover-acts, .line-mark, [aria-hidden='true'], .turn-card").forEach((x) => x.remove());
    return clean(c.textContent ?? "");
  };
  // The first non-blank character's box, skipping hover rows and marks.
  const first = (el) => {
    const walk = document.createTreeWalker(el, NodeFilter.SHOW_TEXT, {
      acceptNode: (n) => (!n.textContent.trim() || n.parentElement.closest(".hover-row, .line-acts, .hover-acts, .line-mark, [aria-hidden='true']")
        ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT),
    });
    const n = walk.nextNode();
    if (!n) return null;
    const i = n.textContent.search(/\S/);
    const r = document.createRange();
    r.setStart(n, i);
    r.setEnd(n, i + 1);
    return { rect: r.getBoundingClientRect(), font: parseFloat(getComputedStyle(n.parentElement).fontSize) };
  };
  const rows = [];
  const add = (kind, el, box = el) => {
    const f = first(el);
    const b = box.getBoundingClientRect();
    if (!f || b.height === 0) return;
    rows.push({ kind, text: words(el), x: f.rect.left - edge, top: b.top, height: b.height, fontSize: f.font });
  };
  for (const el of col.querySelectorAll(".me, .line-row, .say .md > *, [data-row='box'], .turn-foot, .thinking")) {
    if (el.closest(".fold-steps, .line-open")) continue;
    if (el.matches(".me")) add("prompt", el);
    else if (el.matches(".line-row")) {
      const kind = el.dataset.kind === "fold" ? "fold" : el.dataset.kind === "thought" ? "thought" : "line";
      add(kind, el.querySelector(".line"), el.querySelector(".line-plate"));
    } else if (el.matches(".turn-foot")) add("footer", el.querySelector(".turn-line") ?? el, el);
    else if (el.matches(".thinking")) add("live", el);
    else if (el.matches("[data-row='box']")) add("card", el.querySelector("b, .ask-h, h3") ?? el, el);
    else if (el.matches("ul, ol")) el.querySelectorAll(":scope > li").forEach((li) => add("prose", li));
    else if (el.matches(".md-code, .md-table")) add("code", el);
    else add("prose", el);
  }
  const top0 = rows[0]?.top ?? 0;
  const r1 = (v) => Math.round(v * 10) / 10;
  return {
    rows: rows.map((r) => ({ ...r, x: r1(r.x), top: r1(r.top - top0), height: r1(r.height), fontSize: r1(r.fontSize) })),
    column: r1(col.getBoundingClientRect().width - parseFloat(cs.paddingLeft) - parseFloat(cs.paddingRight)),
    gutter: r1(parseFloat(cs.paddingLeft)),
  };
}

const chrome = process.env.CHROME ?? "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const profile = mkdtempSync(join(tmpdir(), "frog-metrics-"));
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
await call("Page.navigate", { url });
await new Promise((r) => setTimeout(r, Number(process.env.METRICS_WAIT ?? 6000)));
const res = await call("Runtime.evaluate", { expression: `document.fonts.ready.then(() => (${measure.toString()})())`, awaitPromise: true, returnByValue: true });
ws.close();
proc.kill();
await new Promise((r) => proc.once("exit", r));
try { rmSync(profile, { recursive: true, force: true, maxRetries: 5 }); } catch {}
const v = res?.result?.value;
if (!v || v.error) { console.error(`metrics.mjs: ${v?.error ?? JSON.stringify(res)}`); process.exit(1); }
const dump = { format: "frog-transcript-metrics/1", app: "web", width: +w, height: +h, look, column: v.column, gutter: v.gutter, rows: v.rows };
writeFileSync(out, JSON.stringify(dump, null, 2) + "\n");
console.log(`${out}: ${v.rows.length} rows`);

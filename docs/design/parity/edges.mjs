#!/usr/bin/env node
// The web's transcript edges: where every element of the conversation column starts and ends,
// left and right, for check-edges.mjs (format below). Headless Chrome over the DevTools protocol,
// like metrics.mjs.
//
//   node edges.mjs <url> <out.json> <width> <height> [light|dark]
//   EDGES_WAIT=20000 (ms at most to let the session load)  EDGES_STORAGE='{"frog.inspector":"1"}'
//
// Format `frog-transcript-edges/1`: { format, app, width, height, look, column, indent,
// elements: [{ kind, part, text, left, right, claims }] }. Lengths are points (CSS px), rounded to
// 0.1, from the column's box edge: 0 is the left line for boxes, `indent` the left line for text
// (0 unless the gutter is too narrow for marks to hang), `column` the right line. `claims` say
// which line an element must sit on: "text" (left = indent), "box" (left = 0), "right" (right =
// column), "hung" (right <= indent: a mark in the gutter, never pushing text). An element with no
// claims is recorded for the table only (a card's title inside its padding, an inline code chip's
// background).
import { spawn } from "node:child_process";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createRequire } from "node:module";

/** Runs in the page: the column's elements and their edges. Kept free of outer references. */
export function measureEdges() {
  const col = document.querySelector(".tx");
  if (!col) return { error: "no .tx column on the page" };
  const cs = getComputedStyle(col);
  const edge = col.getBoundingClientRect().left + parseFloat(cs.paddingLeft);
  const column = col.getBoundingClientRect().width - parseFloat(cs.paddingLeft) - parseFloat(cs.paddingRight);
  const indent = parseFloat(getComputedStyle(document.documentElement).getPropertyValue("--tx-indent")) || parseFloat(getComputedStyle(col).getPropertyValue("--tx-indent")) || 0;
  const clean = (s) => (s ?? "").replace(/\s+/g, " ").trim();
  const skip = ".hover-row, .line-acts, .hover-acts, .line-mark, .ticks, .turn-card, [aria-hidden='true']";
  // The visible text nodes of an element, in order, minus hover actions and marks.
  const texts = (el) => {
    const walk = document.createTreeWalker(el, NodeFilter.SHOW_TEXT, {
      acceptNode: (n) => (!n.textContent.trim() || n.parentElement.closest(skip) || !n.parentElement.getClientRects().length
        ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT),
    });
    const out = [];
    for (let n = walk.nextNode(); n; n = walk.nextNode()) out.push(n);
    return out;
  };
  const glyph = (n, i) => { const r = document.createRange(); r.setStart(n, i); r.setEnd(n, i + 1); return r.getBoundingClientRect(); };
  // The left of the first visible character and the right of the last (any line of a wrap).
  const ink = (el) => {
    const ns = texts(el);
    if (!ns.length) return null;
    const first = glyph(ns[0], ns[0].textContent.search(/\S/));
    let right = -Infinity;
    for (const n of ns) {
      // Each non-blank character's box: trailing spaces would otherwise stretch the right edge.
      const t = n.textContent;
      const z = t.length - 1 - (t.length - t.trimEnd().length);
      if (z >= 0) right = Math.max(right, glyph(n, z).right);
      const r = document.createRange(); r.setStart(n, 0); r.setEnd(n, z + 1);
      for (const b of r.getClientRects()) right = Math.max(right, b.right);
    }
    return { left: first.left, right, text: clean(ns.map((n) => n.textContent).join(" ")) };
  };
  const out = [];
  const push = (kind, part, text, left, right, claims) => out.push({ kind, part, text: clean(text).slice(0, 60), left: left - edge, right: right - edge, claims });
  const box = (kind, part, el, claims, text = "") => { if (!el) return; const b = el.getBoundingClientRect(); if (b.width) push(kind, part, text || el.textContent, b.left, b.right, claims); };
  // Clamped to the element's box: a truncated result's hidden overflow isn't drawn.
  const word = (kind, part, el, claims) => { if (!el) return; const k = ink(el); if (k) push(kind, part, k.text, k.left, Math.min(k.right, el.getBoundingClientRect().right), claims); };
  // The drawn marks of the turn line (its strip and curve), not its box: what the eye lines up.
  const graph = (kind, el) => {
    const svg = el?.querySelector(".turn-graph svg");
    if (!svg) return;
    let l = Infinity, r = -Infinity;
    for (const s of svg.querySelectorAll("path, rect, line, polyline, circle")) { const b = s.getBoundingClientRect(); if (b.width || b.height) { l = Math.min(l, b.left); r = Math.max(r, b.right); } }
    if (r > l) push(kind, "turn line (drawn)", "", l, r, ["right"]);
    box(kind, "turn line (box)", svg, ["right"], " ");
  };
  const top = (el) => !el.closest(".fold-steps, .outline, .thought-body");
  for (const el of col.querySelectorAll(".me, .line-row, .say .md > *, [data-row='box'], .banner, .turn-note, .turn-foot, .live-row, .live-tail")) {
    if (!top(el)) continue;
    if (el.matches(".me")) { box("prompt", "bubble", el, ["right"]); continue; }
    if (el.matches(".line-row")) {
      if (el.closest(".line-open")) continue;
      const kind = el.dataset.kind === "fold" ? "fold" : el.dataset.kind === "thought" ? "thought" : `line:${el.dataset.kind ?? "?"}`;
      word(kind, "words", el.querySelector(".line-plate .line"), ["text"]);
      box(kind, "mark", el.querySelector(".line-plate .line-mark"), ["hung"], " ");
      // Without hover (touch) a row's actions are always drawn, in the row after its result
      // (apps/web/src/phone.css), so they, not the result, are what reaches the right edge.
      const acts = el.querySelector(".line-plate > .line-acts");
      const drawn = !!acts && getComputedStyle(acts).position === "static" && acts.getBoundingClientRect().width > 0;
      word(kind, "result", el.querySelector(".line-plate .line-result"), drawn ? [] : ["right"]);
      if (drawn) box(kind, "actions (no hover)", acts, ["right"], " ");
      const open = el.querySelector(":scope > .line-open");
      if (open) {
        word(kind, "opened: failing tests", open.querySelector(".line-failing"), ["text"]);
        // Under its line's words: on the text line (at 26 in a narrow pane, as on the Mac).
        box(kind, "opened: output box", open.querySelector(".line-out, .line-box, .line-said"), ["text", "right"]);
        word(kind, "opened: caption", open.querySelector(".line-foot > span"), ["text"]);
      }
      continue;
    }
    if (el.matches(".live-row, .live-tail")) {
      if (el.matches(".live-row")) {
        word("live", "words", el.querySelector(".line"), ["text"]);
        box("live", "mark", el.querySelector(".line-mark"), ["hung"], " ");
      }
      const st = el.querySelector(".live-stats");
      if (st) { word("stats", "words", st, ["text"]); graph("stats", st); }
      continue;
    }
    if (el.matches(".turn-foot")) { word("footer", "words", el.querySelector(".turn-line") ?? el, ["text"]); graph("footer", el); continue; }
    if (el.matches(".turn-note")) { word("note", "words", el, ["text"]); continue; }
    if (el.matches(".banner")) { box("error", "box", el, ["box", "right"]); word("error", "words", el, []); continue; }
    if (el.matches("[data-row='box']")) {
      const card = el.firstElementChild ?? el;
      const kind = card.matches(".widget, .widget-card") || card.querySelector(".widget") ? "visual" : card.matches(".ask-card") ? "question card" : "card";
      box(kind, "box", card, ["box", "right"]);
      word(kind, "title (inside)", card.querySelector("b, .ask-h, h3, .widget-h") ?? card, []);
      continue;
    }
    // A reply's blocks.
    if (el.matches("ul, ol")) {
      for (const li of el.querySelectorAll(":scope > li")) {
        const k = ink(li);
        const dot = li.querySelector(":scope > .md-dot, :scope > .md-num");
        // The item's words: past its own bullet span, if it draws one.
        const words = dot ? (() => { const c = texts(li).filter((n) => !dot.contains(n)); return c.length ? { left: glyph(c[0], c[0].textContent.search(/\S/)).left } : null })() : k;
        if (words) push("list item", "words", k?.text ?? "", words.left, k.right, ["text"]);
      }
      continue;
    }
    if (el.matches(".md-code")) { box("code", "box", el, ["box", "right"], " "); continue; }
    if (el.matches(".md-table")) { box("table", "box", el.querySelector("table") ?? el, ["box"], " "); continue; }
    if (el.matches("p, h1, h2, h3, h4, h5, h6, blockquote")) {
      const kind = /^H/.test(el.tagName) ? "heading" : el.firstElementChild?.matches("code") && !el.firstChild.textContent?.trim() || el.firstChild === el.firstElementChild && el.firstElementChild?.matches("code") ? "prose (opens with code)" : "prose";
      word(kind, "words", el, ["text"]);
      if (kind === "prose (opens with code)") box(kind, "chip background", el.firstElementChild, [], " ");
    }
  }
  const dock = document.querySelector(".dock .f-composer") ?? document.querySelector(".dock > *");
  if (dock) {
    box("composer", "box", dock, ["box", "right"], " ");
    const ta = dock.querySelector("textarea");
    if (ta) { const b = ta.getBoundingClientRect(), s = getComputedStyle(ta); push("composer", "text (inside)", ta.value || ta.placeholder, b.left + parseFloat(s.paddingLeft), b.right - parseFloat(s.paddingRight), []); }
  }
  const r1 = (v) => Math.round(v * 10) / 10;
  return { column: r1(column), indent: r1(indent), elements: out.map((e) => ({ ...e, left: r1(e.left), right: r1(e.right) })) };
}

/** The page at `url` in headless Chrome at w × h (2×), measured: the dump without its header. */
export async function measureURL(url, w, h, look = "dark", { wait = 8000, storage, chrome: bin } = {}) {
  const require = createRequire(new URL("../../../apps/web/package.json", import.meta.url));
  const WebSocket = require("ws");
  const chrome = bin ?? process.env.CHROME ?? "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
  const profile = mkdtempSync(join(tmpdir(), "frog-edges-"));
  // Ubuntu's AppArmor stops Chrome's own sandbox on CI runners; the pages here are ours.
  const linux = process.platform === "linux" ? ["--no-sandbox"] : [];
  const proc = spawn(chrome, ["--headless=new", "--remote-debugging-port=0", `--user-data-dir=${profile}`, "--hide-scrollbars", ...linux, "about:blank"], { stdio: ["ignore", "ignore", "pipe"] });
  try {
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
    if (storage) await call("Page.addScriptToEvaluateOnNewDocument", { source: `try { for (const [k, v] of Object.entries(${JSON.stringify(storage)})) localStorage.setItem(k, v) } catch {}` });
    await call("Page.navigate", { url });
    // Until the column has its composer and the held turn's live row (the last thing to draw).
    const until = Date.now() + wait;
    while (Date.now() < until) {
      const r = await call("Runtime.evaluate", { expression: "!!document.querySelector('.tx .live-row') && !!document.querySelector('.dock')", returnByValue: true });
      if (r?.result?.value) break;
      await new Promise((r) => setTimeout(r, 250));
    }
    await new Promise((r) => setTimeout(r, 600));
    const res = await call("Runtime.evaluate", { expression: `document.fonts.ready.then(() => (${measureEdges.toString()})())`, awaitPromise: true, returnByValue: true });
    ws.close();
    const v = res?.result?.value;
    if (!v || v.error) throw new Error(`edges.mjs: ${v?.error ?? JSON.stringify(res)}`);
    return { format: "frog-transcript-edges/1", app: "web", width: +w, height: +h, look, ...v };
  } finally {
    proc.kill();
    await new Promise((r) => proc.once("exit", r));
    try { rmSync(profile, { recursive: true, force: true, maxRetries: 5 }); } catch {}
  }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const [url, out, w, h, look = "dark"] = process.argv.slice(2);
  if (!url || !out || !w || !h) {
    console.error("usage: node edges.mjs <url> <out.json> <width> <height> [light|dark]");
    process.exit(2);
  }
  const dump = await measureURL(url, w, h, look, { wait: Number(process.env.EDGES_WAIT ?? 20000), storage: process.env.EDGES_STORAGE ? JSON.parse(process.env.EDGES_STORAGE) : undefined });
  writeFileSync(out, JSON.stringify(dump, null, 2) + "\n");
  console.log(`${out}: ${dump.elements.length} elements`);
}

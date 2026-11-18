// The left sidebar resizes by dragging its right edge, like the inspector its left (2026-11-17):
// 270 by default, 220 to 400, kept in localStorage['frog.sidebarWidth'], double-click resets,
// delivered as --side-w. The clamp and persistence are shared with the inspector (ui/resize.ts).
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createElement as h } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { clampWidth, loadWidth, saveWidth, clearWidth } from "../src/ui/resize.ts";
import { SIDEBAR, Shell } from "../src/ui/Docs.tsx";

/** A localStorage stand-in for node; `broken` throws like Safari's private mode used to. */
function fakeStorage(broken = false) {
  const m = new Map<string, string>();
  const fail = () => { if (broken) throw new Error("denied") };
  (globalThis as { localStorage?: unknown }).localStorage = {
    getItem: (k: string) => { fail(); return m.has(k) ? m.get(k)! : null },
    setItem: (k: string, v: string) => { fail(); m.set(k, String(v)) },
    removeItem: (k: string) => { fail(); m.delete(k) },
  };
  return m;
}

test("the sidebar's width is 270 by default, dragged between 220 and 400", () => {
  assert.deepEqual(SIDEBAR, { initial: 270, min: 220, max: 400 });
  assert.equal(clampWidth(SIDEBAR, 100), 220);
  assert.equal(clampWidth(SIDEBAR, 900), 400);
  assert.equal(clampWidth(SIDEBAR, 301.6), 302, "whole pixels");
  assert.equal(clampWidth(SIDEBAR, 270), 270);
});

test("the sidebar's width is kept per browser, clamped on the way back in", () => {
  const m = fakeStorage();
  assert.equal(loadWidth("frog.sidebarWidth", SIDEBAR), 270, "nothing stored: the default");
  saveWidth("frog.sidebarWidth", 333);
  assert.equal(m.get("frog.sidebarWidth"), "333");
  assert.equal(loadWidth("frog.sidebarWidth", SIDEBAR), 333);
  m.set("frog.sidebarWidth", "9000");
  assert.equal(loadWidth("frog.sidebarWidth", SIDEBAR), 400, "an old or hand-edited value is clamped");
  m.set("frog.sidebarWidth", "wide");
  assert.equal(loadWidth("frog.sidebarWidth", SIDEBAR), 270, "garbage: the default");
  clearWidth("frog.sidebarWidth");
  assert.ok(!m.has("frog.sidebarWidth"), "double-click forgets it");
  assert.equal(loadWidth("frog.sidebarWidth", SIDEBAR), 270);
});

test("storage that throws falls back to the default and never throws itself", () => {
  fakeStorage(true);
  assert.equal(loadWidth("frog.sidebarWidth", SIDEBAR), 270);
  assert.doesNotThrow(() => saveWidth("frog.sidebarWidth", 300));
  assert.doesNotThrow(() => clearWidth("frog.sidebarWidth"));
});

const shell = (mode: "threads" | "docs") => renderToStaticMarkup(h(Shell, {
  mode, className: "win", brand: h("div", { className: "brand" }),
  side: { threads: h("nav", null, "sessions"), docs: h("nav", null, "pages") },
  main: { threads: h("main", { className: "main" }), docs: h("main", { className: "main docs-main" }) },
}));

test("the shell sets --side-w and puts a grip right after the sidebar, in both modes", () => {
  for (const mode of ["threads", "docs"] as const) {
    fakeStorage();
    const html = shell(mode);
    assert.match(html, /<div class="win" style="--side-w:270px"><aside class="side">/, `${mode}: --side-w on the window`);
    assert.match(html, /<\/aside><div class="side-grip" role="separator" aria-orientation="vertical" aria-label="Resize the sidebar"><\/div>/, `${mode}: the grip follows the sidebar`);
  }
});

test("the shell reads the stored sidebar width", () => {
  const m = fakeStorage();
  m.set("frog.sidebarWidth", "350");
  assert.match(shell("threads"), /style="--side-w:350px"/);
  m.set("frog.sidebarWidth", "50");
  assert.match(shell("docs"), /style="--side-w:220px"/);
});

test("the inspector still reads its own width through the shared code", () => {
  const src = readFileSync(new URL("../src/ui/Inspector.tsx", import.meta.url), "utf8");
  assert.match(src, /useResizable\('frog\.inspectorWidth'/);
});

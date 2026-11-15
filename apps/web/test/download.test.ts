// The download chip's two gates are predicates (src/ui/download.ts), so these test the gates
// directly, and then render the real component/site to check the gates are wired to what ships.
// Every assertion here is written to fail with its gate removed: see the PR body for the red proof.
import { test } from "node:test";
import assert from "node:assert/strict";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { COARSE_POINTER, hasThisMac, isPhone, showsDownloadChip } from "../src/ui/download.ts";
import { DownloadAppChip } from "../src/ui/DownloadChip.tsx";
import { Settings } from "../src/ui/Overlays.tsx";
import { Inspector } from "../src/ui/Inspector.tsx";
import { Composer } from "../src/ui/Composer.tsx";
import type { Machine } from "../src/machines.ts";

const noop = () => {};

const mac: Machine = { id: "this-mac", name: "studio", thisMac: true, hardware: "M4 Max · 64 GB unified", online: true, model: null, totalBytes: 64 * 2 ** 30,
  models: [{ id: "mlx-community/Qwen3-8B-4bit", name: "Qwen3-8B-4bit", hash: "aaaaaaaaaaaa11", loaded: true }] };
const mew: Machine = { id: "n1", name: "mew", hardware: "RTX 3090 · 24 GB VRAM", online: true, model: "Qwen3-4B", decode: 58.4, totalBytes: 24 * 2 ** 30,
  models: [{ id: "Qwen/Qwen3-4B", name: "Qwen3-4B", hash: "bbbbbbbbbbbb22", loaded: true }] };

// --- gate 1: the platform -------------------------------------------------

test("gate 1 — a coarse pointer is a phone, anything else is not", () => {
  assert.equal(isPhone((q) => q === COARSE_POINTER), true);
  assert.equal(isPhone(() => false), false, "a desktop with a mouse is not a phone");
  assert.equal(isPhone((q) => q === "(min-width: 100px)"), false, "only the coarse-pointer query counts");
});

test("gate 1 — with no matchMedia at all (a bare node, an old browser), it is not a phone", () => {
  assert.equal(isPhone(), false);
});

// --- gate 2: they already have the app -----------------------------------

test("gate 2 — a paired This Mac on any row means they have the app", () => {
  assert.equal(hasThisMac([mew, mac]), true);
  assert.equal(hasThisMac([mew]), false);
  assert.equal(hasThisMac([]), false);
  assert.equal(hasThisMac(), false);
});

// --- both gates: the truth table -----------------------------------------

test("both gates — the chip shows only on a non-phone without the app", () => {
  assert.equal(showsDownloadChip({ thisMac: false, phone: false }), true, "desktop browser, no app: show");
  assert.equal(showsDownloadChip({ thisMac: true, phone: false }), false, "they have the app: hide");
  assert.equal(showsDownloadChip({ thisMac: false, phone: true }), false, "iOS/Android can't run a .dmg: hide");
  assert.equal(showsDownloadChip({ thisMac: true, phone: true }), false, "both: hide");
});

// --- the component: the gates reach what ships ---------------------------

const chip = (props: { machines?: Machine[]; phone?: boolean; label?: string }) =>
  renderToStaticMarkup(createElement(DownloadAppChip, { label: props.label ?? "Runs from the Mac app", machines: props.machines, phone: props.phone }));

test("the chip is a quiet /download link with the label, and nothing else", () => {
  const html = chip({ machines: [mew], phone: false });
  assert.match(html, /href="\/download"/, html);
  assert.match(html, /Runs from the Mac app/);
  // Never the tarball route: a release has shipped without CLI tarballs.
  assert.ok(!/install\.sh|\.tar\.gz|\.tgz/.test(html), `the chip pointed at a tarball: ${html}`);
});

test("the chip renders nothing when they have the app", () => {
  assert.equal(chip({ machines: [mew, mac], phone: false }), "");
});

test("the chip renders nothing on a phone", () => {
  assert.equal(chip({ machines: [mew], phone: true }), "");
});

// --- the sites: the disabled affordances are gone, the chip is there ------

const settings = (machines: Machine[], machine?: string) =>
  renderToStaticMarkup(createElement(Settings, { account: null, tab: "Models" as const, machines, machine, onSignOut: noop, onClose: noop }));

test("Settings › Models › Pair a machine points at the Mac app instead of dead-ending", () => {
  const html = settings([mew]);
  assert.match(html, /Pair machines in the Mac app/);
  assert.match(html, /href="\/download"/);
});

test("Settings › Models › a machine page replaces Stop, Rename and Unpair with the chip", () => {
  const html = settings([mew], "n1");
  assert.ok(!/disabled=""[^>]*>Stop</.test(html), `a disabled Stop button survived: ${html}`);
  assert.ok(!/Rename…/.test(html), `a disabled Rename button survived: ${html}`);
  assert.ok(!/Unpair mew…/.test(html), `a disabled Unpair button survived: ${html}`);
  assert.match(html, /Stop it in the Mac app/);
  assert.match(html, /Rename it in the Mac app/);
  assert.match(html, /Unpair mew in the Mac app/);
});

test("the Inspector's Preview tab points at the Mac app rather than dead-ending", () => {
  const thread = { changes: [], panes: {} } as unknown as Parameters<typeof Inspector>[0]["thread"];
  const html = renderToStaticMarkup(createElement(Inspector, { thread, hasPr: false, onClose: noop, onCommit: noop, onPr: noop, send: noop, machines: [mew], pane: "preview" }));
  assert.match(html, /The Mac app has Preview/);
  assert.match(html, /href="\/download"/);
  // Already has the app (a paired This Mac): the sentence stands alone, with no chip.
  const withApp = renderToStaticMarkup(createElement(Inspector, { thread, hasPr: false, onClose: noop, onCommit: noop, onPr: noop, send: noop, machines: [mew, mac], pane: "preview" }));
  assert.ok(!withApp.includes("/download"), withApp);
});

// --- the composer's model menu: the dead rows give way to the chip -------

const composer = (machines: Machine[]) =>
  renderToStaticMarkup(createElement(Composer, {
    machines, openModels: true, models: [], onSend: noop, onMode: noop, onModel: noop,
  }));

test("the model menu's machine rows give way to one download hint", () => {
  const html = composer([mew]);
  assert.match(html, /Runs from the Mac app/);
  assert.match(html, /href="\/download"/);
  // No dead machine row beside it: the chip replaces it, it doesn't sit next to it.
  assert.ok(!/Qwen3-4B/.test(html), `a dead machine model row survived: ${html}`);
  assert.ok(!/menuitemradio[^>]*disabled title="Runs from the Mac app"/.test(html), html);
});

test("the model menu keeps its machine rows when they already have the app", () => {
  // A paired This Mac suppresses the chip, so the rows are what's left to show.
  const html = composer([mew, mac]);
  assert.ok(!html.includes("/download"), `the chip showed to someone with the app: ${html}`);
  assert.match(html, /Qwen3-4B/, html);
});

// The download chip's two gates are predicates (src/ui/download.ts), so these test the gates
// directly, and then render the real component/site to check the gates are wired to what ships.
// Every assertion here is written to fail with its gate removed: see the PR body for the red proof.
import { test } from "node:test";
import assert from "node:assert/strict";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { COARSE_POINTER, HANDOFF_DRAFT_KEY, MAX_LINK_PROMPT, hasThisMac, inviteFor, isMacVisitor, isPhone, macHandoff, newSessionHref, openWithFallback, showsDownloadChip, takeHandoffDraft, type FallbackEnv } from "../src/ui/download.ts";
import { DownloadAppChip } from "../src/ui/DownloadChip.tsx";
import { SettingsPage } from "../src/ui/Settings.tsx";
import { Inspector } from "../src/ui/Inspector.tsx";
import { Composer } from "../src/ui/Composer.tsx";
import type { Machine } from "../src/machines.ts";

const noop = () => {};

const mac: Machine = { id: "this-mac", name: "studio", thisMac: true, hardware: "M4 Max, 64 GB unified", online: true, model: null, totalBytes: 64 * 2 ** 30,
  models: [{ id: "mlx-community/Qwen3-8B-4bit", name: "Qwen3-8B-4bit", hash: "aaaaaaaaaaaa11", loaded: true }] };
const mew: Machine = { id: "n1", name: "mew", hardware: "RTX 3090, 24 GB VRAM", online: true, model: "Qwen3-4B", decode: 58.4, totalBytes: 24 * 2 ** 30,
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
  renderToStaticMarkup(createElement(SettingsPage, { section: "models" as const, account: null, machines, machine, onOpen: noop, onSignOut: noop }));

/** Render as a visitor on a Mac (or not): the invitation's platform gate reads the user agent. */
function asVisitor<T>(ua: string, f: () => T): T {
  const was = Object.getOwnPropertyDescriptor(globalThis, "navigator");
  Object.defineProperty(globalThis, "navigator", { value: { userAgent: ua }, configurable: true });
  try { return f(); } finally { if (was) Object.defineProperty(globalThis, "navigator", was); }
}
const MAC_UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_1) AppleWebKit/605.1.15";
const PC_UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36";
/** The invitation rows' pills, by row id. */
const invites = (html: string) => Object.fromEntries(html.split('data-row="').slice(1).flatMap((chunk) => {
  const m = chunk.match(/^([\w-]+)"[^]*?(<a class="f-pill invite-pill"[^>]*>[^<]*<\/a>|<span class="det invite-elsewhere"[^>]*>[^<]*<\/span>)/);
  return m ? [[m[1], m[2]]] : [];
}));

test("Settings › Models: the Mac's rows sit under On your Mac, each with Get the Mac app on a Mac", () => {
  const html = asVisitor(MAC_UA, () => settings([mew]));
  assert.ok(html.indexOf("On your Mac") > html.indexOf("Frog Cloud"), "invitations come after the working rows");
  const pills = invites(html);
  assert.deepEqual(Object.keys(pills), ["pair-machine", "local-models"]);
  for (const [id, a] of Object.entries(pills)) assert.match(a, /href="\/download"[^>]*>Get the Mac app</, id);
  assert.match(html, /Run models on this computer/, "the invitation's web words");
});

test("an invitation reads Open in Frog for Mac when the account has a Mac, and On a Mac off one", () => {
  const withApp = invites(asVisitor(MAC_UA, () => settings([mew, mac])));
  assert.match(withApp["pair-machine"], /href="frog:\/\/settings\/models"[^>]*>Open in Frog for Mac</);
  const pc = invites(asVisitor(PC_UA, () => settings([mew])));
  assert.match(pc["pair-machine"], /^<span class="det invite-elsewhere"[^>]*>On a Mac<\/span>$/);
  // An iPad says Macintosh too; a coarse pointer rules it out.
  const ipad = inviteFor({ mac: isMacVisitor((q) => q === "(pointer: coarse)", MAC_UA), thisMac: false });
  assert.equal(ipad, "elsewhere");
});

test("Settings › Models › a machine page: no dead Stop, Rename or Unpair; rename and share are invitations", () => {
  const html = asVisitor(MAC_UA, () => settings([mew], "n1"));
  assert.ok(!/disabled=""[^>]*>Stop</.test(html), `a disabled Stop button survived: ${html}`);
  assert.ok(!/Rename…/.test(html), `a disabled Rename button survived: ${html}`);
  assert.ok(!/Unpair mew…/.test(html), `a disabled Unpair button survived: ${html}`);
  assert.ok(!/type="checkbox"[^>]*disabled/.test(html), `a dead switch survived: ${html}`);
  assert.deepEqual(Object.keys(invites(html)), ["machine-name", "share-models"]);
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

// --- the composer's model menu: local models are rows that hand off to the Mac app ----------

const composer = (machines: Machine[], ua = MAC_UA, extra: { draft?: string; repo?: string } = {}) =>
  asVisitor(ua, () => renderToStaticMarkup(createElement(Composer, {
    machines, openModels: true, models: [], onSend: noop, onMode: noop, onModel: noop, ...extra,
  })));
/** The menu's local rows: href, label and the muted machine names. */
const localRowsOf = (html: string) => [...html.matchAll(/<a class="cz-row cz-local" role="menuitem" href="([^"]+)"[^>]*aria-label="([^"]+)"[^>]*>(.*?)<\/a>/g)]
  .map(([, href, label, inner]) => ({ href, label, on: /class="cz-on">([^<]*)</.exec(inner)?.[1] ?? null, inner }))

test("with no machines reported, the menu still lists the local models, then one download line", () => {
  const html = composer([]);
  const rows = localRowsOf(html);
  assert.deepEqual(rows.map((r) => r.label.split(",")[0]), ["Qwen3 4B", "Qwen3 8B", "Qwen3 32B", "Qwen3 1.7B", "Gemma 3 4B"]);
  assert.deepEqual(rows.map((r) => r.href), ["qwen3-4b", "qwen3-8b", "qwen3-32b", "qwen3-1.7b", "gemma-3-4b"].map((m) => `frog://new?model=${m}`),
    "the web can't tell if the app is there: try it (the download is the fallback)");
  for (const r of rows) {
    assert.match(r.label, /, runs on your Mac, opens Frog for Mac, or gets it$/);
    assert.match(r.inner, /\$0 a token/);
    // Nothing guessed about where it is.
    assert.equal(r.on, null);
  }
  // Pickable, not dead: no disabled row, no radio that would start a cloud session.
  assert.ok(!/disabled/.test(html.slice(html.indexOf("Run it on your Mac"), html.indexOf("Runs from the Mac app"))), html);
  // The download line comes after the models, not instead of them.
  assert.ok(html.indexOf("Runs from the Mac app") > html.lastIndexOf("cz-local"), html);
});

test("a paired node shows where each model is, and the download line stays until there's a This Mac", () => {
  const rows = localRowsOf(composer([mew]));
  assert.equal(rows.find((r) => r.label.startsWith("Qwen3 4B,"))?.on, "mew");
  assert.match(rows[0].label, /^Qwen3 4B, runs on your Mac \(mew\), opens Frog for Mac, or gets it$/);
  assert.match(composer([mew]), /Runs from the Mac app/);
});

test("with the Mac app, rows open Frog for Mac and the download line goes", () => {
  const html = composer([mew, mac]);
  const rows = localRowsOf(html);
  for (const r of rows) assert.match(r.href, /^frog:\/\/new\?model=/);
  assert.match(rows[1].label, /^Qwen3 8B, runs on your Mac \(This Mac\), opens Frog for Mac$/);
  assert.ok(!html.includes("/download"), `the download showed to someone with the app: ${html}`);
});

test("off a Mac the rows point at the Mac app's page, not a .dmg", () => {
  for (const r of localRowsOf(composer([], PC_UA))) assert.equal(r.href, "/mac");
});

// --- frog://new: the draft and the model ride along ------------------------

test("the link carries the model, the draft and the repo, each encoded for Foundation", () => {
  assert.equal(newSessionHref({ model: "qwen3-8b", prompt: "fix the tests\nthen a+b & c=d?", repo: "muni-works/frog" }),
    "frog://new?model=qwen3-8b&prompt=fix%20the%20tests%0Athen%20a%2Bb%20%26%20c%3Dd%3F&repo=muni-works%2Ffrog");
  assert.equal(newSessionHref({ prompt: "✅ done" }), "frog://new?prompt=%E2%9C%85%20done");
  // What the Mac reads back (URLComponents decodes the same way): every character survives.
  const url = new URL(newSessionHref({ model: "qwen3-8b", prompt: "a+b c\n%20", repo: "o/n" }));
  assert.equal(decodeURIComponent(/prompt=([^&]*)/.exec(url.search)![1]), "a+b c\n%20");
});

test("empty parts are left off, and a message over the Mac's cap stays on the web", () => {
  assert.equal(newSessionHref({}), "frog://new");
  assert.equal(newSessionHref({ model: "qwen3-4b", prompt: "  \n ", repo: "" }), "frog://new?model=qwen3-4b");
  const at = "a".repeat(MAX_LINK_PROMPT);
  assert.equal(newSessionHref({ prompt: at }), `frog://new?prompt=${at}`);
  assert.equal(newSessionHref({ model: "qwen3-4b", prompt: at + "b" }), "frog://new?model=qwen3-4b", "dropped, not cut");
  // Counted in characters, not UTF-16 units: a capped message of emoji still goes.
  assert.ok(newSessionHref({ prompt: "🐸".repeat(MAX_LINK_PROMPT) }).includes("prompt="));
});

test("the hand-off by invitation: the app gets the link, an unsure Mac falls back, elsewhere learns", () => {
  const d = { model: "qwen3-8b", prompt: "hi" };
  assert.deepEqual(macHandoff("open", d), { href: "frog://new?model=qwen3-8b&prompt=hi", does: "opens Frog for Mac", title: "Opens in Frog for Mac" });
  const get = macHandoff("get", d);
  assert.equal(get.href, "frog://new?model=qwen3-8b&prompt=hi");
  assert.equal(get.fallback, "/download");
  assert.equal(macHandoff("elsewhere", d).href, "/mac");
  assert.equal(macHandoff("open", d).fallback, undefined, "with the app there's nothing to fall back to");
  for (const h of [macHandoff("open"), get, macHandoff("elsewhere")]) assert.ok(!h.title.includes(" · ") && !h.does.includes(" · "));
});

test("the menu's local rows carry what's typed and the session's repo", () => {
  const rows = localRowsOf(composer([mew, mac], MAC_UA, { draft: "make it faster", repo: "muni-works/frog" }));
  assert.equal(rows.find((r) => r.label.startsWith("Qwen3 8B,"))?.href.replace(/&amp;/g, "&"),
    "frog://new?model=qwen3-8b&prompt=make%20it%20faster&repo=muni-works%2Ffrog");
});

// --- the fallback: try the app, then the download, keeping the draft ------

const fakeEnv = () => {
  const went: string[] = [], stored = new Map<string, string>()
  const handlers = new Map<string, Set<() => void>>()
  let timer: (() => void) | null = null, hidden = false
  const env: FallbackEnv = {
    go: (h) => { went.push(h) },
    on: (e, f) => { const s = handlers.get(e) ?? new Set(); s.add(f); handlers.set(e, s); return () => s.delete(f) },
    hidden: () => hidden,
    storage: { setItem: (k, v) => { stored.set(k, v) } },
    later: (f) => { timer = f },
  }
  return { env, went, stored, fire: (e: string) => handlers.get(e)?.forEach((f) => f()), tick: () => timer?.(), hide: () => { hidden = true }, live: () => [...handlers.values()].reduce((n, s) => n + s.size, 0) }
}

test("nothing answers frog:// — the download, with the draft kept", () => {
  const f = fakeEnv();
  openWithFallback("frog://new?prompt=hi", "/download", "hi there", 2000, f.env);
  assert.deepEqual(f.went, ["frog://new?prompt=hi"], "the app first");
  f.tick();
  assert.deepEqual(f.went, ["frog://new?prompt=hi", "/download"]);
  assert.equal(f.stored.get(HANDOFF_DRAFT_KEY), "hi there");
  assert.equal(f.live(), 0, "listeners removed");
});

test("the app answered (the window went to it) — no download", () => {
  for (const e of ["blur", "pagehide", "visibilitychange"]) {
    const f = fakeEnv();
    openWithFallback("frog://new", "/download", "hi", 2000, f.env);
    f.fire(e);
    f.tick();
    assert.deepEqual(f.went, ["frog://new"], e);
    assert.equal(f.stored.size, 0);
  }
  const f = fakeEnv();
  openWithFallback("frog://new", "/download", "hi", 2000, f.env);
  f.hide();
  f.tick();
  assert.deepEqual(f.went, ["frog://new"], "a hidden tab means the app took it");
});

test("an empty draft isn't kept; a kept one comes back once", () => {
  const f = fakeEnv();
  openWithFallback("frog://new", "/download", "  ", 2000, f.env);
  f.tick();
  assert.equal(f.stored.size, 0);
  const store = new Map<string, string>([[HANDOFF_DRAFT_KEY, "kept"]]);
  const storage = { getItem: (k: string) => store.get(k) ?? null, removeItem: (k: string) => { store.delete(k) } };
  assert.equal(takeHandoffDraft(storage), "kept");
  assert.equal(takeHandoffDraft(storage), undefined);
});

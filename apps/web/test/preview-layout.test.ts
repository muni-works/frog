// The Preview tab's layout, measured in headless Chrome (test/chrome.ts) from parity/preview.tsx:
// one toolbar row whose every control sits inside it at every inspector width (360 to 560), the
// empty state centred with its icon clear of its words, the device menu, the honest state when
// the gateway has no previews, a failed load with Retry, and the progress line while loading.
// The 2026-11-17 regression was the toolbar's device buttons stacking out of the row as bare
// system buttons, and the empty state's icon sitting on its first words. Skips without Chrome.
import { after, before, test } from "node:test";
import assert from "node:assert/strict";
import { chrome, dumpDOM, serve } from "./chrome.ts";

type Rect = { x: number; y: number; w: number; h: number };
type Geom = {
  state: string; w: number;
  inspector: Rect; strip: Rect | null; bar: Rect | null; stage: Rect | null; frame: Rect | null; iframe: Rect | null; progress: Rect | null;
  controls: { label: string; tag: string; inField: boolean; rect: Rect; bg: string }[];
  empty: { box: Rect; icon: Rect | null; text: { text: string; rect: Rect }[]; buttons: string[] } | null;
  menu: { rect: Rect; bg: string; items: { text: string; checked: string | null; disabled: boolean; rect: Rect }[] } | null;
  address: string | null;
  text: string;
};

const skip = chrome ? false : "no Chrome on this machine";
// Each test ends as a named failure within a minute; the file as a whole runs longer (npm test's --test-timeout).

let server: Awaited<ReturnType<typeof serve>> | undefined;
before(async () => { if (chrome) server = await serve(); });
after(async () => { await server?.close(); });

const decode = (s: string) => s.replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&amp;/g, "&");

async function geom(state: string, w = 360, theme = "dark", h = 560): Promise<Geom> {
  const dom = await dumpDOM(`${server!.origin}/parity/preview.html?state=${state}&w=${w}&h=${h}&theme=${theme}`, w, h);
  const m = dom.match(/<pre id="geom"[^>]*data-done="1"[^>]*>([\s\S]*?)<\/pre>/);
  assert.ok(m, `the parity page measured ${state} at ${w}`);
  return JSON.parse(decode(m[1]));
}

const E = 0.5;
const inside = (a: Rect, b: Rect) => a.x >= b.x - E && a.y >= b.y - E && a.x + a.w <= b.x + b.w + E && a.y + a.h <= b.y + b.h + E;
const overlap = (a: Rect, b: Rect) => a.x < b.x + b.w - E && b.x < a.x + a.w - E && a.y < b.y + b.h - E && b.y < a.y + a.h - E;
const WHITE = /^rgba?\(255, 255, 255(, 1)?\)$|^rgb\(2[34]\d, 2[34]\d, 2[34]\d\)$/;

/** An open menu holds its items (2026-11-17: the composer's menu rule squashed it to 10 px and
 *  its items spilled under the page) and isn't clipped by the inspector. */
function menuHolds(g: Geom) {
  assert.ok(g.menu, "the menu is open");
  for (const i of g.menu!.items) assert.ok(inside(i.rect, g.menu!.rect), `${i.text} is inside the menu`);
  assert.ok(!/rgba\(0, 0, 0, 0\)|transparent/.test(g.menu!.bg), "the menu has a fill");
  assert.ok(inside(g.menu!.rect, g.inspector), "the menu isn't clipped by the window");
}

/** The toolbar is one row: every control inside it, none on another, none in system chrome. */
function oneRow(g: Geom) {
  const where = `${g.state} at ${g.w}`;
  assert.ok(g.bar, `${where}: there's a toolbar`);
  const bar = g.bar!;
  assert.ok(inside(bar, g.inspector), `${where}: the toolbar is inside the inspector`);
  assert.ok(g.controls.length >= 5, `${where}: back, forward, reload, the address and tools are there`);
  for (const c of g.controls) {
    assert.ok(inside(c.rect, bar), `${where}: ${c.label} (${JSON.stringify(c.rect)}) is inside the row ${JSON.stringify(bar)}`);
    assert.ok(!(c.tag === "button" && WHITE.test(c.bg)), `${where}: ${c.label} isn't a bare system button (${c.bg})`);
  }
  assert.equal(Math.round(bar.h), 38, `${where}: the toolbar is one 38 px row (the terminal header's height)`);
  const top = g.controls.filter((c) => !c.inField && c.tag !== "input");
  for (let i = 0; i < top.length; i++) for (let j = i + 1; j < top.length; j++) {
    assert.ok(!overlap(top[i].rect, top[j].rect), `${where}: ${top[i].label} and ${top[j].label} don't overlap`);
  }
  const field = g.controls.find((c) => c.tag === "label");
  assert.ok(field && field.rect.w >= 150, `${where}: the address keeps the room (${field?.rect.w})`);
}

for (const w of [360, 420, 560]) {
  for (const state of ["empty", "loaded", "loading", "failed", "phone", "tablet", "desktop", "mention"]) {
    test(`Preview ${state} at ${w}: one toolbar row, nothing outside it`, { skip, timeout: 60_000 }, async () => oneRow(await geom(state, w)));
  }
}

test("Preview empty: centred in the body like the other tabs, the icon clear of the words", { skip, timeout: 60_000 }, async () => {
  for (const w of [360, 560]) {
    const g = await geom("empty", w);
    assert.ok(g.empty && g.stage, "an empty state in the stage");
    const box = g.empty!.box, stage = g.stage!;
    assert.ok(Math.abs(box.x + box.w / 2 - (stage.x + stage.w / 2)) < 2, `centred across at ${w}`);
    assert.ok(g.empty!.icon, "it has an icon");
    for (const t of g.empty!.text) assert.ok(!overlap(g.empty!.icon!, t.rect), `the icon isn't on "${t.text}"`);
    const words = g.empty!.text.map((t) => t.text).join(" | ");
    assert.match(words, /Nothing to preview yet/);
    assert.match(words, /Run your dev server, then enter its URL or port, or ask Frog to open it\./);
    const ys = g.empty!.text.map((t) => t.rect.y);
    assert.ok(ys.every((y, i) => i === 0 || y > ys[i - 1]), "title above help, stacked");
    const iconMid = g.empty!.icon!.y + g.empty!.icon!.h / 2;
    assert.ok(iconMid > stage.y + stage.h * 0.25 && iconMid < stage.y + stage.h * 0.6, "vertically centred, not stuck to the top");
  }
});

test("Preview unavailable: the web says plainly Preview isn't on the web yet, with no dead toolbar", { skip, timeout: 60_000 }, async () => {
  const g = await geom("unavailable", 360);
  assert.equal(g.bar, null, "no toolbar that can't do anything");
  assert.ok(g.empty, "an empty state");
  assert.match(g.text, /Preview isn’t on the web yet/);
  assert.match(g.text, /Mac app/);
  assert.ok(g.empty!.icon && g.empty!.text.every((t) => !overlap(g.empty!.icon!, t.rect)));
});

test("Preview failed: what failed and a Retry, not a blank body", { skip, timeout: 60_000 }, async () => {
  const g = await geom("failed", 360);
  assert.ok(g.empty, "a failure state over the page");
  const words = g.empty!.text.map((t) => t.text).join(" | ");
  assert.match(words, /Couldn’t load localhost:5173/);
  assert.match(words, /Nothing is listening on port 5173 in the sandbox\./);
  assert.deepEqual(g.empty!.buttons, ["Retry"]);
});

test("Preview loading: a thin progress line right under the row, and reload becomes stop", { skip, timeout: 60_000 }, async () => {
  const g = await geom("loading", 360);
  assert.ok(g.progress && g.bar, "a progress line");
  assert.ok(g.progress!.h <= 2.5, "thin");
  assert.ok(Math.abs(g.progress!.y + g.progress!.h - (g.bar!.y + g.bar!.h)) <= 0.5, "on the row's bottom edge");
  assert.ok(g.controls.some((c) => c.label === "Stop"), "stop instead of reload");
  assert.ok(!g.controls.some((c) => c.label === "Reload"));
});

test("Preview address: host and path, port kept, no scheme", { skip, timeout: 60_000 }, async () => {
  const g = await geom("loaded", 420);
  assert.equal(g.address, "localhost:5173");
});

test("Preview device menu: Fit, Phone, Tablet and Desktop with sizes, inside the inspector", { skip, timeout: 60_000 }, async () => {
  const g = await geom("devices", 420);
  assert.ok(g.menu, "the menu is open");
  assert.deepEqual(g.menu!.items.map((i) => i.text), ["Fit", "Phone390 × 844", "Tablet820 × 1180", "Desktop1280 × 800"]);
  assert.equal(g.menu!.items[0].checked, "true", "Fit is the default");
  menuHolds(g);
});

test("Preview devices: the page frame takes the device's shape inside the body, scaled to fit", { skip, timeout: 60_000 }, async () => {
  for (const [state, ratio] of [["phone", 844 / 390], ["tablet", 1180 / 820], ["desktop", 800 / 1280]] as const) {
    const g = await geom(state, 420);
    assert.ok(g.frame && g.stage && g.iframe, state);
    assert.ok(inside(g.frame!, g.stage!), `${state}: the frame is inside the body`);
    assert.ok(Math.abs(g.frame!.h / g.frame!.w - ratio) < 0.02, `${state}: the frame is the device's shape (${g.frame!.w}×${g.frame!.h})`);
    assert.ok(g.frame!.w < g.stage!.w - 1 || g.frame!.h < g.stage!.h - 1, `${state}: narrower or shorter than the pane`);
  }
  const fit = await geom("loaded", 420);
  assert.ok(fit.frame && fit.stage && Math.abs(fit.frame.w - (fit.stage.w - 20)) <= 1, "Fit fills the body (inside its 10 px gutters)");
});

test("Preview at 360: the tools fold into one More menu that keeps every function", { skip, timeout: 60_000 }, async () => {
  const g = await geom("more", 360);
  assert.ok(g.menu, "the More menu is open");
  const items = g.menu!.items.map((i) => i.text);
  for (const want of ["Pick an element", "Open in browser", "Fit", "Phone", "Tablet", "Desktop"]) {
    assert.ok(items.some((t) => t.startsWith(want)), `More has ${want}: ${items.join(", ")}`);
  }
  menuHolds(g);
  const wide = await geom("loaded", 560);
  assert.ok(!wide.controls.some((c) => c.label === "More"), "at full width the tools are in the row");
  assert.ok(wide.controls.some((c) => c.label === "Device size") && wide.controls.some((c) => c.label === "Pick an element"));
});

test("Preview, light theme: the same one row", { skip, timeout: 60_000 }, async () => oneRow(await geom("loaded", 360, "light")));

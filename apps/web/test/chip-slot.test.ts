// The sidebar's chip slot: at most one chip, directly above Documentation. On the web it holds the
// Mac app chip, with the download chip's gates (not on a phone or tablet; not once a machine is
// this Mac) and a dismiss remembered in localStorage; dismissed, the slot isn't drawn at all.
import { after, test } from "node:test";
import assert from "node:assert/strict";
import { createElement as h } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { ChipSlot, MAC_APP_CHIP, useMacAppChip } from "../src/ui/ChipSlot.tsx";
import { click, closeHarness, find, hasClass, mount, shownText, visible, type Page } from "./app-harness.ts";

after(closeHarness);

const g = globalThis as { addEventListener?: unknown; removeEventListener?: unknown; localStorage?: unknown };
g.addEventListener ??= () => {};
g.removeEventListener ??= () => {};

function Host({ machines, phone }: { machines?: { thisMac?: boolean }[]; phone?: boolean }) {
  const { chip, dismiss } = useMacAppChip(machines, phone);
  return h(ChipSlot, { chip, onDismiss: dismiss });
}
const store = (v: Record<string, string> = {}) => {
  const m = new Map(Object.entries(v));
  g.localStorage = { getItem: (k: string) => m.get(k) ?? null, setItem: (k: string, x: string) => void m.set(k, x), removeItem: (k: string) => void m.delete(k) };
  return m;
};

test("the Mac app chip: the frog mark, Get the Mac app, a true second line, a /download link and a dismiss", () => {
  store();
  const html = renderToStaticMarkup(h(Host, { machines: [], phone: false }));
  assert.match(html, /class="chip-slot"/);
  assert.match(html, /href="\/download"/);
  assert.match(html, /class="mark"/);
  assert.match(html, /Get the Mac app/);
  assert.match(html, new RegExp(MAC_APP_CHIP.detail.replace(/\$/g, "\\$")));
  assert.match(html, /aria-label="Dismiss Get the Mac app"/);
  assert.ok(!/<a[^>]*>[^]*<button[^]*<\/a>/.test(html), "the dismiss is beside the link, not inside it");
});

test("gate 1: no chip on a phone or tablet", () => {
  store();
  assert.equal(renderToStaticMarkup(h(Host, { machines: [], phone: true })), "");
});

test("gate 2: no chip once one of your machines is this Mac", () => {
  store();
  assert.equal(renderToStaticMarkup(h(Host, { machines: [{ thisMac: false }, { thisMac: true }], phone: false })), "");
  assert.notEqual(renderToStaticMarkup(h(Host, { machines: [{ thisMac: false }], phone: false })), "");
});

test("a dismissed chip stays dismissed and the slot draws nothing", () => {
  store({ "frog.chip.mac-app": "dismissed" });
  assert.equal(renderToStaticMarkup(h(Host, { machines: [], phone: false })), "");
});

test("no chip, no slot: nothing at all, not an empty box", () => {
  assert.equal(renderToStaticMarkup(h(ChipSlot, { chip: null, onDismiss: () => {} })), "");
});

const ACCOUNT = { plan: "free", name: "Ada Lovelace", handle: null, email: "ada@example.com", credit_cents: 1278, resets_at: null };
const signedIn = (machines: unknown[] = []) => ({
  storage: { "frog.key": "frog_test" },
  respond: (url: string) => url.endsWith("/v1/me") ? { body: { account: ACCOUNT } }
    : url.endsWith("/v1/sessions") ? { body: { sessions: [] } }
    : url.endsWith("/v1/machines") ? { body: { data: machines } }
    : url.endsWith("/v1/models") ? { body: { data: [] } } : undefined,
});
const sideOf = (p: Page) => find(p, (n) => n.type === "aside")!;

test("signed in, the Mac app pill sits in the sidebar's foot directly above the account", async () => {
  const p = await mount("/", signedIn());
  const order = visible(sideOf(p)).map((n) => ["side-pill", "side-acct-row", "side-legal"].find((c) => hasClass(c)(n))).filter(Boolean);
  assert.deepEqual(order, ["side-pill", "side-acct-row", "side-legal"]);
  assert.ok(shownText(sideOf(p)).includes("$12.78 credit"), "the account row is still there");
  p.unmount();
});

test("signed in with this Mac paired, there's no Mac app pill", async () => {
  const p = await mount("/", signedIn([{ id: "m", name: "studio", thisMac: true, hardware: "M4", online: true, model: null, totalBytes: 1, models: [] }]));
  assert.equal(find(p, hasClass("side-pill")), undefined);
  p.unmount();
});

test("a dismissed Mac app chip keeps the pill away, signed out too", async () => {
  const shown = await mount("/");
  assert.ok(find(shown, hasClass("side-pill")), "shown by default");
  shown.unmount();
  const again = await mount("/", { storage: { "frog.chip.mac-app": "dismissed" } });
  assert.equal(find(again, hasClass("side-pill")), undefined, "still gone after a reload");
  again.unmount();
});

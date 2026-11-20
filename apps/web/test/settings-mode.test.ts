// Settings is a mode of the shell (docs/design/app-shell.md), not an overlay: ⌘,, the Settings
// row, the account row, the palette, every openSettings caller and ?settings= links open it on
// the right section; the sidebar becomes the section list with Back to app; every control the
// overlay had still works; Appearance keeps a theme; Billing redeems coupon codes. These mount the
// whole App (test/app-harness.ts) against the mock gateway's account routes and coupon contract.
import { after, test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createElement as h, useState } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { byText, click, closeHarness, find, hasClass, key, mount, shownText, visible, act, dispatch, type HostNode, type Page } from "./app-harness.ts";
import { redeem } from "./mock/account.mjs";
import TestRenderer from "react-test-renderer";
import { Coupon, creditRowLabel, DRAWN_BY, RENDER, SettingsPage, SettingsSidebar, WEB_SHORTCUTS } from "../src/ui/Settings.tsx";
import { Shell, type ShellMode } from "../src/ui/Docs.tsx";
import { Inspector } from "../src/ui/Inspector.tsx";
import { pinModel, rememberPick, ROWS, SECTIONS, sectionOfQuery, settingsSectionOf, startingModel, webRows, WEB_SECTIONS } from "../src/settings.ts";

after(closeHarness);

type Acct = { account: Record<string, unknown>; history: Record<string, unknown>[]; redeemed: Set<string>; keys: Record<string, unknown>[] };
const fresh = (over: Record<string, unknown> = {}, history?: Record<string, unknown>[]): Acct => ({
  account: { plan: "free", name: "Ada Lovelace", handle: null, image: null, google: null, email: "ada@example.com", credit_cents: 1278, resets_at: null, subscription: null, ...over },
  history: history ?? [{ kind: "topup", at: "2026-11-02T18:00:00Z", amount_micro_usd: 10_000_000, status: "succeeded" }],
  redeemed: new Set(),
  keys: [
    { id: "k_this", name: "frog.toys web, ab12", kind: "device", created: "2026-11-01T00:00:00Z", last_used: null, revoked: false, current: true },
    { id: "k_cli", name: "laptop cli", kind: "key", created: "2026-11-01T00:00:00Z", last_used: null, revoked: false, current: false },
  ],
});
const MACHINES = [{ id: "n1", name: "mew", hardware: "RTX 3090, 24 GB VRAM", online: true, model: "Qwen3-4B", decode: 58.4, totalBytes: 24 * 2 ** 30, freeBytes: 13 * 2 ** 30,
  models: [{ id: "Qwen/Qwen3-4B", name: "Qwen3-4B", hash: "bbbbbbbbbbbb22", loaded: true, quant: "bf16" }] }];
const MODELS = [{ id: "glm-5.3-flash", context_length: 131072, pricing: { prompt: "0.00000004", completion: "0.0000004", input_cache_read: "0.00000001" } }];

/** Signed in, against an in-memory account answering like the mock gateway. */
async function signedIn(path: string, a: Acct = fresh(), globals?: Record<string, unknown>) {
  const p = await mount(path, {
    storage: { "frog.key": "frog_test" },
    globals,
    respond: (url, init) => {
      const u = new URL(url).pathname;
      const body = typeof init.body === "string" ? JSON.parse(init.body) : {};
      if (u === "/v1/me") return { body: { account: a.account } };
      if (u === "/v1/sessions") return { body: { sessions: [] } };
      if (u === "/v1/machines") return { body: { data: MACHINES } };
      if (u === "/v1/models") return { body: { data: MODELS } };
      if (u === "/v1/keys" && init.method === "POST") return { body: { key: "frog_newkey123", id: "k_new" } };
      if (u === "/v1/keys") return { body: { keys: a.keys } };
      if (/^\/v1\/keys\/.+\/revoke$/.test(u)) return { body: { ok: true } };
      if (u === "/v1/billing/history") return { body: { topups: a.history } };
      if (u === "/v1/coupons/redeem") return redeem(a, body.code);
      if (u === "/v1/billing/subscribe" || u === "/v1/billing/topup" || u === "/v1/billing/portal") return { body: { url: "https://checkout.stripe.test/x" } };
      // zest#213: the plan changes in place; /v1/me answers with the new one after.
      if (u === "/v1/billing/plan") { const sub = a.account.subscription as { plan: string; name: string } | null; if (sub) { sub.plan = body.plan; sub.name = body.plan === "max5" ? "Max" : body.plan === "max" ? "Ultra" : "Pro"; } return { body: { plan: body.plan, status: "active" } }; }
      if (u === "/v1/auth/link") return { body: { link: "l_1" } };
      return undefined;
    },
  });
  await settle();
  return p;
}
const settle = () => act(async () => { await new Promise((r) => setTimeout(r, 30)); });
const side = (p: Page) => find(p, (n) => n.type === "aside")!;
const page = (p: Page) => find(p, hasClass("settings-page"));
const sectionShown = (p: Page) => page(p)?.props["aria-label"];
const btn = (p: Page, t: string | RegExp) => find(p, byText("button", t));
const calls = (p: Page, path: string, method = "POST") => p.calls.filter((c) => new URL(c.url, "https://frog.toys").pathname === path && c.method === method);
async function type(n: HostNode | undefined, value: string) {
  if (!n) throw new Error("no field");
  await act(async () => { (n.props.onChange as (e: unknown) => void)({ target: { value, style: {}, scrollHeight: 20 }, currentTarget: { value } }); });
}
async function submit(n: HostNode | undefined) {
  if (!n) throw new Error("no form");
  await act(async () => { (n.props.onSubmit as (e: unknown) => void)({ preventDefault() {} }); });
  await settle();
}

// ---------- getting in ----------

test("⌘, opens Settings mode on Account: the sidebar is Back to app and the sections; no overlay", async () => {
  const p = await signedIn("/");
  await key(",");
  assert.equal(p.path(), "/settings/account");
  assert.equal(sectionShown(p), "Account");
  assert.match(shownText(side(p)), /Back to app esc General Appearance Models Permissions Shortcuts Skills Connections Rules Memory Automations Usage Account Billing/, "thirteen sections");
  // Three runs with a small gap between them, no labels: Skills and Usage start a run.
  assert.deepEqual(visible(side(p)).filter(hasClass("run-start")).map((n) => shownText(n)), ["Skills", "Usage"]);
  assert.equal(find(p, (n) => n.props.role === "dialog"), undefined, "no settings overlay");
  p.unmount();
});

test("the Settings row (gear) under Search opens Settings; the account row opens Account", async () => {
  const p = await signedIn("/");
  const s = shownText(side(p));
  // Documentation is hidden for now (ui/Side.tsx SHOW_DOCS), and Customize is in Settings now.
  assert.match(s, /New session ⌘N Search ⌘K Settings ⌘,/, "the top rows, Settings after Search");
  await click(find(p, (n) => n.type === "button" && hasClass("side-row")(n) && shownText(n).startsWith("Settings")));
  assert.ok(page(p), "Settings mode");
  await click(btn(p, "Billing"));
  assert.equal(p.path(), "/settings/billing");
  await click(btn(p, "Back to app"));
  await click(find(p, (n) => n.type === "button" && n.props.title === "Account and billing"));
  assert.equal(sectionShown(p), "Account");
  p.unmount();
});

test("?settings=billing and ?settings=account open that section, keeping the rest of the query", async () => {
  const b = await signedIn("/?settings=billing&ref=stripe");
  assert.equal(sectionShown(b), "Billing");
  assert.equal(b.path(), "/settings/billing?ref=stripe");
  b.unmount();
  const a = await signedIn("/?settings=account");
  assert.equal(sectionShown(a), "Account");
  assert.equal(a.path(), "/settings/account");
  a.unmount();
});

test("a direct visit to /settings/<section> opens it; signed out it opens the app instead", async () => {
  const p = await signedIn("/settings/models");
  assert.equal(sectionShown(p), "Models");
  p.unmount();
  const out = await mount("/settings/billing");
  assert.equal(page(out), undefined, "no settings without a key");
  assert.equal(out.path(), "/");
  assert.ok(shownText(out.root.root as unknown as HostNode).includes("What should we work on?"));
  out.unmount();
});

test("the palette has Settings and one entry per section", async () => {
  const p = await signedIn("/");
  await key("k");
  const pal = find(p, (n) => n.props.role === "dialog" && n.props["aria-label"] === "Command palette")!;
  const t = shownText(pal);
  for (const s of ["Settings ⌘,", "Account Settings", "Appearance Settings", "Models Settings", "Billing Settings"]) assert.ok(t.includes(s), `${s} in ${t}`);
  await click(find(p, (n) => n.type === "button" && hasClass("pick")(n) && shownText(n) === "Billing Settings"));
  assert.equal(sectionShown(p), "Billing");
  p.unmount();
});

test("every openSettings caller lands on its section: the composer's Billing and Manage, Models' Add credit", async () => {
  const p = await signedIn("/");
  const composer = () => p.root.root.findAll((n) => typeof n.type === "function" && "usage" in n.props && "onManage" in n.props)[0];
  await act(async () => { composer().props.usage.onBilling(); });
  assert.equal(sectionShown(p), "Billing");
  await click(btn(p, "Back to app"));
  await act(async () => { composer().props.onManage(); });
  assert.equal(sectionShown(p), "Models");
  await click(btn(p, "Add credit…"));
  assert.equal(sectionShown(p), "Billing");
  p.unmount();
});

test("the out-of-credit card (the credit wall) opens Have a code? inline, with Billing's own Coupon field", () => {
  // The wall needs a live session's socket, which the harness doesn't run; its wiring is read here
  // and rendered in test/credit-wall.test.ts.
  const src = readFileSync(new URL("../src/ui/CreditWall.tsx", import.meta.url), "utf8");
  assert.match(src, /import \{ Coupon \} from '\.\/Settings'/);
  assert.match(src, /<Coupon apiKey=\{apiKey\} focus=\{1\} onRedeemed=\{onRedeemed\} \/>/);
});

test("Billing opened for a code puts the cursor in the field; a plain visit doesn't", async () => {
  const seen: string[] = [];
  const mock = (el: { props?: Record<string, unknown> }) => ({ focus: () => seen.push(String(el.props?.["aria-label"])) });
  let r!: TestRenderer.ReactTestRenderer;
  await act(async () => { r = TestRenderer.create(h(Coupon, { apiKey: "k" }), { createNodeMock: mock as never }); });
  assert.deepEqual(seen, [], "no request, no focus");
  await act(async () => { r.update(h(Coupon, { apiKey: "k", focus: 1 })); });
  assert.deepEqual(seen, ["Coupon code"], "asked: the field has the cursor");
  await act(async () => { r.update(h(Coupon, { apiKey: "k", focus: 2 })); });
  assert.deepEqual(seen, ["Coupon code", "Coupon code"], "asked again (the card's link a second time): again");
  r.unmount();
  // A later plain visit mounts it again with no request (openSettings resets it): no cursor.
  await act(async () => { r = TestRenderer.create(h(Coupon, { apiKey: "k", focus: 0 }), { createNodeMock: mock as never }); });
  assert.equal(seen.length, 2, "a plain visit after the card's doesn't take the cursor");
  r.unmount();
  // And the App hands the request through: openSettings(..., { coupon: true }) bumps what
  // SettingsPage gets as focusCoupon.
  const src = readFileSync(new URL("../src/App.tsx", import.meta.url), "utf8");
  assert.match(src, /if \(opts\?\.coupon\) setCouponAsk\(\(n\) => n \+ 1\)\n\s*else setCouponAsk\(0\)/);
  assert.match(src, /const backToApp = \(\) => \{ setCouponAsk\(0\);/);
  assert.match(src, /focusCoupon=\{couponAsk\}/);
});

test("returning from Settings keeps the new-session draft, and Escape is Back to app", async () => {
  const p = await signedIn("/");
  await type(find(p, (n) => n.type === "textarea"), "rename the flag");
  await key(",");
  assert.ok(page(p));
  await act(async () => { dispatch("keydown", { key: "Escape" }); });
  assert.equal(page(p), undefined, "Escape left Settings");
  assert.equal(p.path(), "/");
  assert.equal(find(p, (n) => n.type === "textarea")!.props.value, "rename the flag", "the draft is as it was");
  p.unmount();
});

// ---------- every control the overlay had ----------

test("Account: identity, Sign out, GitHub and Google Connect, devices and keys with create and revoke", async () => {
  const p = await signedIn("/settings/account", fresh(), { Notification: { permission: "granted", requestPermission: async () => "granted" } });
  const t = shownText(page(p)!);
  for (const s of ["Ada Lovelace", "ada@example.com", "Sign-ins GitHub Not connected", "Google Not connected", "Devices and keys frog.toys web, ab12", "This browser", "laptop cli"]) assert.ok(t.includes(s), `${s}: ${t}`);
  assert.ok(!t.includes("Notifications"), "Notifications moved to General (board 7)");
  await type(find(p, (n) => n.type === "input" && n.props["aria-label"] === "New API key name"), "ci");
  await submit(find(p, (n) => n.type === "form" && hasClass("set-row")(n)));
  assert.equal(JSON.parse(calls(p, "/v1/keys")[0].body!).name, "ci");
  assert.ok(shownText(page(p)!).includes("frog_newkey123"), "the new key shows once");
  await click(btn(p, "Revoke"));
  assert.equal(calls(p, "/v1/keys/k_cli/revoke").length, 1);
  await click(find(p, (n) => n.type === "button" && shownText(n) === "Connect"));
  await settle();
  assert.equal(calls(p, "/v1/auth/link").length, 1, "Connect links this account");
  assert.match((globalThis.location as unknown as { assigned: string }).assigned, /\/auth\/web\?.*provider=github/);
  await click(btn(p, "Sign out"));
  assert.equal(p.storage.getItem("frog.key"), null, "signed out");
  assert.equal(page(p), undefined, "back to the app");
  p.unmount();
});

test("Models: the machines list and a machine page, and Frog Cloud's credit", async () => {
  const p = await signedIn("/settings/models");
  assert.match(shownText(page(p)!), /Machines mew .*RTX 3090.*Frog Cloud Account .*Credit \$12\.78/);
  await click(find(p, (n) => n.type === "button" && hasClass("set-machine")(n)));
  assert.match(shownText(page(p)!), /^Status Ready Hardware RTX 3090, 24 GB VRAM .*Qwen3 4B .*58 tok\/s/);
  // The header says where you are, and Models in it goes back.
  const crumbs = () => shownText(find(p, (n) => n.type === "nav" && n.props["aria-label"] === "Breadcrumb")!);
  assert.equal(crumbs(), "Settings › Models › mew");
  await click(find(p, (n) => n.type === "button" && n.props.title === "Back to Models"));
  assert.equal(crumbs(), "Settings › Models");
  p.unmount();
});

test("Billing: plans, top-up, credit, history and the per-model prices", async () => {
  const p = await signedIn("/settings/billing");
  const t = shownText(page(p)!);
  for (const s of ["Usage pricing", "Pro", "Max", "Ultra", "Usage credit $12.78 credit", "Add credit", "Credit added", "$ 10.00", "GLM-5.3 Flash", "Per million tokens."]) assert.ok(t.includes(s), `${s}: ${t}`);
  await click(find(p, (n) => n.type === "button" && hasClass("plan-pick")(n)));
  assert.equal(JSON.parse(calls(p, "/v1/billing/subscribe")[0].body!).plan, "pro");
  p.unmount();
  const q = await signedIn("/settings/billing");
  await click(find(q, (n) => n.type === "button" && n.props.role === "radio" && shownText(n) === "$ 25"));
  await click(btn(q, "Add $25"));
  assert.equal(JSON.parse(calls(q, "/v1/billing/topup")[0].body!).amount, 25e6);
  q.unmount();
});

test("Billing with a plan: its windows, the three plans, and a quiet Cancel plan (the portal)", async () => {
  const sub = { plan: "pro", name: "Pro", over: false, windows: [{ kind: "5h", used: 1, limit: 4, resets_at: "2026-11-18T05:00:00Z" }, { kind: "weekly", used: 2, limit: 4, resets_at: "2026-11-22T00:00:00Z" }] };
  const p = await signedIn("/settings/billing", fresh({ subscription: sub }));
  assert.match(shownText(page(p)!), /Pro Included allowance This 5 hours 25 %, .*This week 50 %/);
  assert.match(shownText(page(p)!), /Your plan/);
  // Cancelling is still a person's click away, and still Stripe's portal.
  await click(btn(p, "Cancel plan"));
  await settle();
  assert.equal(calls(p, "/v1/billing/portal").length, 1);
  assert.equal(calls(p, "/v1/billing/plan").length, 0, "cancel never changes the plan");
  p.unmount();
});

test("Billing with a plan: Upgrade to Max changes the plan in place (POST /v1/billing/plan), no Checkout", async () => {
  const sub = { plan: "pro", name: "Pro", over: false, windows: [{ kind: "5h", used: 1, limit: 4, resets_at: "2026-11-18T05:00:00Z" }, { kind: "weekly", used: 2, limit: 4, resets_at: "2026-11-22T00:00:00Z" }] };
  const p = await signedIn("/settings/billing", fresh({ subscription: sub }));
  await click(btn(p, "Upgrade to Max"));
  await settle();
  const change = calls(p, "/v1/billing/plan");
  assert.equal(change.length, 1);
  assert.deepEqual(JSON.parse(change[0].body ?? "{}"), { plan: "max5" });
  assert.equal(calls(p, "/v1/billing/subscribe").length, 0, "never a second subscription");
  assert.equal(calls(p, "/v1/billing/portal").length, 0);
  p.unmount();
});

test("the old overlay is gone", () => {
  const src = readFileSync(new URL("../src/ui/Overlays.tsx", import.meta.url), "utf8");
  assert.ok(!/export function Settings\b/.test(src), "no Settings overlay component");
  assert.ok(!/className="cardx settings"/.test(readFileSync(new URL("../src/App.tsx", import.meta.url), "utf8")));
});

// ---------- Appearance ----------

test("Appearance keeps the theme in this browser and puts it on the page; System clears it", async () => {
  const p = await signedIn("/settings/appearance");
  const root = (globalThis.document as unknown as { documentElement: { dataset: Record<string, string> } }).documentElement;
  await click(find(p, (n) => n.props.role === "radio" && shownText(n) === "Dark"));
  assert.equal(p.storage.getItem("frog.theme"), "dark");
  assert.equal(root.dataset.theme, "dark");
  await click(find(p, (n) => n.props.role === "radio" && shownText(n) === "Light"));
  assert.equal(root.dataset.theme, "light");
  await click(find(p, (n) => n.props.role === "radio" && shownText(n) === "System"));
  assert.equal(p.storage.getItem("frog.theme"), null);
  assert.equal(root.dataset.theme, undefined);
  p.unmount();
});

test("the palette's Toggle dark mode is kept like Appearance's", async () => {
  const p = await signedIn("/");
  await key("k");
  await click(find(p, (n) => n.type === "button" && hasClass("pick")(n) && shownText(n).startsWith("Toggle dark mode")));
  assert.equal(p.storage.getItem("frog.theme"), "dark");
  p.unmount();
});

test("index.html applies the kept theme before first paint", () => {
  const html = readFileSync(new URL("../index.html", import.meta.url), "utf8");
  assert.match(html, /localStorage\.getItem\('frog\.theme'\)[^<]*dataset\.theme = t/);
  assert.ok(html.indexOf("frog.theme") < html.indexOf('src="/src/main.tsx"'), "before the app's script");
});

// ---------- coupon codes ----------

async function redeemIn(p: Page, code: string) {
  await type(find(p, (n) => n.type === "input" && n.props["aria-label"] === "Coupon code"), code);
  await submit(find(p, (n) => n.type === "form" && hasClass("coupon")(n)));
}
const couponSaid = (p: Page) => shownText(find(p, (n) => n.type === "form" && hasClass("coupon")(n))!.children.find((c) => typeof c !== "string" && c.props.role === "status") as HostNode ?? "");

test("a code that works: Added $5.00 of Frog Cloud credit, the sidebar's credit updates, and history shows it", async () => {
  const p = await signedIn("/settings/billing");
  await redeemIn(p, "LAUNCH5");
  const call = calls(p, "/v1/coupons/redeem")[0];
  assert.equal(call.auth, "Bearer frog_test");
  assert.deepEqual(JSON.parse(call.body!), { code: "LAUNCH5" });
  assert.equal(couponSaid(p), "Added $5.00 of Frog Cloud credit");
  assert.ok(shownText(page(p)!).includes("Usage credit $17.78 credit"), "Billing's credit updates");
  await settle();
  assert.match(shownText(page(p)!), /Code LAUNCH5 \$ 5\.00/);
  await click(btn(p, "Back to app"));
  assert.ok(shownText(side(p)).includes("$17.78 credit"), `the sidebar's credit updates: ${shownText(side(p))}`);
  p.unmount();
});

for (const [code, status, msg] of [
  ["NOPE", 404, "That code doesn't exist. Check it and try again."],
  ["USED", 409, "You've already redeemed this code."],
  ["OLD", 410, "This code has expired."],
  ["GONE", 410, "This code has been used up."],
  ["TEAM", 403, "This code isn't for this account."],
  ["SLOW", 429, "Too many tries. Wait a minute and try again."],
] as const) {
  test(`a code the edge refuses (${status}): its message under the field, and what was typed stays`, async () => {
    const p = await signedIn("/settings/billing");
    await redeemIn(p, code);
    assert.equal(couponSaid(p), msg);
    assert.equal(find(p, (n) => n.type === "input" && n.props["aria-label"] === "Coupon code")!.props.value, code);
    assert.ok(shownText(page(p)!).includes("Usage credit $12.78 credit"), "credit unchanged");
    p.unmount();
  });
}

test("credit history renders coupon rows and unknown kinds plainly rather than dropping them", () => {
  assert.equal(creditRowLabel({ kind: "coupon", code: "LAUNCH5", at: "" }), "Code LAUNCH5");
  assert.equal(creditRowLabel({ kind: "topup", at: "" }), "");
  assert.equal(creditRowLabel({ at: "" }), "");
  assert.equal(creditRowLabel({ kind: "referral_bonus", at: "" }), "referral bonus");
});

test("the coupon field takes the cursor when asked to (the out-of-credit card's link)", () => {
  // SSR can't focus; the Coupon's effect runs on mount in the App tests above. Here: the field and
  // its button are in Billing, under Usage credit.
  const html = renderToStaticMarkup(h(SettingsPage, { section: "billing", account: null, apiKey: "k", onOpen: () => {}, onSignOut: () => {} }));
  assert.match(html, /<b>Have a code\?<\/b>/);
  assert.match(html, /aria-label="Coupon code"/);
  assert.match(html, />Redeem</);
});

// ---------- routing helpers ----------

test("settings paths and ?settings= links", () => {
  assert.equal(settingsSectionOf("/settings/billing"), "billing");
  assert.equal(settingsSectionOf("/settings"), "");
  assert.equal(settingsSectionOf("/settings/nope"), "");
  assert.equal(settingsSectionOf("/docs/install"), null);
  assert.equal(sectionOfQuery("?settings=billing"), "billing");
  assert.equal(sectionOfQuery("?settings=account"), "account");
  assert.equal(sectionOfQuery("?settings=whatever"), "account");
  assert.equal(sectionOfQuery("?x=1"), null);
});

// ---------- the shell keeps the thread, the drawer, and history ----------

let mounts = 0;
function Draft() {
  const [draft, setDraft] = useState("");
  useState(() => { mounts++; return 0; });
  return h("textarea", { "aria-label": "Message Frog", value: draft, onChange: (e: { target: { value: string } }) => setDraft(e.target.value) });
}
const thread = { changes: [], panes: {} } as unknown as Parameters<typeof Inspector>[0]["thread"];
const noop = () => {};
const frame = (mode: ShellMode) => h(Shell, {
  mode, className: "win",
  brand: h("div", { className: "brand" }, "Frog"),
  side: { threads: h("nav", null, "the thread list"), docs: null, settings: h(SettingsSidebar, { current: "appearance", onBack: noop, onOpen: noop }) },
  main: { threads: h("main", { className: "main" }, h(Draft)), docs: null, settings: h(SettingsPage, { section: "appearance", account: null, onOpen: noop, onSignOut: noop }) },
  inspector: h(Inspector, { thread, hasPr: false, onClose: noop, onCommit: noop, send: noop }),
});

test("entering and leaving Settings mode keeps the thread mounted, its draft and the right sidebar's tab", () => {
  mounts = 0;
  let r!: TestRenderer.ReactTestRenderer;
  act(() => { r = TestRenderer.create(frame("threads")); });
  const box = () => r.root.findByProps({ "aria-label": "Message Frog" });
  const tab = (name: string) => r.root.findAll((n) => n.props.role === "tab" && n.children.includes(name))[0];
  act(() => { box().props.onChange({ target: { value: "half-typed" } }); });
  act(() => { tab("Terminal").props.onClick(); });
  act(() => { r.update(frame("settings")); });
  assert.equal(r.root.findAll((n) => typeof n.props.className === "string" && n.props.className.includes("settings-page")).length, 1, "the section shows");
  assert.deepEqual(r.root.findAll((n) => n.props.className === "shell-keep").map((n) => n.props.style.display), ["none", "none", "none"], "thread list, thread and right sidebar hidden");
  act(() => { r.update(frame("threads")); });
  assert.equal(box().props.value, "half-typed");
  assert.equal(tab("Terminal").props["aria-selected"], true);
  assert.equal(mounts, 1, "never unmounted, so a running turn keeps running");
  act(() => r.unmount());
});

test("in Settings, picking a section closes the phone drawer", async () => {
  const p = await signedIn("/settings/account");
  await click(find(p, (n) => n.type === "button" && n.props.className === "burger"));
  const win = () => p.root.root.findAll((n) => typeof n.type === "string" && typeof n.props.className === "string" && n.props.className.startsWith("win"))[0].props.className as string;
  assert.match(win(), /\bdrawer\b/);
  await click(btn(p, "Billing"));
  assert.doesNotMatch(win(), /\bdrawer\b/);
  p.unmount();
});

test("signed out at /settings/<x>, or signing out from Settings, replaces the URL, so Back doesn't bounce", async () => {
  const p = await mount("/settings/billing");
  assert.equal(p.path(), "/");
  assert.equal(p.pushes(), 0, "replaced, not pushed");
  p.unmount();
  const q = await signedIn("/settings/account");
  const before = q.pushes();
  await click(btn(q, "Sign out"));
  assert.equal(q.path(), "/");
  assert.equal(q.pushes(), before, "signing out from Settings replaces the settings entry");
  q.unmount();
});

// ---------- one list of rows (design/settings.json) ----------

test("every row the web can do has a renderer, and nothing renders that the list leaves out", () => {
  const web = SECTIONS.flatMap((s) => [...webRows(s.id).rows, ...webRows(s.id, "machine").rows]).map((r) => r.id);
  for (const id of web) assert.ok(RENDER[id] || DRAWN_BY[id], `${id} has no renderer on the web`);
  for (const id of [...Object.keys(RENDER), ...Object.keys(DRAWN_BY)]) assert.ok(web.includes(id), `${id} renders but isn't a web row`);
  // What's left out says why: Mac rows, and rows marked not yet with a reason.
  const left = ROWS.filter((r) => !web.includes(r.id) && r.platform !== "invite");
  for (const r of left) assert.ok(r.platform === "mac" || r.notYet?.web, `${r.id} is missing on the web without a reason`);
});

test("no Mac-only row shows on the web, in any section", async () => {
  const p = await signedIn("/settings/general");
  const mac = ROWS.filter((r) => r.platform === "mac").map((r) => r.label);
  for (const s of WEB_SECTIONS) {
    await click(btn(p, s.label));
    const t = shownText(page(p)!);
    for (const l of mac) assert.ok(!t.includes(l), `${l} showed in ${s.label}`);
  }
  p.unmount();
});

test("General: Notifications, then the Mac's rows under On your Mac", async () => {
  const p = await signedIn("/settings/general", fresh(), { Notification: { permission: "granted", requestPermission: async () => "granted" } });
  const t = shownText(page(p)!);
  assert.match(t, /^Notifications When a session needs you .* On your Mac Open files in your editor .* Let Frog on iPhone connect/);
  assert.ok(find(p, (n) => n.type === "input" && n.props.role === "switch" && n.props["aria-label"] === "Notifications"));
  p.unmount();
});

test("Permissions: New sessions start in is the new composer's mode; Yolo asks first; the sandbox is a fact", async () => {
  const p = await signedIn("/settings/permissions");
  const radio = (t: string) => find(p, (n) => n.props.role === "radio" && shownText(n) === t);
  assert.match(shownText(page(p)!), /New sessions start in A model approves steps .* Sandbox Cloud sessions always run in a sandbox of their own\. Always on On your Mac Work in folders on your computer/);
  await click(radio("Edits"));
  assert.equal(p.storage.getItem("frog.newMode"), "accept-edits");
  assert.match(shownText(page(p)!), /New sessions start in File edits are allowed; commands still ask\./, "the selected mode's line");
  await click(radio("Yolo"));
  assert.equal(p.storage.getItem("frog.newMode"), "accept-edits", "not until it's confirmed");
  await click(btn(p, "Start in Yolo"));
  assert.equal(p.storage.getItem("frog.newMode"), "yolo");
  await click(btn(p, "Back to app"));
  const composer = p.root.root.findAll((n) => typeof n.type === "function" && "onMode" in n.props && "mode" in n.props)[0];
  assert.equal(composer.props.mode, "yolo", "the new session's composer starts there");
  p.unmount();
});

test("Models: New conversations use pins a model for the new composer; the last one picked otherwise", async () => {
  const p = await signedIn("/settings/models");
  const menu = find(p, (n) => n.type === "select" && n.props["aria-label"] === "New conversations use")!;
  assert.equal(menu.props.value, "", "the last model I used");
  await act(async () => { (menu.props.onChange as (e: unknown) => void)({ target: { value: "glm-5.3-flash" } }); });
  assert.equal(p.storage.getItem("frog.defaultModel"), "glm-5.3-flash");
  await click(btn(p, "Back to app"));
  const composer = p.root.root.findAll((n) => typeof n.type === "function" && "onMode" in n.props && "model" in n.props)[0];
  assert.equal(composer.props.model, "glm-5.3-flash");
  p.unmount();
});

test("a pinned model outlasts picks in the composer; unpinned, the last pick is remembered", () => {
  const m = new Map<string, string>();
  const s = { getItem: (k: string) => m.get(k) ?? null, setItem: (k: string, v: string) => void m.set(k, v), removeItem: (k: string) => void m.delete(k) };
  rememberPick("a", s);
  assert.equal(startingModel(s), "a");
  pinModel("b", s);
  rememberPick("c", s);
  assert.equal(startingModel(s), "b", "the next conversation goes back to the pinned one");
  pinModel(null, s);
  assert.equal(startingModel(s), "a");
});

test("Appearance: Compact puts the transcript's compact gaps on the page and keeps them", async () => {
  const p = await signedIn("/settings/appearance");
  const root = (globalThis.document as unknown as { documentElement: { dataset: Record<string, string> } }).documentElement;
  await click(find(p, (n) => n.props.role === "radio" && shownText(n) === "Compact"));
  assert.equal(p.storage.getItem("frog.density"), "compact");
  assert.equal(root.dataset.density, "compact");
  await click(find(p, (n) => n.props.role === "radio" && shownText(n) === "Comfortable"));
  assert.equal(p.storage.getItem("frog.density"), null);
  assert.equal(root.dataset.density, undefined);
  assert.match(readFileSync(new URL("../src/tokens.css", import.meta.url), "utf8"), /\[data-density="compact"\]/, "the hook it sets exists");
  p.unmount();
});

test("Shortcuts lists the web's own keys; Usage is the Mac's rows as invitations", async () => {
  const p = await signedIn("/settings/shortcuts");
  const t = shownText(page(p)!);
  for (const [, keys] of WEB_SHORTCUTS) for (const [what] of keys) assert.ok(t.includes(what), what);
  await click(btn(p, "Usage"));
  assert.match(shownText(page(p)!), /^On your Mac Measured energy for this Mac/);
  p.unmount();
});

test("old section names open the section they became", () => {
  assert.equal(settingsSectionOf("/settings/mcp"), "connections");
  assert.equal(settingsSectionOf("/settings/energy"), "usage");
  assert.equal(settingsSectionOf("/settings/lend"), "models");
  assert.equal(sectionOfQuery("?settings=energy"), "usage");
});

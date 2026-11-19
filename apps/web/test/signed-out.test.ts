// A signed-out visitor gets the real shell: the same sidebar as signed in (the web home canvas,
// Final page), the landing in the main column, documentation by URL, and nothing that needs a
// key is called or opened.
// These mount the whole App (test/app-harness.ts), so they fail on a build with the old early
// return: there the page had no sidebar and /docs/<slug> showed the landing.
import { after, test } from "node:test";
import assert from "node:assert/strict";
import { byText, click, closeHarness, find, hasClass, key, mount, shownText, visible, act, type HostNode, type Page } from "./app-harness.ts";

after(closeHarness);

const side = (p: Page) => find(p, (n) => n.type === "aside")!;
const mainCol = (p: Page) => find(p, (n) => n.type === "main")!;
const keyed = (p: Page) => p.calls.filter((c) => c.auth !== null);

test("signed out, the sidebar is the signed-in layout: top rows, starters, then the pill, Sign in and the legal row", async () => {
  const p = await mount("/");
  const s = shownText(side(p));
  for (const t of ["New session", "Search", "Customize", "Settings", "Start with one of these", "Make a tiny pomodoro timer",
    "Frog for Mac", "Sign in", "25¢ free, $1 with GitHub", "Pricing", "Privacy", "Terms"])
    assert.ok(s.includes(t), `sidebar has "${t}": ${s}`);
  assert.ok(!s.includes("Documentation"), `Documentation is hidden for now: ${s}`);
  // In order: the pill, then Sign in, then the legal row last.
  const order = visible(side(p)).map((n) => ["side-starters", "side-pill", "signin-row", "side-legal"].find((c) => hasClass(c)(n))).filter(Boolean);
  assert.deepEqual(order, ["side-starters", "side-pill", "signin-row", "side-legal"]);
  // The main column is still the landing.
  assert.ok(shownText(mainCol(p)).includes("What should we work on?"));
  p.unmount();
});

test("signed out, nothing account-only is called: only the public model list, with no key", async () => {
  const p = await mount("/");
  assert.deepEqual(keyed(p), [], "no call carries a key");
  for (const c of p.calls) assert.match(c.url, /\/v1\/models$/, `only /v1/models is called signed out, not ${c.url}`);
  p.unmount();
});

test("the sidebar's Sign in opens the GitHub / Google choice and takes the composer's draft along", async () => {
  const p = await mount("/");
  const field = find(p, (n) => n.type === "textarea")!;
  await act(async () => { (field.props.onChange as (e: unknown) => void)({ target: { value: "fix the flaky test", style: {}, scrollHeight: 20 }, currentTarget: { value: "fix the flaky test", style: {}, scrollHeight: 20 } }); });
  await click(find(p, (n) => n.type === "button" && n.props["aria-haspopup"] === "menu" && shownText(n).startsWith("Sign in")));
  const menu = find(p, (n) => n.props.role === "menu" && n.props["aria-label"] === "Sign in")!;
  assert.ok(menu, "the provider choice is open");
  assert.match(shownText(menu), /Continue with GitHub.*Continue with Google/);
  await click(find(p, byText("button", "Continue with GitHub")));
  await act(async () => { await new Promise((r) => setTimeout(r, 50)); });
  const assigned = (globalThis.location as unknown as { assigned: string }).assigned;
  assert.match(assigned, /\/auth\/web\?.*provider=github/, assigned);
  const pending = JSON.parse(globalThis.sessionStorage.getItem("frog.signin") ?? "{}");
  assert.equal(pending.after, "fix the flaky test", "the draft goes along and is sent after the round trip");
  p.unmount();
});

test("signed out, a direct visit to /docs/<slug> shows that page in the shell, not the landing", async () => {
  const p = await mount("/docs/frog-cloud");
  const page = find(p, (n) => n.type === "article")!;
  assert.ok(page, "the docs page shows");
  assert.equal(page.props["aria-label"], "Frog Cloud");
  assert.ok(shownText(side(p)).includes("Back to app"));
  assert.ok(!shownText(p.root.root as unknown as HostNode).includes("What should we work on?"), "the landing is not on screen");
  assert.deepEqual(keyed(p), [], "docs pages call nothing that needs a key");
  p.unmount();
});

test("signed out, ⌘K and ⌘, open nothing, the inspector isn't there, and the model menu has no Manage", async () => {
  const p = await mount("/");
  await key("k");
  await key(",");
  assert.equal(find(p, (n) => n.props.role === "dialog"), undefined, "no palette or settings");
  assert.equal(find(p, hasClass("insp")), undefined, "no inspector");
  const composer = (p.root.root.findAll((n) => typeof n.type === "function" && "onSignIn" in n.props))[0];
  assert.ok(composer, "the signed-out composer");
  assert.equal(composer.props.onManage, undefined, "Manage… isn't offered signed out");
  p.unmount();
});

test("signed out, the collapse toggle folds the sidebar and remembers it", async () => {
  const p = await mount("/");
  await click(find(p, (n) => n.type === "button" && n.props["aria-label"] === "Hide sidebar (⌘\\)"));
  const win = p.root.root.findAll((n) => typeof n.type === "string" && typeof n.props.className === "string" && n.props.className.startsWith("win"))[0];
  assert.match(win.props.className, /\bcollapsed\b/);
  assert.equal(p.storage.getItem("frog.sidebarCollapsed"), "1");
  assert.ok(find(p, (n) => n.type === "button" && n.props["aria-label"] === "Show sidebar (⌘\\)"), "the floating toggle brings it back");
  p.unmount();
});

test("the composer's own Sign in pill still keeps the draft for after the round trip", async () => {
  const p = await mount("/");
  const field = find(p, (n) => n.type === "textarea")!;
  await act(async () => { (field.props.onChange as (e: unknown) => void)({ target: { value: "add a dark mode", style: {}, scrollHeight: 20 }, currentTarget: { value: "add a dark mode", style: {}, scrollHeight: 20 } }); });
  await click(find(p, hasClass("cz-signin")));
  await click(find(p, (n) => n.type === "button" && n.props.role === "menuitem" && shownText(n) === "Continue with Google"));
  await act(async () => { await new Promise((r) => setTimeout(r, 50)); });
  assert.match((globalThis.location as unknown as { assigned: string }).assigned, /provider=google/);
  assert.equal(JSON.parse(globalThis.sessionStorage.getItem("frog.signin") ?? "{}").after, "add a dark mode");
  p.unmount();
});

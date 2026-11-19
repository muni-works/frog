// Customize is a mode of the shell beside Documentation and Settings (docs/design/app-shell.md):
// its routes, its sidebar, an explainer on every list page, what a Frog Cloud session really
// reads (said plainly), the Mac's half as invitations, and no figure without an engine report.
// Settings' Connections moved here on the web. These mount the whole App (test/app-harness.ts).
import { after, test } from "node:test";
import assert from "node:assert/strict";
import { byText, click, closeHarness, find, hasClass, key, mount, shownText, act, type Page } from "./app-harness.ts";
import { CUSTOMIZE_SECTIONS, customizeAtOf, customizePath, customizePathIsCanonical, docsSlugFor, EXPLAINERS, weekDays, type CustomizeAt } from "../src/customize.ts";
import { settingsMovedTo, WEB_SECTIONS } from "../src/settings.ts";

after(closeHarness);

const REPOS = { repos: [{ name: "ada/pond", private: true, pushed_at: null }, { name: "ada/site", private: false, pushed_at: null }], install: "https://github.com/apps/frog/installations/new" };

async function signedIn(path: string, repos: unknown = REPOS) {
  const p = await mount(path, {
    storage: { "frog.key": "frog_test" },
    respond: (url) => {
      const u = new URL(url, "https://frog.toys").pathname;
      if (u === "/v1/me") return { body: { account: { plan: "free", name: "Ada", handle: null, image: null, google: null, email: "ada@example.com", credit_cents: 500, resets_at: null, subscription: null } } };
      if (u === "/v1/sessions") return { body: { sessions: [] } };
      if (u === "/v1/repos") return { body: repos };
      if (u === "/v1/machines") return { body: { data: [] } };
      if (u === "/v1/models") return { body: { data: [] } };
      return undefined;
    },
  });
  await act(async () => { await new Promise((r) => setTimeout(r, 30)); });
  return p;
}
const side = (p: Page) => find(p, (n) => n.type === "aside")!;
const page = (p: Page) => find(p, hasClass("customize-page"));
const crumbs = (p: Page) => shownText(find(p, (n) => n.type === "nav" && n.props["aria-label"] === "Breadcrumb" && !!find(p, hasClass("customize-main")))!);

// ---------- routes ----------

test("each page has its own URL, and the URL names the page back", () => {
  const pages: CustomizeAt[] = [
    ...CUSTOMIZE_SECTIONS.map((s) => ({ section: s.id }) as CustomizeAt),
    { section: "skills", page: "skill", name: "release-notes" },
    { section: "skills", page: "add" },
    { section: "connections", page: "add" },
    { section: "connections", page: "review", id: "com.supabase/mcp" },
  ];
  for (const at of pages) assert.deepEqual(customizeAtOf(customizePath(at)), at, customizePath(at));
  assert.equal(customizePath({ section: "connections", page: "review", id: "com.supabase/mcp" }), "/customize/connections/add/com.supabase%2Fmcp");
});

test("bare /customize opens Skills, old names open what they became, and other paths aren't Customize", () => {
  assert.deepEqual(customizeAtOf("/customize"), { section: "skills" });
  assert.deepEqual(customizeAtOf("/customize/"), { section: "skills" });
  assert.deepEqual(customizeAtOf("/customize/instructions"), { section: "rules" });
  assert.deepEqual(customizeAtOf("/customize/mcp"), { section: "connections" });
  assert.deepEqual(customizeAtOf("/customize/nonsense"), { section: "skills" });
  assert.deepEqual(customizeAtOf("/customize/rules/whatever"), { section: "rules" });
  assert.equal(customizeAtOf("/settings/skills"), null);
  assert.equal(customizeAtOf("/s/abc"), null);
  assert.ok(customizePathIsCanonical("/customize/rules"));
  assert.ok(!customizePathIsCanonical("/customize"));
  assert.ok(!customizePathIsCanonical("/customize/instructions"));
});

test("a /customize link opens the mode on that page: Back to app and the five sections; crumbs in the header", async () => {
  const p = await signedIn("/customize/rules");
  assert.match(shownText(side(p)), /Back to app esc Skills Connections Rules Memory Automations/);
  assert.equal(page(p)?.props["aria-label"], "Rules");
  assert.equal(crumbs(p), "Customize › Rules");
  await click(find(p, (n) => n.type === "a" && shownText(n) === "Memory" && String(n.props.className ?? "").includes("srow")));
  assert.equal(page(p)?.props["aria-label"], "Memory");
  assert.equal(p.path(), "/customize/memory");
  p.unmount();
});

test("signed out, a /customize link opens the app instead", async () => {
  const p = await mount("/customize/skills", { respond: () => undefined });
  assert.equal(page(p), undefined);
  p.unmount();
});

test("the palette opens Customize and each section", async () => {
  const p = await signedIn("/");
  await key("k");
  const item = find(p, byText("button", /^Rules\s*Customize/)) ?? find(p, (n) => shownText(n).startsWith("Rules") && shownText(n).includes("Customize") && typeof n.props.onClick === "function");
  assert.ok(item, "a Rules › Customize command");
  await click(item);
  assert.equal(page(p)?.props["aria-label"], "Rules");
  p.unmount();
});

// ---------- every list page ----------

test("every list page opens with its explainer card: the bold sentence, one more, and the docs link", async () => {
  for (const s of CUSTOMIZE_SECTIONS) {
    const p = await signedIn(customizePath({ section: s.id }));
    const card = find(p, hasClass("cust-explain"))!;
    const x = EXPLAINERS[s.id];
    assert.ok(card, s.id);
    assert.equal(shownText(find(p, (n) => n.type === "b" && shownText(n) === x.lead)!), x.lead);
    assert.ok(shownText(card).includes(x.rest), s.id);
    const link = find(p, (n) => n.type === "a" && shownText(n) === x.link);
    if (s.id === "automations") assert.equal(link, undefined, "no docs page for automations yet, so no dead link");
    else assert.match(String(link?.props.href), /^\/docs\/[\w-]+$/, s.id);
    p.unmount();
  }
});

test("the docs link goes to /docs/<section> once that page exists, else the page that covers it", () => {
  assert.equal(docsSlugFor("skills", ["skills", "skills-and-mcp"]), "skills");
  assert.equal(docsSlugFor("skills", ["skills-and-mcp"]), "skills-and-mcp");
  assert.equal(docsSlugFor("rules", ["memory-and-frog-md"]), "memory-and-frog-md");
  assert.equal(docsSlugFor("automations", ["frog-cloud"]), null);
});

// ---------- what's real, what's an invitation, what's hidden ----------

test("Skills says where a cloud session reads skills, lists the repos it can open, and invites to the Mac for home skills", async () => {
  const p = await signedIn("/customize/skills");
  const t = shownText(page(p)!);
  assert.match(t, /In your repos Skills in a repo A cloud session uses the skills in the repo it opens, from \.frog\/skills ?, \.agents\/skills or \.claude\/skills/);
  assert.match(t, /Repos Frog Cloud can open ada\/pond, ada\/site 2 Choose repos/);
  assert.match(t, /On your Mac Skills for every project Kept in your home folder/);
  p.unmount();
});

test("with no repos and no install link, the repo row says so and promises no link", async () => {
  const p = await signedIn("/customize/rules", { repos: [] });
  assert.match(shownText(page(p)!), /Repos Frog Cloud can open None yet\. (?!Choose)/);
  p.unmount();
});

test("Connections, Rules and Memory say what's true of a cloud session; Automations is an empty state", async () => {
  const c = await signedIn("/customize/connections");
  assert.match(shownText(page(c)!), /reads its repo's \.mcp\.json and tries to start the servers it lists\. A sandbox can only read the open web/);
  assert.match(shownText(page(c)!), /On your Mac Connections on your own machine .* Sign in to a server/);
  c.unmount();
  const r = await signedIn("/customize/rules");
  assert.match(shownText(page(r)!), /reads AGENTS\.md ?, FROG\.md or CLAUDE\.md from the root of the repo it opens/);
  r.unmount();
  const m = await signedIn("/customize/memory");
  assert.match(shownText(page(m)!), /No notes kept Each cloud session starts on a fresh machine/);
  assert.match(shownText(page(m)!), /On your Mac Notes Frog keeps/);
  m.unmount();
  const a = await signedIn("/customize/automations");
  assert.match(shownText(page(a)!), /Nothing repeats yet\. When automations arrive, you'll make one by doing the task once in a conversation and saying "keep doing this"/);
  assert.match(shownText(page(a)!), /Today/);
  a.unmount();
});

test("with no engine report, no page shows a figure: no tokens, no use counts, no marks, no spend", async () => {
  for (const s of CUSTOMIZE_SECTIONS) {
    const p = await signedIn(customizePath({ section: s.id }));
    const main = find(p, hasClass("customize-main"))!;
    const t = shownText(main);
    assert.doesNotMatch(t, /\d[\d,]* tokens?|\$\d|\d+ times|\d+ calls|never used|\bused \d/i, s.id);
    for (const c of ["cust-weight", "cust-act", "cust-sq", "cust-sheet", "cust-rail", "cust-tog"]) assert.equal(find(p, hasClass(c)), undefined, `${s.id}: ${c}`);
    p.unmount();
  }
});

test("Add (F9Find) on the web says how to add to a repo, and invites to the Mac for search and review", async () => {
  const p = await signedIn("/customize/skills");
  await click(find(p, byText("button", "Add a skill")));
  assert.equal(p.path(), "/customize/skills/add");
  assert.equal(crumbs(p), "Customize › Skills › Add");
  const t = shownText(page(p)!);
  assert.match(t, /Add a skill to a repo Commit a folder with a SKILL\.md under \.frog\/skills/);
  assert.match(t, /On your Mac Find a skill/);
  p.unmount();
  // A result's review needs a search the web doesn't have: its URL opens Add, and says so.
  const r = await signedIn("/customize/connections/add/com.supabase%2Fmcp");
  assert.equal(crumbs(r), "Customize › Connections › Add");
  assert.equal(r.path(), "/customize/connections/add");
  r.unmount();
});

test("a skill's page with no report opens the Skills list, and the URL says so", async () => {
  const p = await signedIn("/customize/skills/release-notes");
  assert.match(shownText(page(p)!), /Skills in a repo/);
  assert.equal(crumbs(p), "Customize › Skills");
  assert.equal(p.path(), "/customize/skills");
  p.unmount();
});

test("the week grid's head runs the last six days, then Today", () => {
  assert.deepEqual(weekDays(new Date("2026-11-18T12:00:00")), ["Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Today"]);
});

// ---------- Connections moved out of Settings ----------

test("Settings on the web no longer lists Connections; its old links open Customize › Connections", async () => {
  assert.ok(!WEB_SECTIONS.some((s) => s.id === "connections"));
  assert.equal(settingsMovedTo("/settings/connections"), "connections");
  assert.equal(settingsMovedTo("/settings/mcp"), "connections");
  assert.equal(settingsMovedTo("/", "?settings=mcp"), "connections");
  assert.equal(settingsMovedTo("/settings/billing"), null);
  const p = await signedIn("/settings/mcp");
  assert.equal(page(p)?.props["aria-label"], "Connections");
  assert.equal(p.path(), "/customize/connections");
  p.unmount();
});

test("the app sidebar's Customize row opens Customize on Skills", async () => {
  const p = await signedIn("/");
  await click(find(p, (n) => n.type === "button" && shownText(n) === "Customize"));
  assert.equal(page(p)?.props["aria-label"], "Skills");
  assert.equal(p.path(), "/customize/skills");
  p.unmount();
});

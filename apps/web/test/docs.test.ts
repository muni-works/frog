// Documentation mode (docs/design/app-shell.md): the pages in docs/app through the shared
// manifest and platform blocks, the /docs/<slug> route, and the shell keeping the thread you
// were in (its draft, its running turn, the right sidebar's tab) while the docs are open.
import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";
import { createElement as h, useState } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import TestRenderer, { act } from "react-test-renderer";
import { docsSlugOf, forPlatform, neighbors, pages, search, withoutTitle, type Manifest } from "../src/docs/docs.ts";
import { DocsPage, DocsSidebar, Shell, type ShellMode } from "../src/ui/Docs.tsx";
import { Inspector } from "../src/ui/Inspector.tsx";

(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

const ROOT = new URL("../../../docs/app/", import.meta.url);
const manifest = JSON.parse(readFileSync(new URL("manifest.json", ROOT), "utf8")) as Manifest;
const read = (file: string) => (existsSync(new URL(file, ROOT)) ? readFileSync(new URL(file, ROOT), "utf8") : undefined);
const WEB = pages(manifest, read, "web");
const noop = () => {};
const text = (html: string) => html.replace(/<[^>]+>/g, " ").replace(/\s+/g, " ").trim();

// ---------- platform blocks ----------

const PAGE = [
  "# Install",
  "",
  "Everywhere.",
  "",
  "<!-- only: mac -->",
  "Mac only: it updates itself.",
  "<!-- end -->",
  "",
  "<!-- only: web -->",
  "Web only: nothing to install.",
  "<!-- end -->",
  "",
  "<!-- only: mac, terminal -->",
  "Mac or terminal.",
  "<!-- end -->",
  "",
  "After.",
].join("\n");

test("a block for mac isn't shown on the web; web blocks and unmarked text are, without markers", () => {
  const web = forPlatform(PAGE, "web");
  assert.ok(!web.includes("Mac only"), "the mac block is dropped");
  assert.ok(!web.includes("Mac or terminal"), "a mac, terminal block is dropped too");
  assert.ok(web.includes("Web only: nothing to install."));
  assert.ok(web.includes("Everywhere.") && web.includes("After."));
  assert.ok(!web.includes("<!--"), "no marker survives");
  assert.ok(!/\n{3,}/.test(web), "a dropped block leaves one blank line, not a gap");
});

test("the same page for the mac and the terminal keeps theirs and drops the web's", () => {
  const mac = forPlatform(PAGE, "mac");
  assert.ok(mac.includes("Mac only") && mac.includes("Mac or terminal") && !mac.includes("Web only"));
  const term = forPlatform(PAGE, "terminal");
  assert.ok(!term.includes("Mac only") && term.includes("Mac or terminal") && !term.includes("Web only"));
});

test("the rendered page shows no mac block", () => {
  const all = pages({ version: 1, sections: [{ title: "Start", pages: [{ slug: "install", title: "Install", file: "x.md" }] }] }, () => PAGE, "web");
  const html = renderToStaticMarkup(h(DocsPage, { pages: all, slug: "install", onOpen: noop }));
  assert.ok(!html.includes("Mac only") && !html.includes("Mac or terminal"));
  assert.ok(html.includes("Web only: nothing to install."));
});

test("the page's own # Title gives way to the manifest's title above it", () => {
  assert.equal(withoutTitle("# Install\n\nBody."), "Body.");
  assert.equal(withoutTitle("Body.\n\n# Later"), "Body.\n\n# Later");
  const html = renderToStaticMarkup(h(DocsPage, { pages: WEB, slug: WEB[0].slug, onOpen: noop }));
  assert.equal((html.match(new RegExp(`>${WEB[0].title}</h`, "g")) ?? []).length, 1, "the title is drawn once");
  assert.match(html, new RegExp(`<div class="docs-sec">${WEB[0].section}</div><h1 class="docs-title">${WEB[0].title}</h1>`));
});

// ---------- the pages in docs/app ----------

test("the manifest's files all exist under docs/app, with unique slugs and balanced markers", () => {
  assert.equal(manifest.version, 1);
  const slugs = manifest.sections.flatMap((s) => s.pages.map((p) => p.slug));
  assert.equal(new Set(slugs).size, slugs.length, "slugs are unique across sections");
  for (const s of manifest.sections) for (const p of s.pages) {
    assert.match(p.slug, /^[a-z0-9-]+$/, p.slug);
    assert.ok(!p.file.includes(".."), `${p.file} stays inside docs/app`);
    const src = read(p.file);
    assert.ok(src, `${p.file} exists`);
    const opens = (src!.match(/^\s*<!--\s*only:.*-->\s*$/gm) ?? []).length;
    const ends = (src!.match(/^\s*<!--\s*end\s*-->\s*$/gm) ?? []).length;
    assert.equal(opens, ends, `${p.file}: every only: block has its end`);
    assert.match(src!, /^# /, `${p.file} starts with its title`);
  }
});

test("every markdown file in docs/app is in the manifest", () => {
  const listed = new Set(manifest.sections.flatMap((s) => s.pages.map((p) => p.file)));
  const walk = (dir: string, at = ""): string[] => readdirSync(dir).flatMap((n) =>
    statSync(join(dir, n)).isDirectory() ? walk(join(dir, n), `${at}${n}/`) : n.endsWith(".md") ? [`${at}${n}`] : []);
  for (const f of walk(ROOT.pathname)) assert.ok(listed.has(f), `${f} is listed`);
});

test("previous and next run across sections; search filters titles and headings", () => {
  const three: Manifest = { version: 1, sections: [
    { title: "Start", pages: [{ slug: "install", title: "Install", file: "a" }, { slug: "first", title: "Your first session", file: "b" }] },
    { title: "Use", pages: [{ slug: "web", title: "Web search and fetch", file: "c" }] },
  ] };
  const all = pages(three, (f) => (f === "c" ? "# Web\n\n## Reading pages\n\nText." : "# X\n\nText."), "web");
  assert.equal(neighbors(all, "install").prev, undefined);
  assert.equal(neighbors(all, "first").next?.slug, "web", "next crosses into the next section");
  assert.equal(neighbors(all, "web").next, undefined);
  const html = renderToStaticMarkup(h(DocsPage, { pages: all, slug: "first", onOpen: noop }));
  assert.match(html, /<a class="docs-step" href="\/docs\/install">.*Previous.*Install<\/span><\/a>/);
  assert.match(html, /<a class="docs-step next" href="\/docs\/web">.*Next.*Web search and fetch<\/span><\/a>/);
  assert.deepEqual(search(all, "INSTALL").map((p) => p.slug), ["install"]);
  assert.deepEqual(search(all, "reading").map((p) => p.slug), ["web"], "a heading matches");
  assert.equal(search(all, "zzzz-nothing").length, 0);
  assert.equal(search(all, "  ").length, all.length);
});

test("the sidebar: Back to app, Search docs, sections with their pages, the version at the bottom", () => {
  const html = renderToStaticMarkup(h(DocsSidebar, { pages: WEB, current: "install", version: "0.6.0", onBack: noop, onOpen: noop }));
  const t = text(html);
  assert.ok(t.startsWith("Back to app esc Search docs"), "Back to app with its esc hint, then the Search docs row");
  assert.match(html, /<button type="button" class="row big"><svg[^>]*><path d="M11 4[^"]*"><\/path><\/svg><span[^>]*>Search docs<\/span><\/button>/, "search is a row with the magnifier until clicked");
  assert.ok(!html.includes("<input"), "no field until it's clicked");
  const heads = [...html.matchAll(/<div class="docs-h">([^<]*)<\/div>/g)].map((m) => m[1].replace(/&#x27;/g, "'"));
  assert.deepEqual(heads, manifest.sections.map((s) => s.title), "one label per section, in manifest order");
  assert.match(html, /<a class="srow on" href="\/docs\/install"><span class="stitle" aria-current="page">Install<\/span><\/a>/);
  assert.ok(t.endsWith("Frog 0.6.0"));
});

// ---------- routes ----------

test("a /docs/<slug> URL opens that page", () => {
  assert.equal(docsSlugOf("/docs/web-search-and-fetch"), "web-search-and-fetch");
  assert.equal(docsSlugOf("/docs/install/"), "install");
  assert.equal(docsSlugOf("/docs"), "");
  assert.equal(docsSlugOf("/s/s_123"), null);
  assert.equal(docsSlugOf("/"), null);
  assert.equal(docsSlugOf("/docsx"), null);
  const slug = docsSlugOf("/docs/web-search-and-fetch")!;
  const html = renderToStaticMarkup(h(DocsPage, { pages: WEB, slug, onOpen: noop }));
  assert.match(html, /<h1 class="docs-title">Web search and fetch<\/h1>/);
  const unknown = renderToStaticMarkup(h(DocsPage, { pages: WEB, slug: "no-such-page", onOpen: noop }));
  assert.match(unknown, /Page not found/);
});

// ---------- the shell keeps the thread ----------

/** A stand-in for the composer: the draft lives in its own state, as the real one's does. */
let mounts = 0;
function Draft() {
  const [draft, setDraft] = useState("");
  useState(() => { mounts++; return 0; });
  return h("textarea", { "aria-label": "Message Frog", value: draft, onChange: (e: { target: { value: string } }) => setDraft(e.target.value) });
}
const thread = { changes: [], panes: {} } as unknown as Parameters<typeof Inspector>[0]["thread"];
const frame = (mode: ShellMode) => h(Shell, {
  mode, className: "win",
  brand: h("div", { className: "brand" }, "Frog"),
  side: { threads: h("nav", null, "the thread list"), docs: h(DocsSidebar, { pages: WEB, current: "install", version: "0.6.0", onBack: noop, onOpen: noop }) },
  main: { threads: h("main", { className: "main" }, h(Draft)), docs: h(DocsPage, { pages: WEB, slug: "install", onOpen: noop }) },
  inspector: h(Inspector, { thread, hasPr: false, onClose: noop, onCommit: noop, send: noop }),
});

test("entering and leaving Documentation mode keeps the thread, its draft and the right sidebar's tab", () => {
  mounts = 0;
  let r!: TestRenderer.ReactTestRenderer;
  act(() => { r = TestRenderer.create(frame("threads")); });
  const box = () => r.root.findByProps({ "aria-label": "Message Frog" });
  const tab = (name: string) => r.root.findAll((n) => n.props.role === "tab" && n.children.includes(name))[0];
  act(() => { box().props.onChange({ target: { value: "half-typed" } }); });
  act(() => { tab("Terminal").props.onClick(); });

  act(() => { r.update(frame("docs")); });
  // In Documentation mode the page shows and the thread is hidden, not gone.
  assert.ok(r.root.findAll((n) => n.props.className === "docs-title").length === 1, "the page shows");
  const hidden = r.root.findAll((n) => n.props.className === "shell-keep").map((n) => n.props.style.display);
  assert.deepEqual(hidden, ["none", "none", "none"], "thread list, thread and right sidebar are hidden");
  assert.equal(box().props.value, "half-typed", "the draft is still there underneath");

  act(() => { r.update(frame("threads")); });
  assert.equal(box().props.value, "half-typed", "the draft is as it was");
  assert.equal(tab("Terminal").props["aria-selected"], true, "the right sidebar is still on Terminal");
  assert.equal(mounts, 1, "the thread was never unmounted, so a running turn keeps running");
  assert.equal(r.root.findAll((n) => n.props.className === "docs-title").length, 0, "the page is gone");
  act(() => r.unmount());
});

test("in Documentation mode the right sidebar is hidden", () => {
  const html = renderToStaticMarkup(frame("docs"));
  assert.match(html, /<div class="shell-keep" style="display:none"><section class="insp/);
  const on = renderToStaticMarkup(frame("threads"));
  assert.match(on, /<div class="shell-keep" style="display:contents"><section class="insp/);
  assert.ok(!on.includes("docs-side"));
});

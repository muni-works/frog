// The inspector's unified layout (2026-11-15, one design with the Mac's PaneArea): icon-and-label
// tabs, the Changes header and file rows, the bottom actions, and one empty state for all tabs.
import { test } from "node:test";
import assert from "node:assert/strict";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { Inspector } from "../src/ui/Inspector.tsx";
import type { FileDiff } from "../src/cloud/protocol.ts";

const noop = () => {};
type Props = Parameters<typeof Inspector>[0];
const diff = (path: string, added: number, removed: number, created = false) =>
  ({ path, created, added, removed, hunks: [] }) as unknown as FileDiff;
const render = (changes: FileDiff[], extra: Partial<Props> = {}) =>
  renderToStaticMarkup(createElement(Inspector, {
    thread: { changes, panes: {} } as unknown as Props["thread"],
    hasPr: false, onClose: noop, onCommit: noop, onPr: noop, send: noop, ...extra,
  }));
const text = (html: string) => html.replace(/<[^>]+>/g, " ").replace(/\s+/g, " ").trim();

test("the tab strip is always Changes, Terminal, Preview, each an icon and a label, then close", () => {
  for (const pane of ["changes", "terminal", "preview"] as const) {
    const html = render([], { pane });
    const tabs = [...html.matchAll(/<button[^>]*role="tab"[^>]*aria-selected="(true|false)"[^>]*>(<svg.*?<\/svg>)([^<]+)<\/button>/g)];
    assert.deepEqual(tabs.map((t) => t[3]), ["Changes", "Terminal", "Preview"]);
    assert.deepEqual(tabs.map((t) => t[1] === "true"), ["changes", "terminal", "preview"].map((p) => p === pane), `only ${pane} is selected`);
    assert.ok(!html.includes('class="seg"'), "the old text-only segmented control is gone");
    assert.match(html, /aria-label="Close the inspector"/);
  }
});

test("Changes: 'N files +a −d' and Expand all, no title; rows show icon, name, folder; actions at the bottom", () => {
  const html = render([diff("src/retry.rs", 3, 2), diff("crates/upload/src/client/retry_policy.rs", 4, 1), diff("tests/upload_retry.rs", 12, 0, true)]);
  const head = text(html.match(/<div class="files-head">.*?<\/div>/)![0]);
  assert.equal(head, "3 files +19 −3 Expand all");
  assert.ok(!/<b>|>Changes<\/h/.test(html.match(/<div class="insp-body">.*$/)![0]), "no Changes title or bold count in the body");
  // Name over folder; a new file gets the document-with-plus icon instead of a "new" badge.
  assert.match(html, /<span class="file-name">retry_policy\.rs<\/span><span class="file-dir"><bdi>crates\/upload\/src\/client<\/bdi><\/span>/);
  assert.equal((html.match(/class="file-ic new"/g) ?? []).length, 1);
  assert.equal((html.match(/class="file-ic"/g) ?? []).length, 2);
  assert.ok(!html.includes("file-new"), "no badge");
  assert.match(text(html), /Commit Open PR$/);
  assert.match(text(render([diff("a.ts", 1, 0)], { hasPr: true })), /Commit Push$/);
  assert.ok(!text(render([diff("a.ts", 1, 0)], { onPr: undefined })).includes("Open PR"), "no repo, nowhere to push");
});

test("one file says '1 file'", () => {
  assert.equal(text(render([diff("a.ts", 1, 0)]).match(/<div class="files-head">.*?<\/div>/)![0]), "1 file +1 −0 Expand all");
});

test("every tab's empty state is the same component: icon, title, one line, its own action", () => {
  const empty = (html: string) => html.match(/<div class="insp-empty"><svg[^>]*width="24"[^>]*>.*?<\/svg><b>(.*?)<\/b><span class="wrap">(.*?)<\/span>(.*?)<\/div>/);
  const changes = empty(render([]));
  assert.ok(changes, "Changes uses the empty state");
  assert.equal(changes[1], "No changes yet");
  assert.equal(changes[2], "Files Frog edits show up here.");
  assert.equal(changes[3], "", "no action on Changes");
  assert.ok(!text(render([])).includes("Commit"), "no actions without changes");
  const terminal = empty(render([], { pane: "terminal" }));
  assert.ok(terminal, "Terminal uses the empty state");
  assert.equal(terminal[1], "A shell in the sandbox");
  assert.match(terminal[3], /Open a terminal/);
  const preview = empty(render([], { pane: "preview" }));
  assert.ok(preview, "Preview uses the empty state");
  assert.equal(preview[1], "Preview isn&#x27;t on the web yet");
});

test("the width defaults to 420", () => {
  assert.match(render([]), /style="--insp-w:420px"/);
});

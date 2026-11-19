// The composer view's rules that a test can see (docs/design/composer/spec.md): one status line
// by priority, queued follow-ups as removable chips, the where menu signed in and out, the
// narrow rule, and ⌘. doing one thing.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createElement as h } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import TestRenderer, { act, type ReactTestInstance } from "react-test-renderer";
import { Composer, type ComposerProps } from "../src/ui/Composer.tsx";
import type { Pr } from "../src/composer.ts";

(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;
// The download chip listens for resizes; a bare node has no window to listen on.
const g = globalThis as { addEventListener?: unknown; removeEventListener?: unknown };
g.addEventListener ??= () => {};
g.removeEventListener ??= () => {};

const noop = () => {};
const base: ComposerProps = { onSend: noop, onMode: noop, mode: "auto", model: "glm-5.3-flash", models: [{ id: "glm-5.3-flash", context: 131072, input: 4e-8, output: 4e-7, cached: null }], onModel: noop };
const html = (p: Partial<ComposerProps>) => renderToStaticMarkup(h(Composer, { ...base, ...p }));
const statusLines = (s: string) => s.match(/class="cz-status[^"]*"/g) ?? [];
const pr = (n: number, state: Pr["state"]): Pr => ({ repo: "muni-works/frog", number: n, title: `PR ${n}`, state, checks: { ok: 1, total: 3 } });
const err = { code: "no_credit", message: "Out of credit", actions: ["add_credit"], control: null, detail: null, retryIn: null };

test("status line: an error wins over a question, a notice and git, and only one line shows", () => {
  const s = html({ session: true, repo: "muni-works/frog", branch: "claude/x", adds: 12, dels: 3, tray: { error: err, confirm: "merge", notice: "Swaps after this turn" } });
  assert.equal(statusLines(s).length, 1, s);
  assert.match(s, /role="alert"/);
  assert.match(s, /Out of credit/);
  assert.ok(!s.includes("Swaps after this turn") && !s.includes("Merge #") && !s.includes("+12"), s);
});

test("status line: a question beats a notice and git; a notice beats git", () => {
  const q = html({ session: true, repo: "muni-works/frog", prs: [pr(297, "approved")], tray: { confirm: "merge", notice: "Swaps after this turn" } });
  assert.equal(statusLines(q).length, 1);
  assert.match(q, /Merge #297\?/);
  assert.ok(!q.includes("Swaps after this turn"));
  const n = html({ session: true, repo: "muni-works/frog", adds: 4, tray: { notice: "Swaps after this turn" } });
  assert.equal(statusLines(n).length, 1);
  assert.match(n, /Swaps after this turn/);
  assert.ok(!n.includes("+4"));
});

test("status line: git shows the repo, the PR as a dot and a word, and one action", () => {
  const s = html({ session: true, repo: "muni-works/frog", branch: "claude/x", ahead: 1, prs: [pr(412, "checks")] });
  assert.equal(statusLines(s).length, 1);
  assert.match(s, /#412 checking/);
  assert.match(s, />Push</);
  // Never green on the web: it can't know the session has its own worktree.
  assert.ok(!s.includes("cz-tb--go"));
});

test("status line: a clean session, or one without a repo, has no line (two rows)", () => {
  assert.equal(statusLines(html({ session: true, repo: "muni-works/frog", branch: "main" })).length, 0);
  assert.equal(statusLines(html({ session: true, adds: 3 })).length, 0);
  assert.equal(statusLines(html({})).length, 0);
});

test("no bare queued count: each follow-up is a chip with its words", () => {
  const s = html({ session: true, state: "working", queued: [{ text: "then update the changelog", images: [] }, { text: "bump the version", images: [] }] });
  assert.match(s, /then update the changelog/);
  assert.match(s, /bump the version/);
  assert.ok(!s.includes("cz-qcount") && !/Queued, 2/.test(s), s);
  assert.match(s, /placeholder="Add a follow-up"/);
});

const find = (root: ReactTestInstance, pred: (n: ReactTestInstance) => boolean) => root.find(pred);

test("removing a queued chip removes that follow-up", () => {
  const removed: number[] = [];
  let r!: TestRenderer.ReactTestRenderer;
  act(() => { r = TestRenderer.create(h(Composer, { ...base, session: true, state: "working", queued: [{ text: "one", images: [] }, { text: "two", images: [] }], onUnqueue: (i) => removed.push(i) })); });
  const x = find(r.root, (n) => n.type === "button" && n.props["aria-label"] === "Remove queued message 2");
  act(() => x.props.onClick());
  assert.deepEqual(removed, [1]);
  act(() => r.unmount());
});

test("the where menu, signed in: filter, Scratch sandbox, your repos, more access, Branch", () => {
  const s = html({ pickRepo: true, onRepo: noop, repo: "ecto/pond", repos: ["ecto/pond", "ecto/loon"], install: "https://github.com/apps/frog/installations/new" });
  assert.match(s, /placeholder="Search your repos"/);
  assert.match(s, />Scratch sandbox</);
  assert.match(s, /Your repos/);
  assert.match(s, /ecto\/loon/);
  assert.match(s, /Give Frog access to more repos/);
  assert.match(s, />Branch</);
  // Web: the Frog Cloud part only.
  assert.ok(!s.includes("This Mac") && !s.includes("Choose a folder") && !s.includes("Just chat"), s);
});

// Cam, 2026-11-19: an account with dozens of repos listed every one. The menu shows the best six
// (repoRank.ts) and one line for the rest; typing searches all of them; return picks the first.
test("the where menu trims a long repo list, searches all of it, and return picks", () => {
  const names = Array.from({ length: 40 }, (_, i) => `ecto/r${String(i).padStart(2, "0")}`);
  const pushed = Object.fromEntries(names.map((n, i) => [n, `2026-11-${String(28 - (i % 28)).padStart(2, "0")}T00:00:00Z`]));
  const picked: (string | undefined)[] = [];
  // An open menu listens on the document for clicks outside it.
  const d = globalThis as { document?: unknown };
  const had = d.document;
  d.document ??= { addEventListener: noop, removeEventListener: noop, activeElement: null };
  let r!: TestRenderer.ReactTestRenderer;
  act(() => { r = TestRenderer.create(h(Composer, { ...base, pickRepo: true, repo: "ecto/r39", recent: ["ecto/r30"], repos: names, pushed, onRepo: (x) => picked.push(x) })); });
  const rows = () => r.root.findAll((n) => n.type === "button" && n.props.role === "menuitemradio").map((n) => n.findAll((c) => c.props.className === "cz-mname")[0]?.children.join("") ?? "Scratch");
  // Scratch sandbox, then six: the current repo, the last used, then by last push (r00 and r28 tie on the 28th: name order).
  assert.deepEqual(rows(), ["Scratch", "ecto/r39", "ecto/r30", "ecto/r00", "ecto/r28", "ecto/r01", "ecto/r29"]);
  const note = () => r.root.findAll((n) => n.props.className === "cz-menu-note cz-more").map((n) => n.children.join(""));
  assert.deepEqual(note(), ["34 more repos, type to search"]);
  const input = r.root.find((n) => n.type === "input" && n.props.placeholder === "Search your repos");
  act(() => input.props.onChange({ target: { value: "r17" } }));
  assert.deepEqual(rows(), ["ecto/r17"]);
  assert.deepEqual(note(), []);
  act(() => input.props.onKeyDown({ key: "Enter", preventDefault: () => {} }));
  assert.deepEqual(picked, ["ecto/r17"]);
  act(() => r.unmount());
  d.document = had;
});

// First-run audit: with the GitHub App not installed the menu was "No repo" and "Give Frog
// access to more repos", with no why; and before GitHub was connected it offered the install too.
test("the where menu with no repos yet says why and leads to GitHub", () => {
  const s = html({ pickRepo: true, onRepo: noop, repos: [], install: "https://github.com/apps/frog/installations/new" });
  assert.match(s, /Frog sees only the repos you give it access to\./);
  assert.match(s, />Pick repos on GitHub</);
  assert.ok(!s.includes("more repos"), s);
  const google = html({ pickRepo: true, onRepo: noop, repos: [], onConnectGithub: noop, install: "https://github.com/apps/frog/installations/new" });
  assert.match(google, /Connect GitHub to see your repos/);
  assert.ok(!google.includes("Pick repos on GitHub") && !google.includes("more repos"), google);
});

test("the where menu, signed out: one row that opens sign-in", () => {
  const s = html({ pickRepo: true, onSignIn: noop });
  const menu = s.slice(s.indexOf('aria-label="Where it runs"'));
  assert.match(menu, /Sign in to use Frog Cloud/);
  assert.ok(!menu.includes("Search your repos"), menu);
  // The action is the Sign in pill.
  assert.match(s, /class="cz-signin"[^>]*>Sign in</);
});

test("the where chip names the place with its branch, and leaves once the session starts", () => {
  const s = html({ repo: "ecto/pond", onRepo: noop });
  assert.match(s, /aria-label="Where it runs: ecto\/pond, main"/);
  assert.match(s, /placeholder="What should we work on\?"/);
  const inSession = html({ session: true, repo: "ecto/pond" });
  assert.ok(!inSession.includes("cz-where"), inSession);
  assert.match(inSession, /placeholder="Reply to Frog"/);
});

test("narrow rule: under 420 the model keeps its icon and its name as the label; the where chip truncates in the middle", () => {
  const s = html({ repo: "ecto/slamwich", onRepo: noop });
  assert.match(s, /aria-label="Model: GLM-5\.3 Flash"/);
  assert.match(s, /class="cz-model-name">GLM-5\.3 Flash</);
  assert.match(s, /class="cz-where-head">ecto\/slam<\/span><span class="cz-where-tail">wich</);
  const css = readFileSync(new URL("../src/app.css", import.meta.url), "utf8");
  const narrow = css.match(/@container \(max-width: 419px\) \{([^}]*)\}/);
  assert.ok(narrow, "no narrow container rule");
  assert.match(narrow![1], /\.cz-model-name/);
  assert.match(narrow![1], /\.cz-where-branch/);
  assert.match(css, /\.cz-card \{[^}]*container-type: inline-size/);
  assert.match(css, /\.cz-controls \{[^}]*height: 28px/);
  assert.doesNotMatch(css, /\.cz-controls \{[^}]*flex-wrap: wrap/);
});

test("the card has no shadow and no glass", () => {
  const css = readFileSync(new URL("../src/app.css", import.meta.url), "utf8");
  const card = css.match(/\.cz-card \{([^}]*)\}/)![1];
  assert.match(card, /box-shadow: none/);
  assert.match(card, /border: 1px solid var\(--edge\)/);
  assert.doesNotMatch(css, /\.cz-card[^{]*\{[^}]*backdrop-filter/);
  assert.ok(!html({}).includes("f-glass"));
});

test("yolo shows the bolt and keeps the word", () => {
  const s = html({ mode: "yolo" });
  assert.match(s, /cz-bolt/);
  assert.match(s, /aria-label="When Frog asks: Yolo"/);
});

// ⌘. with the composer focused: one thing. With a permission card on screen the app's handler
// denies it, so the composer must not also cycle the mode.
const periodKey = () => {
  let prevented = false;
  return { e: { key: ".", metaKey: true, ctrlKey: false, shiftKey: false, nativeEvent: { isComposing: false }, preventDefault: () => { prevented = true; } }, prevented: () => prevented };
};

test("⌘. with a permission card on screen leaves the mode alone", () => {
  const modes: string[] = [];
  let r!: TestRenderer.ReactTestRenderer;
  act(() => { r = TestRenderer.create(h(Composer, { ...base, session: true, state: "working", waiting: true, asking: true, onMode: (m) => modes.push(m) })); });
  const k = periodKey();
  act(() => r.root.findByType("textarea").props.onKeyDown(k.e));
  assert.deepEqual(modes, []);
  assert.equal(k.prevented(), false, "the app's window handler answers the card");
  act(() => r.unmount());
});

test("⌘. with no permission card cycles the mode", () => {
  const modes: string[] = [];
  let r!: TestRenderer.ReactTestRenderer;
  act(() => { r = TestRenderer.create(h(Composer, { ...base, session: true, mode: "auto", onMode: (m) => modes.push(m) })); });
  const k = periodKey();
  act(() => r.root.findByType("textarea").props.onKeyDown(k.e));
  assert.deepEqual(modes, ["default"]);
  assert.equal(k.prevented(), true);
  act(() => r.unmount());
});

test("a bound PR shows the git line on a clean session", () => {
  const s = html({ session: true, repo: "muni-works/frog", branch: "claude/x", pr: "#412" });
  assert.equal(statusLines(s).length, 1, s);
  assert.match(s, /#412/);
});

test("out of credit: the status line says so and Return keeps the draft", () => {
  const sent: string[] = [];
  let r!: TestRenderer.ReactTestRenderer;
  act(() => { r = TestRenderer.create(h(Composer, { ...base, session: true, state: "paused", draft: "add a test", onSend: (t) => sent.push(t) })); });
  const ta = r.root.findByType("textarea");
  act(() => ta.props.onKeyDown({ key: "Enter", shiftKey: false, metaKey: false, nativeEvent: { isComposing: false }, preventDefault: noop }));
  assert.deepEqual(sent, []);
  assert.equal(r.root.findByType("textarea").props.value, "add a test");
  assert.ok(r.root.findAll((n) => n.props.className === "cz-st-text" && n.children.includes("Out of credit")).length === 1);
  act(() => r.unmount());
});

test("a refused mic keeps its message when dictation then ends", () => {
  // The browser fires error, then end, on callbacks made renders earlier.
  const made: { onerror: ((e: { error: string }) => void) | null; onend: (() => void) | null }[] = [];
  class FakeRecognition { continuous = false; interimResults = false; onresult = null; onerror: ((e: { error: string }) => void) | null = null; onend: (() => void) | null = null; start() { made.push(this); } stop() {} }
  const g2 = globalThis as { window?: unknown };
  const had = "window" in g2;
  g2.window = { webkitSpeechRecognition: FakeRecognition };
  let r!: TestRenderer.ReactTestRenderer;
  try {
    act(() => { r = TestRenderer.create(h(Composer, { ...base, session: true })); });
    act(() => r.root.find((n) => n.type === "button" && n.props["aria-label"] === "Dictate").props.onClick());
    assert.equal(made.length, 1);
    assert.ok(r.root.find((n) => n.type === "button" && n.props["aria-label"] === "Stop dictation"), "listening face");
    act(() => made[0].onerror!({ error: "not-allowed" }));
    act(() => made[0].onend!());
    const text = JSON.stringify(r.toJSON());
    assert.match(text, /Needs mic access to take dictation/);
    assert.ok(r.root.find((n) => n.type === "button" && n.props["aria-label"] === "Dictate").props.className.includes("cz-marked"));
  } finally {
    act(() => r?.unmount());
    if (!had) delete g2.window;
  }
});

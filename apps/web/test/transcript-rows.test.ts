// Phase 1 of the unified transcript (docs/design/transcript/spec.md, "Lines", "Failure", "Test
// runs"): every finished step is one line — mark, past-tense verb in muted, object in fg (mono for
// paths and commands), result at the right — with its words from the shared verb table
// (docs/design/transcript/verbs.json). Drawn with the real ToolLine and read back as markup.
import { test, beforeEach } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { ToolLine } from "../src/ui/Transcript.tsx";
import { foldRuns, lineOf, lookOf, gutterLayout, INSET_BELOW, rememberOpen, resetOpened, type Step } from "../src/ui/rows.ts";
import type { Entry } from "../src/engine/thread.ts";

const verbs = JSON.parse(readFileSync(new URL("../../../docs/design/transcript/verbs.json", import.meta.url), "utf8"));

const step = (over: Partial<Entry> = {}): Entry => ({
  id: "t1", kind: "tool", text: "", name: "Read", arg: "src/retry.rs", output: "", done: true, outcome: "ok", ...over,
});
const draw = (e: Entry) => renderToStaticMarkup(createElement(ToolLine, { e }));
/** The text of the first element with this class. */
const part = (html: string, cls: string) => {
  const m = new RegExp(`class="[^"]*\\b${cls}\\b[^"]*"[^>]*>([\\s\\S]*?)</`).exec(html);
  return m ? m[1].replace(/<[^>]+>/g, "").replace(/&#x27;/g, "'").replace(/&amp;/g, "&") : null;
};

beforeEach(() => resetOpened());

test("every tool in the verb table draws its past verb and object from the table", () => {
  for (const t of verbs.tools) {
    const arg = t.object === "host" ? "https://docs.rs/rand/latest" : t.object === "none" ? "" : "src/retry.rs";
    const html = draw(step({ name: t.tool, arg, output: "" }));
    assert.equal(part(html, "line-verb"), t.past, `${t.tool}: verb`);
    const obj = part(html, "line-obj");
    if (t.object === "none") assert.equal(obj, null, `${t.tool}: no object`);
    else if (t.object === "host") assert.equal(obj, "docs.rs", `${t.tool}: host`);
    else assert.equal(obj, "src/retry.rs", `${t.tool}: object`);
    const mono = /class="line-obj mono"/.test(html);
    assert.equal(mono, ["command", "path", "pattern", "tool"].includes(t.object), `${t.tool}: mono only for code, paths and commands`);
  }
});

test("a finished command says Ran and the command, the cd prefix dropped", () => {
  const html = draw(step({ name: "Bash", arg: "cd /Users/cam/frog/.claude/worktrees/audit334 && cargo test -q", output: "ok" }));
  assert.equal(part(html, "line-verb"), "Ran");
  assert.equal(part(html, "line-obj"), "cargo test -q");
  assert.equal(part(html, "line-result"), "in audit334");
});

test("an unknown tool never reads 'Used X'", () => {
  const html = draw(step({ name: "mcp__github__list_issues", arg: "{\"repo\":\"frog\"}" }));
  assert.equal(part(html, "line-verb"), verbs.unknown.past);
  assert.equal(part(html, "line-obj"), "github › list_issues");
  assert.doesNotMatch(html, />Used</);
});

test("a gist is the whole line of a successful step, never of a failed one", () => {
  assert.equal(part(draw(step({ name: "Bash", arg: "cargo test", gist: "ran the suite in the worktree" })), "line-gist"), "ran the suite in the worktree");
  const failed = draw(step({ name: "Bash", arg: "cargo test", gist: "ran the suite", outcome: "error" }));
  assert.equal(part(failed, "line-verb"), "Failed");
  assert.equal(part(failed, "line-obj"), "cargo test");
});

test("an edit says +3 −2 with a true minus", () => {
  const diff = { path: "src/retry.rs", created: false, added: 3, removed: 2, hunks: [] };
  const html = draw(step({ name: "Edit", diff }));
  assert.equal(part(html, "line-verb"), "Edited");
  assert.match(html, /class="line-n add">\+3</);
  assert.match(html, /class="line-n del">−2</);
  assert.equal(part(draw(step({ name: "Write", diff: { ...diff, created: true } })), "line-verb"), "Created");
});

test("a denied step: Didn't run … you said no", () => {
  const html = draw(step({ name: "Bash", arg: "rm -rf build", outcome: "denied" }));
  assert.equal(part(html, "line-verb"), "Didn't run");
  assert.equal(part(html, "line-obj"), "rm -rf build");
  assert.equal(part(html, "line-result"), "you said no");
  assert.doesNotMatch(html, /tool-tag/, "no pill");
});

test("a failed step: the verb is Failed in warn, no pill", () => {
  const html = draw(step({ name: "Read", arg: "src/gone.rs", outcome: "error", output: "No such file" }));
  assert.equal(part(html, "line-verb"), "Failed");
  assert.match(html, /data-state="failed"/);
  assert.doesNotMatch(html, /tool-tag|>failed</, "the word and the colour say it: no pill");
});

test("a failed command starts opened, once; a failed read doesn't open itself", () => {
  const e = step({ id: "f1", name: "Bash", arg: "cargo test", outcome: "error", output: "test a ... FAILED" });
  const first = draw(e);
  assert.match(first, /aria-expanded="true"/);
  assert.match(first, /line-open/);
  // Drawn again (StrictMode's second call, the app replaying its cache, a session switch): still open.
  assert.match(draw(e), /line-open/, "a remount doesn't close what opened itself");
  // The person closes it: from then on it stays as they left it, on every mount.
  rememberOpen("f1", false);
  assert.doesNotMatch(draw(e), /line-open/, "a failure opens itself once, not again after you close it");
  assert.doesNotMatch(draw(step({ id: "f2", name: "Read", outcome: "error", output: "gone" })), /line-open/);
  // A step that didn't fail never opens itself, and remembering it does nothing.
  rememberOpen("ok1", true);
  assert.doesNotMatch(draw(step({ id: "ok1", name: "Bash", arg: "ls", output: "a" })), /line-open/);
});

test("a recognised test run reads 10 of 11 and, opened, names what failed above the output", () => {
  const e = step({ id: "tr", name: "Bash", arg: "cargo test -q upload", outcome: "error", output: "…\ntest result: FAILED. 10 passed; 1 failed",
    tests: { runner: "cargo", passed: 10, total: 11, failed: ["upload_retries_on_503"] }, started: 0, ended: 9000 });
  const html = draw(e);
  assert.equal(part(html, "line-result"), "10 of 11 · 9.0s");
  assert.match(html, /class="line-failing"[^>]*>[\s\S]*upload_retries_on_503/);
  assert.ok(html.indexOf("line-failing") < html.indexOf("line-out"), "the names come above the output");
});

test("without the engine's tests field a command is a plain command: no count is guessed", () => {
  const html = draw(step({ name: "Bash", arg: "cargo test", outcome: "ok", output: "test result: ok. 11 passed; 0 failed" }));
  assert.doesNotMatch(html, /of 11/);
});

test("lookOf: aliases and the engine's own casing", () => {
  assert.equal(lookOf("!").past, "Ran");
  assert.equal(lookOf("MultiEdit").past, "Edited");
  assert.equal(lookOf("ToolSearch").past, "Found tools");
  assert.equal(lineOf(step({ name: "Grep", arg: "thread_rng", display: "3 matches in 2 files" })).result, "3 matches in 2 files");
  assert.equal(lineOf(step({ name: "Read", display: "Read 54 lines" })).result, "54 lines", "the verb isn't said twice");
});

// Folds: four or more finished steps in a row, no prose between, fold into one line.
const s = (id: string, over: Partial<Step> = {}): Step => ({ kind: "step", id, failed: false, ...over });
const p = (id: string): Step => ({ kind: "other", id, failed: false });
const shape = (xs: ReturnType<typeof foldRuns>) => xs.map((x) => (x.kind === "fold" ? `fold(${x.steps.length})` : x.id));

test("three steps don't fold; four do", () => {
  assert.deepEqual(shape(foldRuns([s("a"), s("b"), s("c")])), ["a", "b", "c"]);
  assert.deepEqual(shape(foldRuns([s("a"), s("b"), s("c"), s("d")])), ["fold(4)"]);
});

test("prose between steps breaks a run", () => {
  assert.deepEqual(shape(foldRuns([s("a"), s("b"), p("m"), s("c"), s("d")])), ["a", "b", "m", "c", "d"]);
  assert.deepEqual(shape(foldRuns([p("m"), s("a"), s("b"), s("c"), s("d"), s("e"), p("n")])), ["m", "fold(5)", "n"]);
});

test("a failed step never folds, and splits the run", () => {
  assert.deepEqual(shape(foldRuns([s("a"), s("b"), s("x", { failed: true }), s("c"), s("d")])), ["a", "b", "x", "c", "d"]);
  assert.deepEqual(shape(foldRuns([s("a"), s("b"), s("c"), s("d"), s("x", { failed: true })])), ["fold(4)", "x"]);
});

test("the gutter fallback: under 26 the marks come inside and all text indents by 26", () => {
  const wide = gutterLayout(1280);
  assert.equal(wide.mode, "hang");
  assert.equal(wide.indent, 0);
  assert.ok(wide.gutter >= 26);
  const phone = gutterLayout(375);
  assert.equal(phone.mode, "inset");
  assert.ok(phone.gutter < 26);
  assert.equal(phone.indent, 26);
  assert.equal(gutterLayout(INSET_BELOW).mode, "hang");
  assert.equal(gutterLayout(INSET_BELOW - 1).mode, "inset");
});

test("the CSS switches at the same width as gutterLayout", () => {
  const css = readFileSync(new URL("../src/transcript.css", import.meta.url), "utf8");
  assert.match(css, new RegExp(`@container transcript \\(max-width: ${INSET_BELOW - 1}px\\)`));
});

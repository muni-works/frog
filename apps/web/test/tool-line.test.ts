// The row's line, once a gist lands, must not repeat what the gist already says: "Ran
// searched the engine for where gists flush" says "ran" twice. With a gist, the verb goes;
// the raw argument (mono, uncapitalised) is the line until one lands, and a failure keeps
// its verb ("Ran cargo test — failed"). Written to fail without the Transcript.tsx fix.
import { test } from "node:test";
import assert from "node:assert/strict";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { ToolLine } from "../src/ui/Transcript.tsx";
import type { Entry } from "../src/engine/thread.ts";

const e = (over: Partial<Entry>): Entry =>
  ({
    id: "t1", kind: "tool", name: "Bash", arg: "git log --oneline -5",
    done: true, outcome: "ok", output: "abc123 fix the thing", ...over,
  }) as Entry;

function html(entry: Entry): string {
  return renderToStaticMarkup(createElement(ToolLine, { e: entry }));
}

test("a gist row carries no verb beside it", () => {
  const row = html(e({ gist: "git log of the sleep-events worktree" }));
  assert.ok(!/tool-verb/.test(row), `a gist row must not render a verb: ${row}`);
  assert.match(row, /git log of the sleep-events worktree/);
});

test("no gist yet: the raw argument is the line, uncapitalised mono", () => {
  const row = html(e({}));
  assert.match(row, /tool-what/);
  assert.ok(row.includes("git log --oneline -5"), `the raw command must be the line: ${row}`);
  assert.ok(!/Running|Ran\b/.test(row), `no gist, no verb needed when the command is the line: ${row}`);
});

test("a failure keeps the verb", () => {
  const row = html(e({ outcome: "error", output: "error: no upstream" }));
  assert.match(row, /tool-verb/);
  assert.match(row, /failed/);
});

test("a running call keeps its present-tense verb", () => {
  const row = html(e({ done: false, outcome: "ok" }));
  assert.match(row, /tool-verb/);
  assert.match(row, /Running/);
});

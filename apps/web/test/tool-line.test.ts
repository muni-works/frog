// The row's line, once a gist lands, must not repeat what the gist already says: "Ran
// searched the engine for where gists flush" says "ran" twice. With a gist, the gist is the
// line. Without one, the unified transcript (docs/design/transcript/spec.md, "Lines") always
// says the verb: "Ran" in muted, the command in mono. A failure says "Failed", never the gist.
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
  assert.ok(!/line-verb/.test(row), `a gist row must not render a verb: ${row}`);
  assert.match(row, /class="line-gist">git log of the sleep-events worktree</);
});

test("no gist yet: Ran, then the raw command in mono", () => {
  const row = html(e({}));
  assert.match(row, /class="line-verb">Ran</);
  assert.match(row, /class="line-obj mono">git log --oneline -5</);
});

test("a failure says Failed and the command, never the gist", () => {
  const row = html(e({ outcome: "error", output: "error: no upstream", gist: "looked at the log" }));
  assert.match(row, /class="line-verb">Failed</);
  assert.doesNotMatch(row, /looked at the log/);
});

test("a running call keeps its present-tense verb", () => {
  const row = html(e({ done: false, outcome: "ok" }));
  assert.match(row, /class="line-verb">Running</);
});

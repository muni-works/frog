// The parity fuzz cases (docs/design/parity/fuzz/cases.mjs) as regression tests for the web: each
// session log is folded and rendered to HTML, and what broke when they were written stays fixed.
// docs/design/parity/fuzz.sh renders the same cases on Mac and web for eyes.
import { test } from "node:test";
import assert from "node:assert/strict";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { CASES, log } from "../../../docs/design/parity/fuzz/cases.mjs";
import { emptyThread, reduce } from "../src/engine/thread.ts";
import { Transcript } from "../src/ui/Transcript.tsx";
import type { Envelope } from "../src/cloud/protocol.ts";

const noop = () => {};
function render(name: string): string {
  const envs = log(name).split("\n").map((l: string) => JSON.parse(l)).filter((v: { type: string }) => v.type === "event").map((v: { env: Envelope }) => v.env);
  const thread = envs.reduce(reduce, emptyThread);
  return renderToStaticMarkup(createElement(Transcript, { thread, onDecide: noop, onAnswer: noop, onElicit: noop, onRetry: noop }));
}

for (const name of Object.keys(CASES)) {
  test(`fuzz case ${name} renders, with no margin rule on replies`, () => {
    const html = render(name);
    assert.ok(html.length > 100);
    // The served-by rule drew a green bar down every Frog Cloud reply (2026-11-12): it's the
    // footer's job now, as on Mac.
    assert.doesNotMatch(html, /class="say served"|--served/);
  });
}

test("blank messages draw nothing: no empty bubble, Thought row or reply", () => {
  const html = render("empty-messages");
  assert.doesNotMatch(html, /<div class="me">\s*<\/div>/);
  assert.equal((html.match(/class="thought"/g) ?? []).length, 0);
  assert.equal((html.match(/class="say"/g) ?? []).length, 1);
});

test("nested lists step in, and ***both*** and ~~struck~~ leave no stray marks", () => {
  const html = render("markdown-structure");
  assert.match(html, /class="md-nest"/);
  assert.match(html, /--d:2/);
  assert.match(html, /<strong><em>Bold italic<\/em><\/strong>/);
  assert.match(html, /<del>struck<\/del>/);
  assert.doesNotMatch(html, /<li>- /);
});

test("a table keeps its column alignment", () => {
  assert.match(render("code-and-tables"), /text-align:right/);
});

// The caret is drawn by transcript.css at the end of a writing reply's last line of words; one
// that ends in a code box has none (it would add a line inside the box, which finishing removes).
test("a reply streaming inside an unclosed fence draws it as code, still writing", () => {
  const html = render("streaming-fence");
  assert.match(html, /class="md-code"/);
  assert.match(html, /class="say"[^>]*data-writing=""/);
});

test("a connection drop says so, in the Mac's words, not 'system error'", () => {
  const html = render("errors-notices");
  assert.match(html, /Couldn(’|'|&#x27;)t reach the model/);
  assert.doesNotMatch(html, /system error/);
});

test("child sessions read 'Ran an agent', as on Mac", () => {
  assert.match(render("child-sessions"), /Ran an agent/);
});

test("Arabic and Hebrew lines pick their own direction", () => {
  assert.match(render("scripts-and-emoji"), /<p dir="auto">/);
});

test("a short thought alone before the reply folds away, as on Mac", () => {
  // The thought's line is a line-row since the unified transcript (spec phase 1).
  assert.equal((render("scripts-and-emoji").match(/class="line-row thought"/g) ?? []).length, 0);
  assert.equal((render("thoughts").match(/class="line-row thought"/g) ?? []).length, 1);
});

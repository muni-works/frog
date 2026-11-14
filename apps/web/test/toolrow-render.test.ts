// The web's half of Cam's report, checked against the DOM the browser is actually handed:
// a `SendMessage` row buried a one-sentence result behind a click and said its label twice.
//
// `toolrow.test.ts` covers the helpers, which is not enough on its own: the helpers can stay
// correct while `ToolLine` stops calling them (checked — reverting the row to
// `<span className="tool-chev">` plus a `<pre>` body leaves every helper test green). So this
// draws the real row and reads the markup back, as `askcard.test.ts` does for the Ask card.
import { test } from "node:test";
import assert from "node:assert/strict";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { ToolLine } from "../src/ui/Transcript.tsx";
import type { Entry } from "../src/engine/thread.ts";

/** The engine's real `SendMessage` reply: one sentence, then advice. */
const SENT =
  "Sent to ops (20261112-175150-6a2c); delivered (turn started). It reads the message at its next turn boundary; its reply, if any, arrives as a <session-message>."

const draw = (e: Entry) => renderToStaticMarkup(createElement(ToolLine, { e }))

const sent = (over: Partial<Entry> = {}): Entry => ({
  id: "t1",
  kind: "tool",
  text: "",
  name: "SendMessage",
  arg: "ops",
  output: SENT,
  done: true,
  outcome: "ok",
  ...over,
})

test("a SendMessage row says its result with no click at all", () => {
  const html = draw(sent())
  // The meat is on the row's own line, in the row's own text.
  assert.match(html, /tool-said/, "the result must be said on the row: reverted row has no tool-said")
  assert.match(
    html,
    /Sent to ops \(20261112-175150-6a2c\); delivered \(turn started\)/,
    "the first sentence is the row's, uncut: reverted row shows the sentence only after a click",
  )
})

test("a line that already says it all offers no click, and no body", () => {
  // Cut at the first sentence, so there IS more behind it — a chevron is right here.
  assert.match(draw(sent()), /tool-chev/)
  assert.doesNotMatch(draw(sent()), /tool-body/, "nothing is open until the person clicks")
  // The whole result on one line: nothing behind it, so no chevron to click for nothing.
  const whole = draw(sent({ output: "Sent to ops; delivered." }))
  assert.doesNotMatch(whole, /tool-chev/, "a click that reveals nothing is the same wasted click")
  assert.match(whole, /Sent to ops; delivered\./)
})

test("the label is not said twice", () => {
  // The web is single-level (no boxed inner row), so the duplication it can show is the
  // result repeating the row's own words. `VerbLine` strips that on the Mac; here the row's
  // words are the verb and the argument, so the sentence must not open with both again.
  const html = draw(sent({ arg: "ops", output: "Sent to ops; delivered." }))
  const said = /<span class="tool-said">([^<]*)<\/span>/.exec(html)?.[1] ?? ""
  assert.ok(said.length > 0, `the row must say something; html: ${html}`)
  // "Used" is the verb span, and it appears once in the whole row.
  assert.equal((html.match(/>Used</g) ?? []).length, 1, `the verb must appear once; html: ${html}`)
})

test("a payload tool keeps its chevron and its body, and says nothing on the line", () => {
  const bash: Entry = {
    id: "t2",
    kind: "tool",
    text: "",
    name: "Bash",
    arg: "cargo test",
    output: "test result: ok. 666 passed",
    done: true,
    outcome: "ok",
  }
  const html = draw(bash)
  assert.doesNotMatch(html, /tool-said/, "a command's output is a payload, not a sentence")
  assert.match(html, /tool-chev/, "a payload stays behind the chevron")
})

test("an opened short result is text, never a terminal block", () => {
  // Opened by hand (an error opens by itself), the body is its sentence in a plain div.
  const denied = draw(sent({ outcome: "error" }))
  assert.match(denied, /tool-said-body/, "one line in a <pre> reads as a payload it isn't")
  assert.doesNotMatch(denied, /tool-out/)
})

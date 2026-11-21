// A turn that didn't finish still ends on its summary (Cam, 2026-11-21: "if a turn was
// interrupted, it should still show the post-turn response summary footer"). A stopped turn's
// footer says "Stopped" first, in its own muted words; a call stopped mid-stream counts what had
// streamed (the engine's `usage.cut`) and reads "about"; a turn that used nothing draws none,
// just the "Stopped" note; any other ending keeps its banner above the footer. History from a
// resumed session folds the same events, so it draws the same. The Mac's twin is
// FrogTests/StoppedFooterTests.
import { test } from "node:test";
import assert from "node:assert/strict";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { emptyThread, reduce } from "../src/engine/thread.ts";
import { Transcript } from "../src/ui/Transcript.tsx";
import type { Envelope, TurnUsage } from "../src/cloud/protocol.ts";

const noop = () => {};
let seq = 0;
const env = (e: object): Envelope => ({ seq: ++seq, session: "s", created: 1_790_000_000_000 + seq * 1000, ...e } as unknown as Envelope);
const usage = (u: Partial<TurnUsage>): TurnUsage => ({ context_tokens: 900, input_tokens: 0, output_tokens: 0, model_calls: 0, tokens_per_sec: null, timing: { wall_ms: 12_000, prefill_ms: 0, decode_ms: 0, tool_ms: 0 }, model: "cloud/qwen3-coder-next", ...u } as TurnUsage);

function render(events: object[]): string {
  const thread = events.map(env).reduce(reduce, emptyThread);
  return renderToStaticMarkup(createElement(Transcript, { thread, onDecide: noop, onAnswer: noop, onElicit: noop, onRetry: noop }));
}
/** The footer's words, as read (tags out, gaps as spaces). */
const footer = (html: string) => (/<div data-row="footer" class="turn-foot[^"]*"><span class="turn-line">([\s\S]*?)<\/span><span class="hover-acts">/.exec(html)?.[1] ?? "").replace(/<[^>]+>/g, "").replace(/\s+/g, " ").trim();

const start = (input: string) => ({ event: "turn_started", turn: 1, input });
const writing = [
  { event: "item_started", id: "m1", kind: { type: "message" } },
  { event: "item_delta", id: "m1", delta: { type: "text", text: "The retry waits on the store, and" } },
];

test("stopped mid-stream: the footer says Stopped, with what had streamed, about", () => {
  const html = render([start("why?"), ...writing,
    { event: "turn_ended", turn: 1, reason: { type: "cancelled" }, usage: usage({ cut: { output_tokens: 120, input_tokens: 900 } }) }]);
  const words = footer(html);
  assert.match(words, /^Stopped Qwen3 Coder Next 12s about 120 tokens( about \S+)?$/, words);
  assert.doesNotMatch(html, /class="turn-note">Stopped/, "the footer says it; no second Stopped");
  assert.doesNotMatch(words, / · /);
  assert.match(html, /The retry waits on the store, and/, "what it had written stays");
  assert.doesNotMatch(html, /data-writing/, "and no caret once the turn has ended");
});

test("stopped during a tool call, after a finished call: the provider's own figures, no about", () => {
  const html = render([start("run the tests"),
    { event: "item_started", id: "t1", kind: { type: "tool_call", name: "Bash", arg: "cargo test" } },
    { event: "turn_ended", turn: 1, reason: { type: "cancelled" }, usage: usage({ model_calls: 1, input_tokens: 4000, output_tokens: 40 }) }]);
  assert.match(footer(html), /^Stopped Qwen3 Coder Next 12s 40 tokens/);
  assert.doesNotMatch(footer(html), /about/);
  assert.doesNotMatch(html, /tool-spin|Running/, "no step spinning on after the stop, as on the Mac");
});

test("stopped before anything was used: no footer, the Stopped note", () => {
  const html = render([start("hi"), { event: "turn_ended", turn: 1, reason: { type: "cancelled" }, usage: usage({}) }]);
  assert.equal(footer(html), "");
  assert.match(html, /class="turn-note">Stopped</);
});

test("an error or a limit keeps its banner, with the footer under it", () => {
  const html = render([start("go"), ...writing,
    { event: "turn_ended", turn: 1, reason: { type: "error", error: { type: "connection", message: "connection reset by peer" } }, usage: usage({ model_calls: 1, input_tokens: 2000, output_tokens: 300 }) }]);
  assert.match(html, /class="banner warn"/);
  assert.match(footer(html), /^Qwen3 Coder Next 12s 300 tokens/);
  assert.ok(html.indexOf('class="banner warn"') < html.indexOf('data-row="footer"'), "the banner, then the footer");
});

test("a resumed session's old interrupted turn draws the same as a live one", () => {
  const events = [start("why?"), ...writing,
    { event: "turn_ended", turn: 1, reason: { type: "cancelled" }, usage: usage({ model_calls: 1, input_tokens: 900, output_tokens: 80 }) },
    { event: "turn_started", turn: 2, input: "go on" },
    { event: "item_started", id: "m2", kind: { type: "message" } },
    { event: "item_completed", id: "m2", item: { type: "message", text: "Done." } },
    { event: "turn_ended", turn: 2, reason: { type: "complete" }, usage: usage({ model_calls: 1, input_tokens: 900, output_tokens: 3 }) }];
  const html = render(events);
  const all = [...html.matchAll(/data-row="footer"/g)].length;
  assert.equal(all, 2, "both turns have a footer");
  assert.match(footer(html), /^Stopped /, "the first, stopped, says so");
});

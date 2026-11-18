// Phase 2 of the unified transcript (docs/design/transcript/spec.md, "The thinking row and the
// stats line"): the engine's thought line folded from the wire and shown verbatim, the live token
// count, and the row and stats drawn from them.
import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { emptyThread, reduce, type Thread } from "../src/engine/thread.ts";
import type { Envelope, Event } from "../src/cloud/protocol.ts";

// The engine's cases (docs/design/transcript/thoughts.json) land with #420. Until it's on main the
// two tests that replay them skip and say why; once it is, they run.
const CASES = new URL("../../../docs/design/transcript/thoughts.json", import.meta.url);
const NO_CASES = existsSync(CASES) ? false : "thoughts.json isn't here yet: it lands with the engine's #420";
const cases = NO_CASES ? { streams: [] } : JSON.parse(readFileSync(CASES, "utf8"));

let seq = 0;
const env = (e: Event, created = 0) => ({ ...e, seq: ++seq, session: "s1", created }) as Envelope;
const run = (events: Event[], t: Thread = emptyThread) => events.reduce((x, e) => reduce(x, env(e)), t);
const thinking = () => run([
  { event: "turn_started", turn: 1, input: "go" },
  { event: "item_started", id: "r1", kind: { type: "reasoning" } },
]);
const entry = (t: Thread, id = "r1") => t.turns.at(-1)!.entries.find((e) => e.id === id)!;

test("every streams case: the row shows each delta's thought verbatim and keeps it until the next", { skip: NO_CASES }, () => {
  for (const c of cases.streams) {
    let t = thinking();
    let showing: string | undefined;
    for (const ev of c.events) {
      t = reduce(t, env({ event: "item_delta", id: "r1", delta: { type: "reasoning", text: ev.chunk, ...(ev.thought != null ? { thought: ev.thought } : {}) } }));
      if (ev.thought != null) showing = ev.thought;
      assert.equal(entry(t).thought, showing, `${c.name}: after the chunk at ${ev.at} ms`);
    }
    // Live, the outline is every line the row showed; `shown` in the case is the finished item's
    // list, which the engine may trim (a paragraph missing from the final text), and replaces it.
    const live = c.events.filter((e: { thought: string | null }) => e.thought != null).map((e: { thought: string }) => e.thought)
    assert.deepEqual(entry(t).shown ?? [], live, `${c.name}: the lines shown live, in order`);
  }
});

test("a finished think keeps the engine's outline and how long it thought; an old log has neither", { skip: NO_CASES }, () => {
  const c = cases.streams.find((x: { shown: unknown[] }) => x.shown.length > 1);
  const text = c.events.map((e: { chunk: string }) => e.chunk).join("");
  let t = reduce(thinking(), env({ event: "item_completed", id: "r1", item: { type: "reasoning", text, thoughts: c.shown, think_ms: 1840 } }, 9000));
  assert.deepEqual(entry(t).thoughts, c.shown);
  assert.equal(entry(t).thinkMs, 1840);
  for (const s of c.shown) assert.ok(text.slice(s.start, s.end).startsWith(s.text.slice(0, 8)), "ranges are into the text (UTF-16)");
  t = reduce(thinking(), env({ event: "item_completed", id: "r1", item: { type: "reasoning", text: "hm" } }, 9000));
  assert.equal(entry(t).thoughts, undefined);
  assert.equal(entry(t).thinkMs, undefined, "never derived from the item's own times");
});

test("output_tokens reaches the running turn, so_far and all, and a provider figure replaces the count", () => {
  let t = thinking();
  t = reduce(t, env({ event: "output_tokens", turn: 1, output: 120, so_far: true }));
  assert.deepEqual(t.live, { output: 120, soFar: true, slow: false, cached: null });
  // Ephemeral events carry their own seq like deltas do; the replay gate must not drop them.
  t = reduce(t, env({ event: "output_tokens", turn: 1, output: 131 }));
  assert.deepEqual(t.live, { output: 131, soFar: false, slow: false, cached: null });
  // #426: `slow` rides so_far counts; `cached` comes when a call ends and holds through the next.
  t = reduce(t, env({ event: "output_tokens", turn: 1, output: 140, so_far: true, slow: true }));
  assert.equal(t.live?.slow, true);
  t = reduce(t, env({ event: "output_tokens", turn: 1, output: 150, cached: 9000 }));
  t = reduce(t, env({ event: "output_tokens", turn: 1, output: 160, so_far: true }));
  assert.deepEqual(t.live, { output: 160, soFar: true, slow: false, cached: 9000 }, "slow goes with the next count; cached stays");
  assert.ok((t.pulse ?? 0) >= 2, "a count is a sign of life");
  t = run([{ event: "turn_ended", turn: 1, reason: { type: "complete" } }, { event: "output_tokens", turn: 1, output: 999 }], t);
  assert.notEqual(t.live?.output, 999, "an idle session takes no live count");
  t = run([{ event: "turn_started", turn: 2, input: "again" }], t);
  assert.equal(t.live, null, "a new turn starts with no count");
});

test("the first output and the card's time are kept for the stats' hover and the wait", () => {
  let t = reduce(thinking(), env({ event: "item_delta", id: "r1", delta: { type: "reasoning", text: "a" } }, 800));
  t = reduce(t, env({ event: "item_delta", id: "r1", delta: { type: "reasoning", text: "b" } }, 1200));
  assert.equal(t.firstOutputAt, 800);
  t = reduce(t, env({ event: "item_started", id: "t1", kind: { type: "tool_call", name: "Bash", arg: "npm test" } }, 2000));
  t = reduce(t, env({ event: "permission_request", id: "p1", item: "t1", name: "Bash", arg: "npm test", always: "" }, 3000));
  assert.equal(t.askedAt, 3000);
});

// The row and the settled line, drawn with the real components and read back as markup.
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { Transcript } from "../src/ui/Transcript.tsx";
import { LiveContext, LiveTail, Outline, resetThoughts, type LiveInfo } from "../src/ui/LiveRow.tsx";
import { liveRow, thoughtLabel, OUTLINE_MAX, type LiveRow } from "../src/ui/rows.ts";
import type { Entry } from "../src/engine/thread.ts";

const verbs = JSON.parse(readFileSync(new URL("../../../docs/design/transcript/verbs.json", import.meta.url), "utf8"));
const tool = (id: string, name: string, arg: string, done = false): Entry => ({ id, kind: "tool", text: "", name, arg, output: "", done, ...(done ? { outcome: "ok" as const } : {}) });
const noop = () => {};
const page = (t: Thread) => renderToStaticMarkup(createElement(Transcript, { thread: t, onDecide: noop, onAnswer: noop, onElicit: noop }));
const info = (over: Partial<LiveInfo> = {}): LiveInfo => ({ startedAt: Date.now() - 31_000, live: null, pulse: 1, firstOutputAt: null, askedAt: null, activity: null, waitingElsewhere: false, ...over });
const tail = (entries: Entry[], i: LiveInfo, waiting = false) => renderToStaticMarkup(createElement(LiveContext.Provider, { value: i }, createElement(LiveTail, { entries, waiting })));
const text = (html: string, cls: string) => {
  // The stats nest a span per part: read to their div's end.
  const end = cls === "live-stats" ? "div" : "span|div|button";
  const m = new RegExp(`class="[^"]*\\b${cls}\\b[^"]*"[^>]*>([\\s\\S]*?)</(${end})>`).exec(html);
  return m ? m[1].replace(/<[^>]+>/g, "").replace(/&#x27;/g, "'").replace(/&amp;/g, "&") : null;
};

test("the live row's words: a think, one step, several, a card waiting, an answer writing", () => {
  const row = (entries: Entry[], o: Partial<{ waiting: boolean; activity: string | null }> = {}): LiveRow => liveRow(entries, { waiting: false, activity: null, ...o });
  const r: Entry = { id: "r1", kind: "reasoning", text: "x", output: "", done: false, thought: "Check the tests first" };
  assert.deepEqual([row([r]).kind, row([r]).label, row([r]).thought], ["thinking", verbs.live.thinking, "Check the tests first"]);
  const one = row([tool("t1", "Edit", "src/retry.rs")]);
  assert.deepEqual([one.kind, one.label, one.object, one.mono], ["step", "Editing", "src/retry.rs", true], "a step: its live verb and object, from the table");
  assert.equal(row([tool("a", "Read", "a.rs"), tool("b", "Read", "b.rs"), tool("c", "Read", "c.rs")]).label, "Reading 3 files", "parallel steps fold into a count");
  assert.equal(row([tool("a", "Read", "a.rs"), tool("b", "Bash", "ls")]).label, "Running 2 steps");
  assert.equal(row([tool("a", "Bash", "npm test")], { waiting: true }).label, verbs.live.waiting);
  assert.equal(row([{ id: "m", kind: "message", text: "The jitter", output: "", done: false }]).kind, "writing");
  assert.equal(row([tool("a", "Read", "a.rs", true)]).label, verbs.live.thinking, "between steps, a think about to start");
});

test("a running turn draws its live step as the row, not as a line, and a think as the row alone", () => {
  let t = run([
    { event: "turn_started", turn: 1, input: "fix it" },
    { event: "item_started", id: "t1", kind: { type: "tool_call", name: "Edit", arg: "src/retry.rs" } },
  ]);
  let html = page(t);
  assert.equal((html.match(/data-row="line"/g) ?? []).length, 0, "no line for the running step");
  assert.match(html, /data-row="live" data-kind="step"/);
  assert.equal(text(html, "live-label"), "Editing");
  assert.equal(text(html, "line-obj"), "src/retry.rs");
  t = run([
    { event: "item_completed", id: "t1", item: { type: "tool_call", name: "Edit", arg: "src/retry.rs", outcome: "ok", output: "", display: null } },
    { event: "item_started", id: "r2", kind: { type: "reasoning" } },
    { event: "item_delta", id: "r2", delta: { type: "reasoning", text: "Now the tests.\n\n", thought: "Now the tests" } },
  ], t);
  html = page(t);
  assert.equal((html.match(/data-row="line"/g) ?? []).length, 1, "the finished edit is a line; the think is not");
  assert.match(html, /data-row="live" data-kind="thinking"/);
  assert.equal(text(html, "live-label"), "Thinking");
  assert.match(html, /class="live-thought"/, "the thought's place is kept from the first frame");
  assert.doesNotMatch(html, /Now the tests/, "and empty for the first 600 ms");
});

test("a finished think settles to 'Thought for Ns'; an old log reads 'Thought'; a stopped one says when", () => {
  const done: Entry = { id: "r", kind: "reasoning", text: "a\n\nb", output: "", done: true, thinkMs: 31_200 };
  assert.equal(thoughtLabel(done), "Thought for 31s");
  assert.equal(thoughtLabel({ ...done, thinkMs: 400 }), "Thought for 1s", "never 'for 0s'");
  assert.equal(thoughtLabel({ ...done, thinkMs: undefined }), "Thought");
  assert.equal(thoughtLabel({ ...done, done: false, started: 1000, thinkMs: undefined }, 13_000), "Stopped after 12s");
  const t = run([
    { event: "turn_started", turn: 1, input: "go" },
    { event: "item_started", id: "r1", kind: { type: "reasoning" } },
    { event: "item_completed", id: "r1", item: { type: "reasoning", text: "Plan the change.\n\nThen write it.", think_ms: 15_000 } },
    { event: "item_started", id: "m1", kind: { type: "message" } },
    { event: "item_completed", id: "m1", item: { type: "message", text: "Done." } },
    { event: "turn_ended", turn: 1, reason: { type: "complete" } },
  ]);
  const html = page(t);
  assert.match(html, /data-kind="thought"[\s\S]*?class="line-verb">Thought for 15s</);
  assert.doesNotMatch(html, /data-row="live"/, "an ended turn has no live row");
});

test("the stats: time after the first second, tokens never with decimals, tok/s; a card's wait", () => {
  const r: Entry = { id: "r1", kind: "reasoning", text: "", output: "", done: false };
  const html = tail([r], info({ live: { output: 1212, soFar: true, slow: false, cached: 11_900 } }));
  assert.equal(text(html, "live-stats"), "31s · 1,212 tokens");
  assert.match(html, /title="[^"]*Written 1,212 tokens so far/, "the hover says 'so far' while it is a count");
  assert.match(html, /title="[^"]*Read 11,900 tokens from cache/, "cache from the engine's figure");
  assert.equal(text(tail([r], info({ startedAt: Date.now() - 400 })), "live-stats"), null, "no time in the first second");
  const waiting = tail([tool("t1", "Bash", "cargo test")], info({ startedAt: Date.now() - 39_000, askedAt: Date.now() - 6_000 }), true);
  assert.match(waiting, /data-state="waiting"/, "amber only when waiting on a person");
  assert.equal(text(waiting, "live-label"), "Waiting for you");
  assert.equal(text(waiting, "live-stats"), "39s · waited 6s");
  const writing = tail([{ id: "m", kind: "message", text: "The jitter", output: "", done: false }], info({ live: { output: 40, soFar: true, slow: true, cached: null } }));
  assert.doesNotMatch(writing, /data-row="live"/, "an answer writing has no row");
  assert.match(writing, /data-row="stats"/, "only its stats, under the text");
  assert.match(writing, /Slow/, "slow when the engine says so, never computed");
});

test("the outline: a line per shown thought, twelve then 'N more', and the full text a click away", () => {
  resetThoughts();
  const thoughts = Array.from({ length: 15 }, (_, i) => ({ text: `Thought ${i}`, start: i * 12, end: i * 12 + 10, ms: i * 1000 }));
  const e: Entry = { id: "r", kind: "reasoning", text: "x".repeat(200), output: "", done: true, thoughts, thinkMs: 9000 };
  const html = renderToStaticMarkup(createElement(Outline, { e, live: false, onClose: noop }));
  assert.equal((html.match(/class="outline-line/g) ?? []).length, OUTLINE_MAX);
  assert.match(html, />3 more</);
  assert.match(html, />Show all 200 characters</);
  const old = renderToStaticMarkup(createElement(Outline, { e: { ...e, thoughts: undefined }, live: false, onClose: noop }));
  assert.match(old, /class="thought-body"/, "an old log opens straight to its text");
  const live = renderToStaticMarkup(createElement(Outline, { e: { ...e, done: false, thoughts: undefined, shown: ["One", "Two"] }, live: true, onClose: noop }));
  assert.match(live, /class="outline-line now"[^>]*>Two</, "the newest line in fg while live");
});

test("tokens per second over the last seconds, whole numbers", async () => {
  const { rateOf } = await import("../src/ui/rows.ts");
  assert.equal(rateOf([{ at: 0, output: 0 }], 500), null, "not before a second of samples");
  assert.equal(rateOf([{ at: 0, output: 0 }, { at: 1000, output: 29 }, { at: 2000, output: 58 }], 2000), 29);
  assert.equal(rateOf([{ at: 0, output: 0 }, { at: 3000, output: 100 }], 3000), 33, "never a decimal");
});

test("the engine's quiet-call question shows as a card after its think, and the row waits on you", () => {
  const q = { event: "question" as const, id: "q1", item: "r1", question: "The model has sent nothing for 30 s.", options: [{ label: "Keep waiting" }, { label: "Stop the turn" }], multi: false, allow_other: false };
  let t = run([...[{ event: "turn_started", turn: 1, input: "go" }, { event: "item_started", id: "r1", kind: { type: "reasoning" } }] as Event[], q]);
  let html = page(t);
  assert.match(html, /Keep waiting[\s\S]*Stop the turn/, "the card, with the engine's two answers");
  assert.match(html, /data-row="live" data-kind="waiting"/);
  // Nothing streamed yet: an empty item still draws the card (after the turn).
  t = run([{ event: "turn_started", turn: 1, input: "go" }, { ...q, item: "" }]);
  html = page(t);
  assert.match(html, /Stop the turn/);
  // Any token withdraws it.
  t = reduce(t, env({ event: "question_resolved", id: "q1", choices: [] }));
  assert.doesNotMatch(page(t), /Stop the turn/);
});

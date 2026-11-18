// Phase 3 of the unified transcript (docs/design/transcript/spec.md, "The turn line and the turn
// panel"): the web computes a turn's segments from the events it holds, and must agree with the
// engine's reference on every case in docs/design/transcript/timeline.json.
import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { segments, totals } from "../src/engine/timeline.ts";

// The engine's cases land with #420 (#427 adds the 18th). Until they're on main the tests that run
// them skip and say why; once they are, they run.
const CASES = new URL("../../../docs/design/transcript/timeline.json", import.meta.url);
const NO_CASES = existsSync(CASES) ? false : "timeline.json isn't here yet: it lands with the engine's #420";
const cases = NO_CASES ? [] : JSON.parse(readFileSync(CASES, "utf8")).cases;

test("every timeline case: the web's segments equal the engine's", { skip: NO_CASES }, () => {
  assert.ok(cases.length >= 8);
  for (const c of cases) assert.deepEqual(segments(c.events), c.segments, c.name);
});

test("totals count overlapping tools once", () => {
  const t = totals([
    { kind: "tool", start_ms: 0, end_ms: 1000, item: "a" },
    { kind: "tool", start_ms: 500, end_ms: 1500, item: "b" },
    { kind: "thinking", start_ms: 1500, end_ms: 2000, item: "r" },
  ]);
  assert.deepEqual(t, { thinking: 500, tool: 1500, waiting: 0, writing: 0 });
});

// The turn line and the panel, from the segments.
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { TurnLine, axis, pacePath, speedAt, stepName, LONG_WAIT } from "../src/ui/TurnGraph.tsx";

const pace = { bucket_ms: 1000, tokens: [8, 16, 15, 8] };

test("speed at a moment comes from its pace bucket; no pace, no speed", () => {
  assert.equal(speedAt(pace, 1500), 16);
  assert.equal(speedAt(pace, 9000), 0, "past the last bucket: nothing streamed");
  assert.equal(speedAt(null, 1500), null, "a turn before pace was kept draws no curve");
  assert.equal(pacePath(null, 4000, 200, 12), "");
  assert.match(pacePath(pace, 4000, 200, 12), /^M25\.0,/, "one point per bucket, at its middle");
});

test("the turn line draws a strip per segment, grey until hovered, and the curve above", () => {
  const segs = [
    { kind: "thinking" as const, start_ms: 0, end_ms: 1000, item: "r1" },
    { kind: "tool" as const, start_ms: 1000, end_ms: 3000, item: "t1" },
    { kind: "writing" as const, start_ms: 3000, end_ms: 4000, item: "m1" },
  ];
  const html = renderToStaticMarkup(createElement(TurnLine, { segs, total: 4000, pace, entries: [], onOpen: () => {} }));
  assert.match(html, /width="200" height="16"/);
  assert.equal((html.match(/class="seg seg-/g) ?? []).length, 3);
  assert.match(html, /class="pace"/);
  assert.doesNotMatch(html, /data-hover/, "at rest it is grey: no hover state");
  const old = renderToStaticMarkup(createElement(TurnLine, { segs, total: 4000, pace: null, entries: [], onOpen: () => {} }));
  assert.doesNotMatch(old, /class="pace"/, "no pace data: the strip and no curve");
});

test("a wait over 30 s takes 3 s of room on the waterfall's axis, its length written on it", () => {
  const wait = { kind: "waiting" as const, start_ms: 10_000, end_ms: 10_000 + 120_000, item: "t1" };
  const a = axis([wait], 140_000);
  assert.equal(a.broken(wait), true);
  assert.equal(a.broken({ ...wait, end_ms: 10_000 + LONG_WAIT }), false);
  const drawn = a.at(wait.end_ms) - a.at(wait.start_ms);
  assert.ok(drawn > 0 && drawn < 15, `the wait is short on the axis (${drawn.toFixed(1)}%)`);
  assert.equal(Math.round(a.at(140_000)), 100);
});

test("waterfall rows are named like their lines", () => {
  assert.equal(stepName({ id: "t", kind: "tool", text: "", name: "Bash", arg: "cargo test", output: "", done: true, outcome: "ok" }, "tool"), "Ran cargo test");
  assert.equal(stepName(undefined, "waiting"), "Waiting for you");
  assert.equal(stepName({ id: "r", kind: "reasoning", text: "", output: "", done: true }, "thinking"), "Thinking");
});

// What the thread keeps per turn is enough: every case, folded by the reducer, gives the same
// segments from the turn's kept events (so a reload, which rebuilds the thread, draws the same).
import { emptyThread, reduce } from "../src/engine/thread.ts";

test("the thread keeps enough of each turn to draw its timeline after a reload", { skip: NO_CASES }, () => {
  for (const c of cases) {
    const t = c.events.reduce((x: typeof emptyThread, e: never) => reduce(x, e), emptyThread);
    const turn = t.turns.at(-1);
    if (!turn) { assert.deepEqual(c.segments, [], c.name); continue; }
    // A live turn ends at the last event the thread took (deltas aren't kept per turn).
    assert.deepEqual(segments(turn.tl ?? [], t.lastAt), c.segments, c.name);
    assert.ok(JSON.stringify(turn.tl).length < 200 * (turn.tl?.length ?? 0) + 2, `${c.name}: small`);
  }
});

import { paceFromCounts } from "../src/ui/TurnGraph.tsx";
import { TurnFooter } from "../src/ui/TurnFooter.tsx";

test("a live turn's pace: the running count's growth in each second since the turn began", () => {
  const p = paceFromCounts([{ at: 250, output: 10 }, { at: 750, output: 30 }, { at: 1250, output: 45 }, { at: 2900, output: 60 }], 0, 3000);
  assert.deepEqual(p, { bucket_ms: 1000, tokens: [30, 15, 15] });
  assert.equal(paceFromCounts([], 0, 3000), null, "no counts yet: no curve");
});

test("the footer ends in the turn line and has no cost popover any more (the panel replaces it)", () => {
  const ev = (event: string, created: number, rest: object = {}) => ({ seq: 0, session: "s", created, event, ...rest });
  let t = emptyThread;
  for (const [i, e] of [
    ev("turn_started", 0, { turn: 1, input: "go" }),
    ev("item_started", 100, { id: "r1", kind: { type: "reasoning" } }),
    ev("item_completed", 1100, { id: "r1", item: { type: "reasoning", text: "hm", think_ms: 1000 } }),
    ev("item_started", 1200, { id: "m1", kind: { type: "message" } }),
    ev("item_completed", 2000, { id: "m1", item: { type: "message", text: "Done." } }),
    ev("turn_ended", 2100, { turn: 1, reason: { type: "complete" }, usage: { context_tokens: null, input_tokens: 10, output_tokens: 20, model_calls: 1, pace: { bucket_ms: 1000, tokens: [5, 15] } } }),
  ].entries()) t = reduce(t, { ...e, seq: i + 1 } as never);
  const turn = t.turns[0];
  const html = renderToStaticMarkup(createElement(TurnFooter, { usage: turn.usage!, turn, models: [], answer: "Done.", pinned: false }));
  assert.match(html, /class="turn-graph"/);
  assert.match(html, /class="seg seg-thinking"/);
  assert.match(html, /class="pace"/);
  assert.doesNotMatch(html, /turn-card/);
});

// "Thought for Ns" says the same figure as the thinking segment (#441): for an older log's think
// (no think_ms), until the first message or tool call after it starts, or its completion if
// sooner; never just started to completed, which overstates it.
import { thinking } from "../src/engine/timeline.ts";
import { thoughtLabel, thinkMsOf } from "../src/ui/rows.ts";

test("every case's thinking: the label reads each reasoning item's figure, through the reducer", { skip: NO_CASES }, () => {
  let checked = 0;
  for (const c of cases) {
    if (!c.thinking) continue;
    assert.deepEqual(thinking(c.events), c.thinking, `${c.name}: thinking`);
    const t = c.events.reduce((x: typeof emptyThread, e: never) => reduce(x, e), emptyThread);
    const turn = t.turns.at(-1)!;
    for (const want of c.thinking as { item: string; ms: number }[]) {
      const e = turn.entries.find((x: { id: string }) => x.id === want.item)!;
      if (!e.done) continue;
      const s = Math.max(1, Math.round(want.ms / 1000));
      assert.equal(thinkMsOf(turn, e.id), want.ms, `${c.name}: ${want.item}'s ms`);
      assert.equal(thoughtLabel(e, undefined, thinkMsOf(turn, e.id)), `Thought for ${s}s`, `${c.name}: ${want.item}'s label`);
      checked++;
    }
  }
  assert.ok(checked >= 8, `checked ${checked} labels`);
});

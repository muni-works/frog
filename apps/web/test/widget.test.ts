import { test } from "node:test";
import assert from "node:assert/strict";
import { emptyThread, reduce } from "../src/engine/thread.ts";
import type { Envelope, Event } from "../src/cloud/protocol.ts";
import { promptGate } from "../src/ui/widgetGate.ts";

let seq = 0;
const env = (e: Event) => ({ ...e, seq: ++seq, session: "s1", created: 0 }) as Envelope;

test("a Visualize result keeps its widget on the entry, so replays redraw it", () => {
  let t = emptyThread;
  t = reduce(t, env({ event: "turn_started", turn: 1, input: "show me" }));
  t = reduce(t, env({ event: "item_started", id: "v1", kind: { type: "tool_call", name: "Visualize", arg: "casimir" } }));
  const widget = { title: "casimir", code: "<p>hi</p>", html: "<!doctype html><p>hi</p>" };
  t = reduce(t, env({ event: "item_completed", id: "v1", item: { type: "tool_call", name: "Visualize", arg: "casimir", outcome: "ok", output: "shown", display: null, widget } }));
  assert.deepEqual(t.turns[0].entries[0].widget, widget);
});

test("a widget's follow-ups are spaced out and capped per minute", () => {
  const ok = promptGate(4000, 3, 60_000);
  assert.equal(ok(0), true);
  assert.equal(ok(1000), false, "too soon after the last");
  assert.equal(ok(5000), true);
  assert.equal(ok(10_000), true);
  assert.equal(ok(20_000), false, "three in a minute already");
  assert.equal(ok(61_000), true, "the first has aged out");
});

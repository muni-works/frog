// The web's pen (src/ui/ink.ts) keeps the Mac's pace (InkReveal.swift): never slower than reading
// speed, never more than a third of a second behind what has arrived, a whole word at a time, and
// each word settling from green into ink over 0.42 s.
import { test } from "node:test";
import assert from "node:assert/strict";
import { advance, step, INK_STEPS } from "../src/ui/ink.ts";

const text = "The retry waited on the store, and the store gave up first.";

test("with little waiting it writes at reading pace, about 42 characters a second", () => {
  let r = { revealed: 0, carry: 0 }, t = 0;
  // Ten characters waiting is under a third of a second's worth at reading pace: the floor wins.
  while (r.revealed < 10 && t < 2) { r = advance(r.revealed, 10, 1 / 60, r.carry, true, "a b c d e "); t += 1 / 60; }
  // Not instant, and no slower than 42 a second (whole words round each step up).
  assert.ok(t > 0.1 && t <= 10 / 42 + 0.02, `ten characters took ${t.toFixed(2)} s`);
});

test("with a backlog it catches up to within a third of a second", () => {
  let r = { revealed: 0, carry: 0 }, t = 0;
  while (r.revealed < text.length && t < 2) { r = advance(r.revealed, text.length, 1 / 60, r.carry, true, text); t += 1 / 60; }
  assert.ok(t <= 0.4, `the backlog took ${t.toFixed(2)} s`);
});

test("it reveals whole words, and finishes faster once the stream is done", () => {
  const r = advance(0, text.length, 1 / 20, 0, true, text);
  assert.ok(r.revealed > 0 && /\s/.test(text[r.revealed - 1] ?? " ") || r.revealed === text.length, `stopped at a word's end: "${text.slice(0, r.revealed)}"`);
  const live = advance(0, text.length, 1 / 60, 0, true, text).revealed;
  const done = advance(0, text.length, 1 / 60, 0, false, text).revealed;
  assert.ok(done >= live, `done ${done} ≥ live ${live}`);
});

test("a word starts green and settles in 0.42 s", () => {
  assert.equal(step(0), 1);
  assert.equal(step(0.2), 3);
  assert.equal(step(0.42), INK_STEPS + 1, "settled: no highlight");
});

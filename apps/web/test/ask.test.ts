// The row's ask reads as one plain question, the same words as the Mac's; and an Ask card lets
// the person decide how many picks there are.
import { test } from "node:test";
import assert from "node:assert/strict";
import { askLine, clickOption, wide } from "../src/ui/ask.ts";

test("asks read as plain questions", () => {
  assert.equal(askLine("Bash", "cargo test -q\nmore"), "Run cargo test -q?");
  assert.equal(askLine("Edit", "src/fetch.ts"), "Edit fetch.ts?");
  assert.equal(askLine("WebFetch", "https://docs.rs/x"), "Open docs.rs?");
  assert.equal(askLine("Mcp", ""), "Allow Mcp?");
});

test("a plain click on a single-choice card still answers at once", () => {
  // The fast path: one click, one answer, no confirm step.
  assert.deepEqual(clickOption({ multi: false, picking: false, drafting: false }, "Truncate"), {
    kind: "answer",
    choices: ["Truncate"],
  });
});

test("a multi card toggles instead of answering", () => {
  assert.deepEqual(clickOption({ multi: true, picking: false, drafting: false }, "Truncate"), {
    kind: "toggle",
    picking: false,
  });
});

test("typing first makes the click part of one answer, not a race with it", () => {
  // The bug: with allow_other on a single-choice card, a click answered immediately, so the
  // words typed next to it could never be part of the answer. Now the click starts picking, and
  // the answer carries both.
  assert.deepEqual(clickOption({ multi: false, picking: false, drafting: true }, "Truncate"), {
    kind: "toggle",
    picking: true,
  });
  assert.equal(wide(false, true), true, "the card widens once it is picking");
});

test("once picking, further clicks keep toggling and the arity stays the person's", () => {
  assert.equal(wide(false, false), false);
  assert.deepEqual(clickOption({ multi: false, picking: true, drafting: false }, "Checksum"), {
    kind: "toggle",
    picking: true,
  });
  // Back to "pick one": the click toggles (no silent answer with what was already picked).
  assert.deepEqual(clickOption({ multi: false, picking: false, drafting: false }, "Checksum"), {
    kind: "answer",
    choices: ["Checksum"],
  });
  assert.equal(wide(true, false), true, "multi is always wide");
});


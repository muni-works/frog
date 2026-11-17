// frog.toys review: a turn that ended on a denial showed only a bare "denied" tag, and session
// rows had no accessible names.
import { test } from "node:test";
import assert from "node:assert/strict";
import { endNote } from "../src/ui/Transcript.tsx";
import { rowName } from "../src/ui/SessionList.tsx";
import { outOfCredits } from "../src/store.ts";
import { emptyThread } from "../src/engine/thread.ts";
import type { EndReason } from "../src/cloud/protocol.ts";

test("a denied turn ends with a plain sentence", () => {
  assert.match(endNote({ type: "denied" }) ?? "", /denied a step/);
});

test("the engine's own sentence is shown as is when it sends one", () => {
  assert.equal(endNote({ type: "denied", message: "You said no to apt-get, so I stopped." }), "You said no to apt-get, so I stopped.");
  assert.equal(endNote({ type: "complete" }), null);
  assert.equal(endNote({ type: "error", error: {}, message: "x" }), null, "errors have their own banner");
});

test("a session row reads as its title, state, repo and PR", () => {
  assert.equal(rowName("pomodoro timer cli", "Running", "frog", "#12"), "pomodoro timer cli, Running, in frog, pull request #12");
  assert.equal(rowName("notes", null, null, false), "notes");
});

// First-run audit (2026-11-17): since 2026-11-01 the engine ends a turn on an empty wallet with
// `billing_limit`, and the out-of-credit card only knew the old 402 error, so it never showed.
test("an empty wallet reads as out of credit, in either shape", () => {
  const t = (ended: EndReason) => ({ ...emptyThread, ended });
  assert.equal(outOfCredits(t({ type: "billing_limit", window: "credit" })), true);
  assert.equal(outOfCredits(t({ type: "error", error: { status: 402, code: "insufficient_credit" } })), true);
  assert.equal(outOfCredits(t({ type: "error", error: "connection reset" })), false);
  assert.equal(outOfCredits(t({ type: "complete" })), false);
});

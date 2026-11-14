// frog.toys review: a turn that ended on a denial showed only a bare "denied" tag, and session
// rows had no accessible names.
import { test } from "node:test";
import assert from "node:assert/strict";
import { endNote } from "../src/ui/Transcript.tsx";
import { rowName } from "../src/ui/SessionList.tsx";

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

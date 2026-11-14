// A short tool result is said on its row, with no click (Cam: a SendMessage row buried a
// sentence — two clicks on the Mac, one on the web). The Mac's ToolLook.inlineResults is the
// same set, so the two transcripts keep one look.
import { test } from "node:test";
import assert from "node:assert/strict";
import { LINE_CAP, fits, saidLine, sessionCount } from "../src/ui/Transcript.tsx";

test("a short result reads as its first sentence on the row", () => {
  // The engine's real SendMessage reply, cut to the meat.
  const said = saidLine(undefined, "Sent to ops (20261112-175150-6a2c); delivered (turn started). It reads the message at its next turn boundary; its reply, if any, arrives as a <session-message>.")
  assert.equal(said, "Sent to ops (20261112-175150-6a2c); delivered (turn started)")
});

test("an engine display wins over the raw output", () => {
  // Ask returns "The user chose: Send now" and displays "chose: Send now".
  assert.equal(saidLine("chose: Send now", "The user chose: Send now"), "chose: Send now")
});

test("a long result is clipped to one line", () => {
  const said = saidLine(undefined, "x".repeat(200))
  assert.equal(said.length, LINE_CAP)
  assert.ok(said.endsWith("…"))
});

test("an empty result says nothing", () => {
  assert.equal(saidLine(undefined, "  \n "), "")
  assert.equal(saidLine(null, ""), "")
});

test("a row gets no chevron when the line already says everything", () => {
  assert.equal(fits(undefined, "Sent to ops; delivered."), true)
  // Cut short: there is more behind the row.
  assert.equal(fits(undefined, "Sent to ops; delivered. It reads the message at its next boundary."), false)
  assert.equal(fits(undefined, "a\nb"), false)
});

test("ListSessions' page of JSON reads as a count", () => {
  const json = JSON.stringify([{ id: "a" }, { id: "b" }, { id: "c" }])
  assert.equal(sessionCount("listsessions", json), "3 sessions")
  assert.equal(sessionCount("listsessions", JSON.stringify([{ id: "a" }])), "1 session")
  // Only that tool: a Read of a JSON file must not read as a session list.
  assert.equal(sessionCount("read", json), null)
  assert.equal(sessionCount("listsessions", "not json"), null)
});

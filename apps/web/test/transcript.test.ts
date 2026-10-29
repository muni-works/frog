import { test } from "node:test";
import assert from "node:assert/strict";
import type { Envelope, FileDiff } from "../src/protocol.ts";
import { apply, empty, pending } from "../src/transcript.ts";

const env = (seq: number, e: object) => ({ seq, session: "s_1", created: 0, ...e }) as Envelope;
const diff: FileDiff = {
  path: "src/a.ts",
  created: false,
  added: 1,
  removed: 1,
  hunks: [{ lines: [{ kind: "remove", old: 1, new: null, text: "a" }, { kind: "add", old: null, new: 1, text: "b" }] }],
};

test("an edit: diff card to approve, then the tool line with its diff", () => {
  const t = [
    env(1, { event: "turn_started", turn: 1, input: "fix it" }),
    env(2, { event: "item_started", id: "i1", kind: { type: "tool_call", name: "Edit", arg: "src/a.ts" } }),
    env(3, { event: "permission_request", id: "p1", item: "i1", name: "Edit", arg: "src/a.ts", always: "Edit", preview: diff }),
    env(4, { event: "permission_resolved", id: "p1", decision: "allow" }),
    env(5, { event: "item_completed", id: "i1", item: { type: "tool_call", name: "Edit", arg: "src/a.ts", input: {}, outcome: "ok", output: "ok", display: null, diff } }),
    env(6, { event: "item_started", id: "i2", kind: { type: "message" } }),
    env(7, { event: "item_delta", id: "i2", delta: { type: "text", text: "Do" } }),
    env(8, { event: "item_delta", id: "i2", delta: { type: "text", text: "ne." } }),
    env(9, { event: "turn_ended", turn: 1, reason: { type: "complete" } }),
    env(10, { event: "some_future_event" }),
  ].reduce(apply, empty());
  assert.deepEqual(t.entries.map((e) => e.kind), ["user", "tool", "permission", "assistant"]);
  const p = t.entries[2];
  assert.ok(p.kind === "permission" && p.decision === "allow" && p.preview?.path === "src/a.ts");
  const tool = t.entries[1];
  assert.ok(tool.kind === "tool" && tool.outcome === "ok" && tool.diff);
  assert.equal(t.entries[3].kind === "assistant" && t.entries[3].text, "Done.");
  assert.equal(pending(t).length, 0);
  assert.equal(t.running, false);
});

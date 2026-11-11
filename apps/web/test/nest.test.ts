// Cloud sessions nest under the session that started them (the gateway's `parent`).
import { test } from "node:test";
import assert from "node:assert/strict";
import { indented } from "../src/ui/nest.ts";

const row = (id: string, parent?: string) => ({ id, parent });

test("a child follows its parent, one deeper", () => {
  const out = indented([row("a"), row("d", "gone"), row("b", "a"), row("c", "b"), row("e", "a")]);
  assert.deepEqual(out.map((n) => [n.row.id, n.depth]), [["a", 0], ["b", 1], ["c", 2], ["e", 1], ["d", 0]]);
});

test("an older gateway with no parent field stays flat", () => {
  const out = indented([row("a"), row("b"), row("c")]);
  assert.deepEqual(out.map((n) => [n.row.id, n.depth]), [["a", 0], ["b", 0], ["c", 0]]);
});

test("a cycle loses nothing", () => {
  const out = indented([row("x", "y"), row("y", "x")]);
  assert.deepEqual(out.map((n) => n.row.id), ["x", "y"]);
});

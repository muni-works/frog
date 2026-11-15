import { test } from "node:test";
import assert from "node:assert/strict";
import { keyData } from "../src/ui/TerminalPane.tsx";
import { emptyThread, reduce } from "../src/engine/thread.ts";
import type { Envelope, Event } from "../src/cloud/protocol.ts";

const k = (key: string, mods: Partial<{ ctrlKey: boolean; metaKey: boolean; altKey: boolean }> = {}) => keyData({ key, ctrlKey: false, metaKey: false, altKey: false, ...mods });

test("keys become the bytes a terminal expects", () => {
  assert.equal(k("a"), "a");
  assert.equal(k("Enter"), "\r");
  assert.equal(k("Backspace"), "\x7f");
  assert.equal(k("ArrowUp"), "\x1b[A");
  assert.equal(k("c", { ctrlKey: true }), "\x03");
  assert.equal(k("b", { altKey: true }), "\x1bb");
  assert.equal(k("c", { metaKey: true }), null); // ⌘C copies
  assert.equal(k("Shift"), null);
});

let seq = 0;
const env = (e: Event) => ({ ...e, seq: ++seq, session: "s", created: 0 }) as Envelope;

test("a pane keeps its newest screen and knows when it closed", () => {
  let t = reduce(emptyThread, env({ event: "pane_opened", id: "p1", kind: "terminal", title: "zsh" }));
  t = reduce(t, env({ event: "pane_screen", id: "p1", cols: 80, rows: 2, lines: ["$ ls", ""], cursor: [1, 0], screen_seq: 2 }));
  t = reduce(t, env({ event: "pane_screen", id: "p1", cols: 80, rows: 2, lines: ["old", ""], cursor: [0, 0], screen_seq: 1 }));
  assert.equal(t.panes.p1.screen?.lines[0], "$ ls");
  t = reduce(t, env({ event: "pane_closed", id: "p1", exit: 0 }));
  assert.equal(t.panes.p1.closed, true);
});

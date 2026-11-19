// The notes Frog keeps and uses, in the conversation (docs/customize-events.md, "Noted" and "Used
// notes"; canvas M2): "Noted for pond" under the reply with Undo and Make it a rule, the Note call
// that kept it not drawn as a step, and "Used N notes" with the lines that came back.
import { test } from "node:test";
import assert from "node:assert/strict";
import { createElement as h } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import TestRenderer, { act } from "react-test-renderer";
import { emptyThread, reduce, type Thread } from "../src/engine/thread.ts";
import { NotedLine, Transcript, UsedNotesBlock } from "../src/ui/Transcript.tsx";
import type { Envelope } from "../src/cloud/protocol.ts";

let seq = 0;
const env = (e: Record<string, unknown>) => ({ seq: ++seq, session: "s", created: 1_790_000_000_000 + seq, ...e }) as unknown as Envelope;
const fold = (events: Record<string, unknown>[], t: Thread = emptyThread) => events.map(env).reduce(reduce, t);

const noted = { event: "noted", item: "call_9", turn: 1, id: "n_4", text: "Use pnpm here, never npm.", scope: "project", place: "pond", source: "correction", undo: "u_n4" };
const used = { event: "used_notes", turn: 1, tokens: 24, notes: [{ id: "n_1", scope: "project", text: "Tests run with cargo nextest." }, { id: "n_2", scope: "everywhere", text: "Keep replies short." }] };
const turn = [
  { event: "turn_started", turn: 1, input: "no, we use pnpm here, never npm" },
  { event: "item_started", id: "call_9", kind: { type: "tool_call", name: "Note", arg: "Use pnpm here, never npm." } },
  { event: "item_completed", id: "call_9", item: { type: "tool_call", name: "Note", arg: "Use pnpm here, never npm.", input: {}, outcome: "ok", output: "Noted.", display: null } },
];
const noop = () => {};
const page = (thread: Thread) => renderToStaticMarkup(h(Transcript, { thread, onDecide: noop, onAnswer: noop, onElicit: noop, onRetry: noop }));

test("noted and used_notes land on their turn", () => {
  const t = fold([...turn, noted, used]);
  assert.deepEqual(t.turns[0].noted, { item: "call_9", id: "n_4", text: "Use pnpm here, never npm.", scope: "project", place: "pond", undo: "u_n4" });
  assert.equal(t.turns[0].usedNotes?.notes.length, 2);
  // No notes came back: nothing to say.
  assert.equal(fold([...turn, { ...used, notes: [] }]).turns[0].usedNotes, undefined);
});

test("the note draws under the reply, and the Note call that kept it isn't a step of its own", () => {
  const before = page(fold(turn));
  assert.match(before, /data-item="call_9"|Use pnpm here/, "before noted, the call draws as any step");
  const html = page(fold([...turn, noted, used]));
  assert.match(html, /Noted for pond/);
  assert.equal(html.match(/Use pnpm here, never npm\./g)?.length, 1, "once, on the noted line");
  assert.match(html, /data-row="noted"[\s\S]*data-row="used-notes"/);
  assert.match(html, /Used 2 notes[\s\S]*Tests run with cargo nextest\.[\s\S]*Keep replies short\./);
});

test("Undo sends the note's handle, Make it a rule its id and scope; Undo's answer replaces them", () => {
  const t = fold([...turn, noted]);
  const n = t.turns[0].noted!;
  const got: string[] = [];
  let r!: TestRenderer.ReactTestRenderer;
  act(() => { r = TestRenderer.create(h(NotedLine, { noted: n, onUndo: (u: string) => got.push(`undo ${u}`), onRule: (x: typeof n) => got.push(`rule ${x.id} ${x.scope}`) })); });
  const button = (label: string) => r.root.findAll((x) => x.type === "button" && x.children.join("") === label)[0];
  act(() => button("Undo").props.onClick());
  act(() => button("Make it a rule").props.onClick());
  assert.deepEqual(got, ["undo u_n4", "rule n_4 project"]);

  const ok = fold([{ event: "customize_undone", undo: "u_n4", ok: true }], t).turns[0].noted!;
  const okHtml = renderToStaticMarkup(h(NotedLine, { noted: ok, onUndo: noop, onRule: noop }));
  assert.match(okHtml, /Forgot for pond/);
  assert.doesNotMatch(okHtml, />Undo</);
  const bad = fold([{ event: "customize_undone", undo: "u_n4", ok: false, message: "That note is already gone." }], t).turns[0].noted!;
  const badHtml = renderToStaticMarkup(h(NotedLine, { noted: bad, onUndo: noop, onRule: noop }));
  assert.match(badHtml, /That note is already gone\./);
  assert.doesNotMatch(badHtml, />Make it a rule</);
});

test("one note reads singular", () => {
  assert.match(renderToStaticMarkup(h(UsedNotesBlock, { used: { tokens: 8, notes: [{ id: "n_1", scope: "project", text: "x" }] } })), /Used 1 note</);
});

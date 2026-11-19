// Customize cards in the conversation (docs/customize-events.md; canvas N7 Remember, N9 Change):
// the card a change waits on (`permission_request` with a `proposal`), the receipt with Undo once
// it's made (`customize_applied`, then `customize_undone`), the app's own settings changed by
// `setting_change`, and the caps that let the engine offer the tool only to an app that draws it.
import { test } from "node:test";
import assert from "node:assert/strict";
import { createElement as h } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import TestRenderer, { act } from "react-test-renderer";
import { emptyThread, reduce, type Thread } from "../src/engine/thread.ts";
import { AppliedLine, ProposalCard, Transcript, type DecideOpts } from "../src/ui/Transcript.tsx";
import { caps } from "../src/engine/cloud.ts";
import type { Envelope, Proposal } from "../src/cloud/protocol.ts";

let seq = 0;
const env = (e: Record<string, unknown>) => ({ seq: ++seq, session: "s", created: 1_790_000_000_000 + seq, ...e }) as unknown as Envelope;
const fold = (events: Record<string, unknown>[], t: Thread = emptyThread) => events.map(env).reduce(reduce, t);

const remember: Proposal = {
  kind: "line", title: "Remember this?", change: { new: "Use pnpm in this project, never npm." },
  where: "In pond, in AGENTS.md, so your team gets it too", tokens_per_turn: 12, primary: "Remember", dismiss: "Not now",
  alternative: { id: "notes", label: "Keep it just for me", where: "Frog's notes for pond, only you", tokens_per_turn: 12 },
  asked_by: { who: "frog", words: "no, we use pnpm here, never npm" },
};
const density: Proposal = {
  kind: "setting", title: "Change Density", change: { old: "Comfortable", new: "Compact" }, where: "Settings, on this device",
  primary: "Change", dismiss: "Not now", asked_by: { who: "user", words: "make it compact" },
};

const turn = [
  { event: "turn_started", turn: 1, input: "no, we use pnpm here, never npm" },
  { event: "item_started", id: "call_3", kind: { type: "tool_call", name: "Customize", arg: "Remember this?" } },
];

test("a Customize card is the approval with a proposal: the ask carries it", () => {
  const t = fold([...turn, { event: "permission_request", id: "p_81", item: "call_3", name: "Customize", arg: "Remember this?", always: "", reason: remember.where, proposal: remember }]);
  assert.deepEqual(t.ask?.proposal, remember);
});

test("the card: the change in a well, where it goes and what a turn costs, then Remember, Not now, and the alternative", () => {
  const ask = { id: "p_81", item: "call_3", name: "Customize", arg: "Remember this?", proposal: remember };
  const html = renderToStaticMarkup(h(ProposalCard, { ask, proposal: remember, onDecide: () => {} }));
  assert.match(html, />Remember this\?</);
  assert.match(html, /Use pnpm in this project, never npm\./);
  assert.match(html, /In pond, in AGENTS\.md, so your team gets it too\. Adds 12 tokens to each turn\./);
  assert.match(html, />Remember<[\s\S]*>Not now<[\s\S]*>Keep it just for me</);
  // Frog offered it: no "needs you" dot (that's for a change the person asked for that waits on them).
  assert.doesNotMatch(html, /needs-dot/);
});

test("each answer sends its decision: the primary allows, Not now denies, the alternative allows with its choice", () => {
  const ask = { id: "p_81", item: "call_3", name: "Customize", arg: "Remember this?", proposal: remember };
  const got: [boolean, DecideOpts | undefined][] = [];
  let r!: TestRenderer.ReactTestRenderer;
  act(() => { r = TestRenderer.create(h(ProposalCard, { ask, proposal: remember, onDecide: (a: boolean, o?: DecideOpts) => got.push([a, o]) })); });
  const button = (label: string) => r.root.findAll((n) => n.type === "button" && n.children.join("") === label)[0];
  act(() => button("Remember").props.onClick());
  act(() => button("Not now").props.onClick());
  act(() => button("Keep it just for me").props.onClick());
  assert.deepEqual(got, [[true, undefined], [false, undefined], [true, { choice: "notes" }]]);
  act(() => r.unmount());
});

test("a setting's card shows old to new, with the dot when it waits on the person who asked", () => {
  const ask = { id: "p_9", item: "call_9", name: "Customize", arg: "Change Density", proposal: density };
  const html = renderToStaticMarkup(h(ProposalCard, { ask, proposal: density, onDecide: () => {} }));
  assert.match(html, /needs-dot/);
  assert.match(html, />Density<\/span><span class="o">Comfortable<\/span><span class="a">to<\/span><span>Compact</);
  assert.match(html, /Settings, on this device\./);
});

test("a change made shows on its call as a one-line receipt with Undo; Undo's answer replaces the button", () => {
  let t = fold([...turn, { event: "customize_applied", item: "call_3", undo: "u_5c1", card: { ...remember, title: "Remember this" } }]);
  const entry = t.turns[0].entries.find((e) => e.id === "call_3")!;
  assert.equal(entry.applied?.undo, "u_5c1");
  const undos: string[] = [];
  let r!: TestRenderer.ReactTestRenderer;
  act(() => { r = TestRenderer.create(h(AppliedLine, { applied: entry.applied!, onUndo: (u: string) => undos.push(u) })); });
  const text = () => r.root.findAll((n) => typeof n.type === "string").map((n) => n.children.filter((c) => typeof c === "string").join("")).join(" ");
  assert.match(text(), /Remembered/);
  assert.match(text(), /Use pnpm in this project, never npm\./);
  act(() => r.root.findAll((n) => n.type === "button" && n.children.join("") === "Undo")[0].props.onClick());
  assert.deepEqual(undos, ["u_5c1"]);
  act(() => r.unmount());
  t = fold([{ event: "customize_undone", undo: "u_5c1", ok: false, message: "The file changed since; nothing was undone." }], t);
  const html = renderToStaticMarkup(h(AppliedLine, { applied: t.turns[0].entries.find((e) => e.id === "call_3")!.applied!, onUndo: () => {} }));
  assert.match(html, /The file changed since; nothing was undone\./);
  assert.doesNotMatch(html, />Undo</);
});

test("in the transcript, the card stands in for the waiting call, and the receipt for the finished one", () => {
  const asking = fold([...turn, { event: "permission_request", id: "p_81", item: "call_3", name: "Customize", arg: "Remember this?", always: "", proposal: remember }]);
  const noop = () => {};
  const html = renderToStaticMarkup(h(Transcript, { thread: asking, onDecide: noop, onAnswer: noop, onElicit: noop, onRetry: noop }));
  assert.match(html, /cardx ask proposal/);
  const done = fold([{ event: "permission_resolved", id: "p_81", decision: "allow" }, { event: "item_completed", id: "call_3", item: { type: "tool_call", name: "Customize", arg: "Remember this?", input: {}, outcome: "ok", output: "Saved.", display: null } },
    { event: "customize_applied", item: "call_3", undo: "u_1", card: remember }], asking);
  const after = renderToStaticMarkup(h(Transcript, { thread: done, onDecide: noop, onAnswer: noop, onElicit: noop, onRetry: noop }));
  assert.match(after, /line-row applied/);
  assert.doesNotMatch(after, /cardx ask proposal/);
});

test("the engine is told this app draws Customize cards, so it offers the tool here", () => {
  assert.deepEqual(caps(false), { op: "set_client_caps", ask: true, panes: false, customize: true });
});

test("setting_change changes this app's own setting; one it doesn't keep is left alone", async () => {
  const g = globalThis as unknown as { document?: unknown };
  const had = g.document;
  const root = { dataset: {} as Record<string, string | undefined> };
  g.document = { documentElement: root };
  try {
    const { applySetting, customizableSettings } = await import("../src/settings.ts");
    assert.equal(applySetting("density", "compact"), true);
    assert.equal(root.dataset.density, "compact");
    assert.equal(applySetting("theme", "dark"), true);
    assert.equal(root.dataset.theme, "dark");
    assert.equal(applySetting("sounds", false), false, "the web has no sounds setting");
    assert.equal(applySetting("density", "huge"), false, "not one of the row's options");
    assert.deepEqual(Object.keys(customizableSettings()).sort(), ["density", "theme"]);
  } finally {
    g.document = had;
  }
});

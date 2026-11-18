// The first run without GitHub (design board 2, "Web: the first run"): the composer works and
// starts a scratch sandbox, nothing on that path asks for GitHub first, and after the first
// finished turn one card offers GitHub, once per account.
import { test } from "node:test";
import assert from "node:assert/strict";
import { createElement as h } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import TestRenderer, { act } from "react-test-renderer";
import { Composer, type ComposerProps } from "../src/ui/Composer.tsx";
import { ConnectCard } from "../src/ui/ConnectCard.tsx";
import { accountTag, connectCard, finishedTurn, loadMemo, saveMemo, type CardMemo } from "../src/connectCard.ts";
import type { EndReason } from "../src/cloud/protocol.ts";

(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;
const g = globalThis as { addEventListener?: unknown; removeEventListener?: unknown };
g.addEventListener ??= () => {};
g.removeEventListener ??= () => {};

const noop = () => {};
const base: ComposerProps = { onSend: noop, onMode: noop, mode: "auto", model: "glm-5.3-flash", models: [{ id: "glm-5.3-flash", context: 131072, input: 4e-8, output: 4e-7, cached: null }], onModel: noop };
// Signed in with Google or email: no repos, the where menu can connect GitHub, no repo picked.
const noGithub: Partial<ComposerProps> = { onRepo: noop, repos: [], recent: [], onConnectGithub: noop, install: "https://github.com/apps/frog/installations/new" };

// ---------- the composer ----------

test("no GitHub: the where chip says Scratch sandbox and the composer offers no sign-in", () => {
  const s = renderToStaticMarkup(h(Composer, { ...base, ...noGithub }));
  assert.match(s, /aria-label="Where it runs: Scratch sandbox"/);
  assert.ok(!s.includes("cz-signin") && !s.includes("Connect GitHub"), s);
});

test("no GitHub: the where menu leads with Scratch sandbox, checked, and connecting is an extra row", () => {
  const s = renderToStaticMarkup(h(Composer, { ...base, ...noGithub, pickRepo: true }));
  assert.match(s, /aria-checked="true"[^>]*>.*?Scratch sandbox/);
  assert.match(s, /Connect GitHub to see your repos/);
});

test("no GitHub: typing and pressing send starts the session with no repo asked for", async () => {
  const sent: string[] = [];
  let connect = 0;
  let r!: TestRenderer.ReactTestRenderer;
  await act(async () => {
    r = TestRenderer.create(h(Composer, { ...base, ...noGithub, onConnectGithub: () => { connect++ }, onSend: (t) => sent.push(t) }));
  });
  const box = r.root.findByType("textarea");
  const text = "A pomodoro timer with a sleepy frog";
  await act(async () => box.props.onChange({ target: { value: text, style: {}, scrollHeight: 20 } }));
  const action = r.root.findAll((n) => n.type === "button" && typeof n.props.className === "string" && n.props.className.includes("cz-act "))[0];
  assert.ok(action, "the action button");
  assert.notEqual(action.props.disabled, true);
  await act(async () => r.root.findByType("textarea").props.onKeyDown({ key: "Enter", shiftKey: false, metaKey: false, ctrlKey: false, nativeEvent: { isComposing: false }, preventDefault: noop }));
  assert.deepEqual(sent, ["A pomodoro timer with a sleepy frog"]);
  assert.equal(connect, 0);
  r.unmount();
});

// ---------- the card ----------

const turn = (type: EndReason["type"]) => ({ turn: 1, input: "x", entries: [], reason: { type } as EndReason });

test("a finished turn is one that completed, with nothing running", () => {
  assert.equal(finishedTurn({ running: false, turns: [] }), false);
  assert.equal(finishedTurn({ running: false, turns: [turn("complete")] }), true);
  assert.equal(finishedTurn({ running: true, turns: [turn("complete")] }), false);
  assert.equal(finishedTurn({ running: false, turns: [turn("error")] }), false);
  assert.equal(finishedTurn({ running: false, turns: [turn("billing_limit")] }), false);
  assert.equal(finishedTurn({ running: false, turns: [turn("cancelled")] }), false);
  assert.equal(finishedTurn({ running: false, turns: [turn("error"), turn("complete")] }), true);
});

test("the card: never before a result, never with GitHub", () => {
  assert.deepEqual(connectCard(null, { github: false, session: "a", finished: false }), { show: false, claim: false });
  assert.deepEqual(connectCard(null, { github: true, session: "a", finished: true }), { show: false, claim: false });
});

test("the card: the first finished turn shows it and claims that session", () => {
  assert.deepEqual(connectCard(null, { github: false, session: "a", finished: true }), { show: true, claim: true });
});

test("the card: once claimed it stays in its session and nowhere else", () => {
  const memo: CardMemo = { session: "a" };
  assert.deepEqual(connectCard(memo, { github: false, session: "a", finished: true }), { show: true, claim: false });
  assert.deepEqual(connectCard(memo, { github: false, session: "b", finished: true }), { show: false, claim: false });
  // Hidden while the next turn runs, back after it.
  assert.equal(connectCard(memo, { github: false, session: "a", finished: false }).show, false);
});

test("the card: Keep going here retires it for good, and GitHub hides it", () => {
  assert.equal(connectCard({ done: true }, { github: false, session: "a", finished: true }).show, false);
  assert.equal(connectCard({ session: "a" }, { github: true, session: "a", finished: true }).show, false);
});

class Mem implements Storage {
  m = new Map<string, string>();
  get length() { return this.m.size; }
  clear() { this.m.clear(); }
  getItem(k: string) { return this.m.get(k) ?? null; }
  key(i: number) { return [...this.m.keys()][i] ?? null; }
  removeItem(k: string) { this.m.delete(k); }
  setItem(k: string, v: string) { this.m.set(k, v); }
}

test("the card's memory is per account and survives a reload", () => {
  const s = new Mem();
  const a = accountTag({ email: "a@example.com", google: null, name: null });
  const b = accountTag({ email: null, google: "b@gmail.com", name: "B" });
  assert.equal(loadMemo(s, a), null);
  saveMemo(s, a, { session: "s1" });
  saveMemo(s, b, { done: true });
  assert.deepEqual(loadMemo(s, a), { session: "s1" });
  assert.deepEqual(loadMemo(s, b), { done: true });
  // A broken value reads as nothing rather than throwing.
  s.setItem("frog.connectCard", "{nope");
  assert.equal(loadMemo(s, a), null);
  // No storage at all (private mode, a blocked accessor) is fine too.
  assert.equal(loadMemo(undefined, a), null);
  saveMemo(undefined, a, { done: true });
});

test("the card's words and buttons, with no credit promise", () => {
  const html = renderToStaticMarkup(h(ConnectCard, { onConnect: noop, onDismiss: noop }));
  assert.match(html, /Try it on your own code/);
  assert.match(html, /Connect GitHub and Frog can open pull requests on your repos\./);
  assert.match(html, />Connect GitHub</);
  assert.match(html, />Keep going here</);
  assert.ok(!/\$|¢|cent|credit/i.test(html), html);
});

test("the card's buttons connect and dismiss", async () => {
  let c = 0, d = 0;
  let r!: TestRenderer.ReactTestRenderer;
  await act(async () => { r = TestRenderer.create(h(ConnectCard, { onConnect: () => { c++ }, onDismiss: () => { d++ } })); });
  const [connect, keep] = r.root.findAllByType("button");
  await act(async () => connect.props.onClick());
  await act(async () => keep.props.onClick());
  assert.deepEqual([c, d], [1, 1]);
  r.unmount();
});

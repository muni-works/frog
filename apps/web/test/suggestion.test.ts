// The composer's one suggestion (ui/suggestion.ts): muted text in the empty field with a "tab"
// hint; Tab or the hint takes it; a list cycles every 6 s (180 ms out, then the next) until you
// type; reduced motion never cycles. And the landing: the "What is Frog?" card signed out only.
import { afterEach, beforeEach, test } from "node:test";
import assert from "node:assert/strict";
import { createElement as h } from "react";
import TestRenderer, { act, type ReactTestInstance } from "react-test-renderer";
import { Composer, type ComposerProps } from "../src/ui/Composer.tsx";
import { SUGGEST } from "../src/ui/suggestion.ts";

(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;
const g = globalThis as { addEventListener?: unknown; removeEventListener?: unknown; matchMedia?: unknown };
g.addEventListener ??= () => {};
g.removeEventListener ??= () => {};

const LIST = ["Make a tiny pomodoro timer", "Build a Markdown notes app", "Write a CLI that renames photos"];
const base: ComposerProps = { onSend: () => {} };

// A small fake clock for setTimeout (node's mock timers proved flaky with React's act here).
type Timer = { id: number; at: number; f: () => void };
const clock = { now: 0, seq: 0, timers: [] as Timer[] };
const real = { setTimeout: globalThis.setTimeout, clearTimeout: globalThis.clearTimeout };
const gt = globalThis as unknown as { setTimeout: unknown; clearTimeout: unknown };
function advance(ms: number) {
  const end = clock.now + ms;
  for (;;) {
    const next = clock.timers.filter((t) => t.at <= end).sort((a, b) => a.at - b.at || a.id - b.id)[0];
    if (!next) break;
    clock.timers = clock.timers.filter((t) => t !== next);
    clock.now = next.at;
    next.f();
  }
  clock.now = end;
}
beforeEach(() => {
  clock.now = 0; clock.timers = [];
  gt.setTimeout = (f: () => void, ms = 0) => { const t = { id: ++clock.seq, at: clock.now + ms, f }; clock.timers.push(t); return t.id; };
  gt.clearTimeout = (id: number) => { clock.timers = clock.timers.filter((t) => t.id !== id); };
});
afterEach(() => { gt.setTimeout = real.setTimeout; gt.clearTimeout = real.clearTimeout; delete g.matchMedia; });

function render(p: Partial<ComposerProps>) {
  let r!: TestRenderer.ReactTestRenderer;
  act(() => { r = TestRenderer.create(h(Composer, { ...base, ...p }), { createNodeMock: () => ({ focus() {}, style: {}, scrollHeight: 20 }) }); });
  const field = () => r.root.find((n) => n.type === "textarea");
  const shown = () => { const s = r.root.findAll((n) => n.type === "span" && n.props.className === "cz-sg-text"); return s.length ? String(s[0].children.join("")) : null; };
  const out = () => r.root.findAll((n) => typeof n.props.className === "string" && n.props.className.startsWith("cz-sg ")).length > 0;
  const key = (k: string, extra: Record<string, unknown> = {}) => {
    let prevented = false;
    act(() => { (field().props.onKeyDown as (e: unknown) => void)({ key: k, shiftKey: false, altKey: false, ctrlKey: false, metaKey: false, nativeEvent: {}, preventDefault() { prevented = true; }, ...extra }); });
    return prevented;
  };
  const type = (value: string) => act(() => { (field().props.onChange as (e: unknown) => void)({ target: { value, style: {}, scrollHeight: 20 } }); });
  const tick = (ms: number) => act(() => { advance(ms); });
  const cycle = (n = 1) => { for (let i = 0; i < n; i++) { tick(SUGGEST.holdMs); tick(SUGGEST.outMs); } };
  return { r, field, shown, out, key, type, tick, cycle };
}

test("the empty field shows the suggestion with a tab hint, and the placeholder carries its words", () => {
  const c = render({ suggestion: LIST });
  assert.equal(c.shown(), LIST[0]);
  assert.equal(c.field().props.placeholder, LIST[0]);
  const hint = c.r.root.find((n: ReactTestInstance) => n.type === "button" && n.props.className === "cz-tab");
  assert.equal(hint.children.join(""), "tab");
  c.r.unmount();
});

test("Tab puts the suggestion in the field", () => {
  const c = render({ suggestion: LIST });
  assert.equal(c.key("Tab"), true, "Tab is taken, not moving focus");
  assert.equal(c.field().props.value, LIST[0]);
  assert.equal(c.shown(), null, "the suggestion is gone once it's in");
  c.r.unmount();
});

test("Shift+Tab, or Tab with something typed, moves focus as ever", () => {
  const c = render({ suggestion: LIST });
  assert.equal(c.key("Tab", { shiftKey: true }), false);
  assert.equal(c.field().props.value, "");
  c.type("fix");
  assert.equal(c.key("Tab"), false);
  assert.equal(c.field().props.value, "fix");
  c.r.unmount();
});

test("the tab hint takes the suggestion too (phones have no Tab key)", () => {
  const c = render({ suggestion: LIST });
  const hint = c.r.root.find((n) => n.type === "button" && n.props.className === "cz-tab");
  act(() => { (hint.props.onClick as () => void)(); });
  assert.equal(c.field().props.value, LIST[0]);
  c.r.unmount();
});

test("a list cycles: holds 6 s, fades out for 180 ms, then the next one", () => {
  const c = render({ suggestion: LIST });
  c.tick(SUGGEST.holdMs - 1);
  assert.equal(c.shown(), LIST[0]);
  assert.equal(c.out(), false);
  c.tick(1);
  assert.equal(c.out(), true, "fading out");
  assert.equal(c.shown(), LIST[0]);
  c.tick(SUGGEST.outMs);
  assert.equal(c.out(), false);
  assert.equal(c.shown(), LIST[1]);
  c.cycle();
  assert.equal(c.shown(), LIST[2]);
  c.cycle();
  assert.equal(c.shown(), LIST[0], "and round again");
  c.r.unmount();
});

test("a new array with the same words doesn't restart the hold", () => {
  const c = render({ suggestion: [...LIST] });
  c.tick(SUGGEST.holdMs - 10);
  act(() => { c.r.update(h(Composer, { ...base, suggestion: [...LIST] })); });
  c.tick(10);
  c.tick(SUGGEST.outMs);
  assert.equal(c.shown(), LIST[1]);
  c.r.unmount();
});

test("typing stops the cycle for good, even after the field is cleared", () => {
  const c = render({ suggestion: LIST });
  c.cycle();
  assert.equal(c.shown(), LIST[1]);
  c.type("w");
  c.type("");
  c.cycle(5);
  assert.equal(c.shown(), LIST[1], "the one showing when you typed stays");
  assert.equal(c.out(), false);
  c.r.unmount();
});

test("reduced motion: no cycling, the first suggestion stays", () => {
  g.matchMedia = (q: string) => ({ matches: q.includes("reduce"), addEventListener() {}, removeEventListener() {} });
  const c = render({ suggestion: LIST });
  c.cycle(5);
  assert.equal(c.shown(), LIST[0]);
  assert.equal(c.out(), false);
  c.r.unmount();
});

test("one string (a follow-up) stays put; none, the usual placeholder", () => {
  const c = render({ suggestion: "Run the tests again" });
  c.cycle(3);
  assert.equal(c.shown(), "Run the tests again");
  c.r.unmount();
  const none = render({});
  assert.equal(none.shown(), null);
  assert.equal(none.field().props.placeholder, "What should we work on?");
  none.r.unmount();
});

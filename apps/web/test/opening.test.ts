// The new session's status row and helpers (ui/Opening.tsx): the transcript spec's motion rule
// for a changing line (nothing for 600 ms, a cross-fade, at most one change per 1.2 s), the clock
// from 5 s, and the pieces App uses to keep one view from Send to the first turn.
import { after, before, mock, test } from "node:test";
import assert from "node:assert/strict";
import { createElement as h } from "react";
import TestRenderer, { act } from "react-test-renderer";
import { BOOT, BootRow, bootWords, firstTitle, provisional, undelivered, withOpening, type Opening } from "../src/ui/Opening.tsx";
import { emptyThread } from "../src/engine/thread.ts";

(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

// Once for the file: node 20's mocked setInterval stops firing after a reset and enable.
before(() => mock.timers.enable({ apis: ["setTimeout", "setInterval", "Date"] }));
after(() => mock.timers.reset());

const text = (n: TestRenderer.ReactTestInstance | string): string => typeof n === "string" ? n : n.children.map(text).join("");
/** The clock under the row, from the rendered output. */
const clock = (r: TestRenderer.ReactTestRenderer): string | null => {
  const m = JSON.stringify(r.toJSON()).match(/"className":"live-figures"\},"children":\["([^"]*)"\]/);
  return m ? m[1] : null;
};
const row = (r: TestRenderer.ReactTestRenderer) => r.root.find((n) => n.type === "div" && n.props["data-row"] === "live");
// In steps: one long tick doesn't run node's mocked setInterval for every period it covers.
const advance = async (ms: number) => { for (let left = ms; left > 0; left -= 250) await act(() => { mock.timers.tick(Math.min(250, left)); }); };

test("the row keeps its place but shows nothing for the first 600 ms", async () => {
  let r!: TestRenderer.ReactTestRenderer;
  await act(() => { r = TestRenderer.create(h(BootRow, { since: Date.now() })); });
  assert.equal(row(r).props["data-ready"], "false");
  assert.equal(text(row(r)), "Starting a sandbox", "its words are there (its height is kept), just not shown");
  await advance(500);
  assert.equal(row(r).props["data-ready"], "false");
  await advance(250);
  assert.equal(row(r).props["data-ready"], "true");
  r.unmount();
});

test("the seconds show from 5 s, not before", async () => {
  let r!: TestRenderer.ReactTestRenderer;
  await act(() => { r = TestRenderer.create(h(BootRow, { since: Date.now(), repo: "ecto/pond" })); });
  await advance(4750);
  assert.equal(clock(r), null);
  await advance(500);
  assert.equal(clock(r), "5s");
  assert.ok(text(row(r)).startsWith("Starting a sandbox for ecto/pond"));
  r.unmount();
});

test("a change waits out 1.2 s since the last, then cross-fades: the old words out, the new in", async () => {
  const since = Date.now();
  let r!: TestRenderer.ReactTestRenderer;
  await act(() => { r = TestRenderer.create(h(BootRow, { since })); });
  await advance(300);
  await act(() => { r.update(h(BootRow, { since, error: "Couldn't clone ecto/pond.", onRetry: () => {} })); });
  await advance(600);
  assert.equal(text(row(r)), "Starting a sandbox", "held: under 1.2 s since it showed");
  await advance(400);
  const layers = r.root.findAll((n) => typeof n.props.className === "string" && /^tf\b/.test(n.props.className));
  assert.deepEqual(layers.map((n) => [n.props.className, text(n)]), [["tf tf-was", "Starting a sandbox"], ["tf tf-now", "Failed Couldn't clone ecto/pond."]]);
  assert.equal(row(r).props["data-state"], "failed");
  assert.ok(r.root.find((n) => n.type === "button" && text(n) === BOOT.retry), "Try again");
  assert.equal(clock(r), null, "no clock on a failure");
  r.unmount();
});

test("shown once, Try again's new clock doesn't hide it again", async () => {
  let r!: TestRenderer.ReactTestRenderer;
  await act(() => { r = TestRenderer.create(h(BootRow, { since: Date.now(), error: "x", onRetry: () => {} })); });
  await advance(2000);
  assert.equal(row(r).props["data-ready"], "true");
  await act(() => { r.update(h(BootRow, { since: Date.now() })); });
  assert.equal(row(r).props["data-ready"], "true");
  r.unmount();
});

test("words: starting, with the repo when there is one; failed with the reason", () => {
  assert.deepEqual(bootWords({}), { verb: "Starting", object: "a sandbox", failed: false });
  assert.deepEqual(bootWords({ repo: "ecto/pond" }), { verb: "Starting", object: "a sandbox for ecto/pond", failed: false });
  assert.deepEqual(bootWords({ repo: "ecto/pond", error: "No access." }), { verb: "Failed", object: "No access.", failed: true });
});

const op = (over: Partial<Opening> = {}): Opening => ({ text: "hi", images: [], at: 0, row: { id: "pending-1", title: "hi", repo: "", branch: "", state: "starting", updated: 0 }, ...over });

test("withOpening: a session still opening stays listed until the list has it", () => {
  const listed = [{ id: "s_old", title: "old", repo: "", branch: "", state: "running", updated: 1 }];
  assert.deepEqual(withOpening(listed, { "pending-1": op() }).map((s) => s.id), ["pending-1", "s_old"]);
  const real = { ...op().row, id: "s_new", state: "running" };
  assert.equal(withOpening([real, ...listed], { s_new: op({ row: { ...real, state: "starting" } }) })[0].state, "running", "the list's newer state wins");
  assert.equal(withOpening(listed, {}), listed);
});

test("provisional: the sent message as a first turn with nothing running", () => {
  const t = provisional({ ...emptyThread, running: true }, op({ text: "Make a timer" }));
  assert.equal(t.running, false);
  assert.deepEqual(t.turns, [{ turn: 0, input: "Make a timer", entries: [] }]);
});

test("undelivered: a message whose turn has started is gone in the same render", () => {
  const out = [{ text: "a", seen: 0 }, { text: "b", seen: 0 }];
  assert.deepEqual(undelivered(out, [{ input: "a" }]), [{ text: "b", seen: 0 }]);
  assert.equal(undelivered(out, []), out, "the same list when nothing changed");
  assert.deepEqual(undelivered([{ text: "a", seen: 1 }], [{ input: "a" }]), [{ text: "a", seen: 1 }], "an earlier turn with the same words doesn't count");
});

test("firstTitle: 60 characters at most", () => {
  assert.equal(firstTitle("short"), "short");
  assert.equal(firstTitle("x".repeat(70)), "x".repeat(57) + "…");
});

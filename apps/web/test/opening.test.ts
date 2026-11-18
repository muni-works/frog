// A new session's start on the live row (LiveRow.tsx `LiveTail` given `start`, its words from
// ui/Opening.tsx): the transcript spec's motion rule for a changing line (nothing for 600 ms, a
// cross-fade, at most one change per 1.2 s), the thinking row's clock (from the first second, the
// line's height kept before it), the hand-over to the turn's own row in place, and the helpers App
// uses to keep one view from Send to the first turn.
import { after, before, mock, test } from "node:test";
import assert from "node:assert/strict";
import { createElement as h } from "react";
import TestRenderer, { act } from "react-test-renderer";
import { BOOT, STUCK_MS, firstTitle, provisional, startWords, stuck, undelivered, withOpening, type Opening, type StartInfo } from "../src/ui/Opening.tsx";
import { LiveContext, LiveTail, type LiveInfo } from "../src/ui/LiveRow.tsx";
import { emptyThread } from "../src/engine/thread.ts";
import verbs from "../../../docs/design/transcript/verbs.json" with { type: "json" };

(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

// Once for the file: node 20's mocked setInterval stops firing after a reset and enable.
before(() => mock.timers.enable({ apis: ["setTimeout", "setInterval", "Date"] }));
after(() => mock.timers.reset());

type R = TestRenderer.ReactTestRenderer;
type I = TestRenderer.ReactTestInstance;
const text = (n: I | string): string => typeof n === "string" ? n : n.children.map(text).join("");
// In steps: one long tick doesn't run node's mocked setInterval for every period it covers.
const advance = async (ms: number) => { for (let left = ms; left > 0; left -= 250) await act(() => { mock.timers.tick(Math.min(250, left)); }); };
const cls = (c: RegExp) => (n: I) => typeof n.props.className === "string" && c.test(n.props.className);
const rowOf = (r: R) => r.root.find((n) => n.type === "div" && n.props["data-row"] === "live");
const layers = (r: R) => r.root.findAll((n) => n.type === "span" && cls(/^tf\b/)(n)).map((n) => [n.props.className as string, text(n)]);
/** The words as shown: the layer fading in, or the plain label. */
const words = (r: R) => {
  const now = r.root.findAll((n) => n.type === "span" && cls(/^tf( tf-now)?$/)(n));
  return now.length ? text(now[now.length - 1]) : text(r.root.find((n) => n.type === "span" && n.props.className === "live-label"));
};
const stats = (r: R) => r.root.findAll((n) => n.type === "div" && n.props.className === "live-stats");
const clock = (r: R): string | null => { const f = r.root.findAll((n) => n.type === "span" && n.props.className === "live-figures"); return f.length ? text(f[0]) : null; };
const node = (n: I) => (n as unknown as { _fiber: { stateNode: unknown } })._fiber.stateNode;
const INFO = (over: Partial<LiveInfo> = {}): LiveInfo => ({ startedAt: Date.now(), live: null, pulse: 0, firstOutputAt: null, askedAt: null, activity: null, waitingElsewhere: false, ...over });
const tail = (start: StartInfo | undefined, info = INFO()) => h(LiveContext.Provider, { value: info }, h(LiveTail, { entries: [], waiting: false, start }));
const at = (over: Partial<StartInfo> = {}): StartInfo => ({ since: Date.now(), stage: "reserving", ...over });

test("nothing for the first 600 ms (its height is kept), then the start's first stage", async () => {
  let r!: R;
  await act(() => { r = TestRenderer.create(tail(at())); });
  assert.equal(rowOf(r).props["data-ready"], "false");
  assert.equal(rowOf(r).props["data-kind"], "start");
  assert.equal(words(r), "Reserving a sandbox");
  assert.equal(stats(r).length, 1, "the stats line is there from the start, so nothing moves when the time shows");
  await advance(500);
  assert.equal(rowOf(r).props["data-ready"], "false");
  await advance(250);
  assert.equal(rowOf(r).props["data-ready"], undefined);
  r.unmount();
});

test("the stats line carries the time from the first second, as the thinking row's does", async () => {
  let r!: R;
  await act(() => { r = TestRenderer.create(tail(at({ stage: "booting", repo: "ecto/pond" }))); });
  assert.equal(clock(r), null);
  await advance(1250);
  assert.equal(clock(r), "1s");
  assert.equal(words(r), "Booting it and cloning ecto/pond");
  assert.ok(!JSON.stringify(r.toJSON()).includes("tokens"), "no tokens or speed before the model starts");
  r.unmount();
});

test("stages replace each other in place: at most one change per 1.2 s, cross-fading", async () => {
  const s = at();
  let r!: R;
  await act(() => { r = TestRenderer.create(tail(s)); });
  await advance(300);
  await act(() => { r.update(tail({ ...s, stage: "booting" })); });
  await advance(600);
  assert.equal(words(r), "Reserving a sandbox", "held: under 1.2 s since it showed");
  await advance(400);
  assert.deepEqual(layers(r), [["tf tf-was", "Reserving a sandbox"], ["tf tf-now", "Booting it"]]);
  await act(() => { r.update(tail({ ...s, stage: "engine" })); });
  await advance(1300);
  assert.equal(words(r), "Starting Frog");
  assert.equal(r.root.findAll((n) => n.type === "li" || n.type === "svg").length, 0, "no list, no ticks");
  r.unmount();
});

test("a stage that fails turns the row into the error with Try again, in place", async () => {
  const s = at({ stage: "booting" });
  let r!: R;
  let tries = 0;
  await act(() => { r = TestRenderer.create(tail(s)); });
  await advance(2000);
  await act(() => { r.update(tail({ ...s, error: "Couldn't clone ecto/pond.", onRetry: () => { tries++; } })); });
  await advance(1300);
  assert.equal(words(r), "Failed Couldn't clone ecto/pond.");
  assert.equal(rowOf(r).props["data-state"], "failed");
  assert.equal(clock(r), null, "no clock on a failure");
  const again = r.root.find((n) => n.type === "button" && text(n) === BOOT.retry);
  await act(() => { (again.props.onClick as () => void)(); });
  assert.equal(tries, 1);
  r.unmount();
});

test("up 30 s with no turn: the row says Frog didn't pick it up", async () => {
  const s = at({ stage: "engine" });
  let r!: R;
  await act(() => { r = TestRenderer.create(tail({ ...s, upSince: s.since + 8000, onRetry: () => {} })); });
  await advance(8000 + STUCK_MS - 500);
  assert.equal(words(r), "Starting Frog");
  await advance(1500);
  assert.equal(words(r), "Failed Frog didn't pick this up.");
  r.unmount();
});

test("the first turn takes over the same row: no new node, the words cross-fade, the height holds", async () => {
  let r!: R;
  await act(() => { r = TestRenderer.create(tail(at({ stage: "engine" }))); });
  await advance(3000);
  const row = node(rowOf(r));
  await act(() => { r.update(tail(undefined, INFO({ startedAt: Date.now() }))); });
  await advance(50);
  assert.equal(node(rowOf(r)), row, "the same row");
  assert.deepEqual(layers(r).slice(0, 2), [["tf tf-was", "Starting Frog"], ["tf tf-now", "Thinking"]]);
  assert.equal(stats(r).length, 1, "the stats line holds its height in the turn's first second");
  assert.equal(rowOf(r).props["data-kind"], "thinking");
  await advance(500);
  assert.equal(layers(r).length, 0, "nothing of the start is left");
  assert.equal(words(r), "Thinking", "then it is the plain live row");
  r.unmount();
});

test("shown once, Try again's new clock doesn't hide it again", async () => {
  let r!: R;
  await act(() => { r = TestRenderer.create(tail(at({ error: "x", onRetry: () => {} }))); });
  await advance(2000);
  assert.equal(rowOf(r).props["data-ready"], undefined);
  await act(() => { r.update(tail(at())); });
  assert.equal(rowOf(r).props["data-ready"], undefined);
  r.unmount();
});

test("the words are the shared verb table's start section, word for word", () => {
  const t = verbs.start;
  assert.equal(startWords({ stage: "reserving" }).verb, t.reserving);
  assert.equal(startWords({ stage: "booting" }).verb, t.booting);
  assert.equal(startWords({ stage: "booting", repo: "ecto/pond" }).verb, t.cloning.replace("{repo}", "ecto/pond"));
  assert.equal(startWords({ stage: "engine" }).verb, t.engine);
  assert.equal(startWords({ stage: "booting", error: "x" }).verb, t.failed);
  assert.equal(startWords({ stage: "engine", upSince: 0 }, STUCK_MS).object, t.stuck);
  assert.equal(BOOT.retry, t.retry);
});

test("words: each stage, Failed with the reason, and the 30 s rule", () => {
  assert.deepEqual(startWords({ stage: "reserving" }), { verb: "Reserving a sandbox", object: "", failed: false });
  assert.deepEqual(startWords({ stage: "booting" }), { verb: "Booting it", object: "", failed: false });
  assert.deepEqual(startWords({ stage: "booting", repo: "ecto/pond" }), { verb: "Booting it and cloning ecto/pond", object: "", failed: false });
  assert.deepEqual(startWords({ stage: "engine" }), { verb: "Starting Frog", object: "", failed: false });
  assert.deepEqual(startWords({ stage: "booting", error: "No access." }), { verb: "Failed", object: "No access.", failed: true });
  assert.equal(startWords({ stage: "engine", upSince: 0 }, STUCK_MS).object, "Frog didn't pick this up.");
});

test("stuck: up for 30 s with no turn and no other failure", () => {
  const o = op({ runningAt: 0 });
  assert.equal(stuck(o, STUCK_MS - 1), false);
  assert.equal(stuck(o, STUCK_MS), true);
  assert.equal(stuck({ ...o, failed: "x" }, STUCK_MS), false, "a failure already says why");
  assert.equal(stuck(op(), 10 * STUCK_MS), false, "not up yet");
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

// The web-app audit's fixes (connection, state, ring, keyboard, streaming markdown), one test each.
import { after, before, test } from "node:test";
import assert from "node:assert/strict";
import WebSocket from "ws";
import { startMock } from "./mock/mock-gateway.mjs";
import { AUTH_PROBE_AFTER, Gateway, type ConnectionState } from "../src/cloud/client.ts";
import type { Envelope } from "../src/cloud/protocol.ts";
import { diffIds, once } from "../src/live.ts";
import { barTone, ringTone } from "../src/usage.ts";
import { escape, nextIndex, pushLayer, trapIndex } from "../src/ui/layers.ts";
import { parse, parseStreaming, stableCut } from "../src/ui/Markdown.tsx";

let mock: Awaited<ReturnType<typeof startMock>>;
before(async () => (mock = await startMock({ port: 0, delayMs: 1 })));
after(() => mock.close());

const until = async (pred: () => boolean, what: string, ms = 4000) => {
  const deadline = Date.now() + ms;
  while (!pred()) {
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await new Promise((r) => setTimeout(r, 20));
  }
};

/** A scripted socket: the test plays the gateway. */
class FakeWS {
  static all: FakeWS[] = [];
  sent: any[] = [];
  onopen: (() => void) | null = null;
  onmessage: ((m: { data: string }) => void) | null = null;
  onclose: ((e: { code: number; reason: string }) => void) | null = null;
  closed = false;
  constructor(readonly url: string) {
    FakeWS.all.push(this);
    queueMicrotask(() => this.onopen?.());
  }
  send(d: string) { this.sent.push(JSON.parse(d)); }
  close(code = 1000, reason = "") {
    if (this.closed) return;
    this.closed = true;
    queueMicrotask(() => this.onclose?.({ code, reason }));
  }
  /** The gateway says something. */
  say(v: unknown) { this.onmessage?.({ data: JSON.stringify(v) }); }
  get hello() { return this.sent.find((x) => x.hello)?.hello; }
  get submits() { return this.sent.filter((x) => x.op === "submit").map((x) => x.text); }
}
const last = () => FakeWS.all[FakeWS.all.length - 1];
const env = (seq: number, e: object) => ({ seq, session: "s", created: seq, ...e });
const fake = (fetch?: typeof globalThis.fetch) =>
  new Gateway({ origin: "http://gw.test", token: "t", WebSocket: FakeWS as any, fetch: fetch ?? (async () => new Response("{}")) });

// 1. Expired token
test("auth: a socket that keeps failing asks the gateway, and a 401 there stops the reconnects", async () => {
  let signedOut = 0;
  const gw = new Gateway({ origin: `http://127.0.0.1:${mock.port}`, token: "acct-x", WebSocket: WebSocket as any });
  const { id } = await gw.create({ repo: "ecto/frog" });
  // Same session, a token the gateway no longer takes: the upgrade fails like a network drop.
  const bad = new Gateway({ origin: gw.origin, token: "", WebSocket: WebSocket as any, onUnauthorized: () => signedOut++ });
  const states: ConnectionState[] = [];
  const conn = bad.connect(id, { onEnvelope: () => {}, onState: (s) => states.push(s) });
  await until(() => states.some((s) => s.state === "unauthorized"), "unauthorized");
  assert.ok(signedOut >= 1, "the app hears about it");
  const n = states.length;
  await new Promise((r) => setTimeout(r, 600));
  assert.equal(states.length, n, "no reconnects after");
  assert.ok(states.filter((s) => s.state === "connecting" && s.attempt > 0).length >= AUTH_PROBE_AFTER);
  conn.close();
});

test("auth: a 401 from any route tells the app to sign out", async () => {
  let signedOut = 0;
  const gw = new Gateway({ origin: `http://127.0.0.1:${mock.port}`, token: "", onUnauthorized: () => signedOut++ });
  await assert.rejects(gw.list(), { status: 401 });
  assert.equal(signedOut, 1);
});

// 2. Muted sessions
test("seq: a restarted log (first envelope at or below ours) resets the thread and replays it all", async () => {
  FakeWS.all = [];
  let resets = 0;
  const got: number[] = [];
  const conn = fake().connect("s", { onEnvelope: (e: Envelope) => got.push(e.seq), onReset: () => resets++ }, 40);
  await until(() => !!last()?.hello, "hello");
  assert.equal(last().hello.resume_after, 40);
  last().say({ welcome: { protocol: 1, session: "s", engine: "x", last_seq: 3 } });
  last().say(env(3, { event: "idle" }));
  await until(() => FakeWS.all.length === 2 && !!last().hello, "a fresh socket");
  assert.equal(resets, 1);
  assert.equal(last().hello.resume_after, 0);
  last().say({ welcome: { protocol: 1, session: "s", engine: "x", last_seq: 3 } });
  for (const s of [1, 2, 3]) last().say(env(s, { event: "idle" }));
  assert.deepEqual(got, [1, 2, 3]);
  conn.close();
});

test("seq: a welcome whose last_seq is below ours (only kept envelopes counted) is not a restart", async () => {
  FakeWS.all = [];
  let resets = 0;
  const got: number[] = [];
  const conn = fake().connect("s", { onEnvelope: (e: Envelope) => got.push(e.seq), onReset: () => resets++ }, 40);
  await until(() => !!last()?.hello, "hello");
  last().say({ welcome: { protocol: 1, session: "s", engine: "x", last_seq: 30 } });
  last().say(env(41, { event: "idle" }));
  assert.equal(resets, 0);
  assert.deepEqual(got, [41]);
  conn.close();
});

test("seq: without last_seq, a first envelope at or below what we'd seen means a restart", async () => {
  FakeWS.all = [];
  let resets = 0;
  const conn = fake().connect("s", { onEnvelope: () => {}, onReset: () => resets++ }, 40);
  await until(() => !!last()?.hello, "hello");
  last().say({ welcome: { protocol: 1, session: "s", engine: "x" } });
  last().say(env(1, { event: "idle" }));
  await until(() => FakeWS.all.length === 2 && !!last().hello, "a fresh socket");
  assert.equal(resets, 1);
  assert.equal(last().hello.resume_after, 0);
  conn.close();
});

// 3. Lost sends
test("sends: a submit the dying socket ate goes again after the reconnect, once", async () => {
  FakeWS.all = [];
  const conn = fake().connect("s", { onEnvelope: () => {} }, 0);
  await until(() => !!last()?.hello, "hello");
  last().say({ welcome: { protocol: 1, session: "s", engine: "x", last_seq: 0 } });
  conn.send({ op: "submit", text: "lost" });
  conn.send({ op: "submit", text: "delivered" });
  assert.deepEqual(last().submits, ["lost", "delivered"]);
  last().close(1006);
  await until(() => FakeWS.all.length === 2 && !!last().hello, "reconnect");
  // The gateway had received "delivered" and started it; "lost" never arrived.
  last().say({ welcome: { protocol: 1, session: "s", engine: "x", last_seq: 1 } });
  assert.deepEqual(last().submits, [], "nothing goes before the replay is in");
  last().say(env(1, { event: "turn_started", turn: 1, input: "delivered" }));
  assert.deepEqual(last().submits, ["lost"]);
  // Once it starts, it isn't sent again on the next reconnect.
  last().say(env(2, { event: "turn_started", turn: 2, input: "lost" }));
  last().close(1006);
  await until(() => FakeWS.all.length === 3 && !!last().hello, "reconnect");
  last().say({ welcome: { protocol: 1, session: "s", engine: "x", last_seq: 2 } });
  assert.deepEqual(last().submits, []);
  conn.close();
});

// 4. Reconnect churn
test("live set: only the sessions that changed open or close", () => {
  assert.deepEqual(diffIds(["a", "b"], ["b", "c"]), { add: ["c"], drop: ["a"] });
  assert.deepEqual(diffIds(["a"], ["a"]), { add: [], drop: [] });
  assert.deepEqual(diffIds([], ["a", "a"]), { add: ["a"], drop: [] });
});

// 5. Queue race
test("queue: a batch is submitted once however often the effect runs", () => {
  const fresh = once<object>();
  const q = [{ text: "x" }];
  assert.equal(fresh(q), true);
  assert.equal(fresh(q), false);
  assert.equal(fresh([{ text: "x" }]), true, "a new batch is new");
});

// 7. Ring
test("ring: red only past the plan or a full context, the notice colour past 80%", () => {
  assert.equal(ringTone(0.5, 0.2, false), "var(--muted)");
  assert.equal(ringTone(0.85, 0, false), "var(--notice)");
  assert.equal(ringTone(0, 0.9, false), "var(--notice)");
  assert.equal(ringTone(1, 0, false), "var(--warn)");
  assert.equal(ringTone(0, 1, false), "var(--warn)");
  assert.equal(ringTone(0.1, 0, true), "var(--warn)");
  for (const x of [0.5, 0.85, 1]) assert.equal(ringTone(x, 0, false) === "var(--warn)", barTone(x) === "var(--warn)");
  assert.equal(barTone(0.85), "var(--notice)");
});

// 8. Streaming markdown
const samples = [
  "# Title\n\nSome *text*.\n\n```py\nprint(1)\n\nprint(2)\n```\n\n- a\n- b\n\n1. one\n2. two\n\n> quoted\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\nend",
  "para one\nstill one\n\n~~~\ncode\n\n~~~ \n\n\n- x\n  more x\n\ntail",
  "```\nnever closed\n\nstill code",
];
test("markdown: the cut is safe, and streaming parses match a full parse at every length", () => {
  for (const s of samples) {
    const cache = { head: "", blocks: [] as ReturnType<typeof parse> };
    for (let n = 0; n <= s.length; n++) {
      const src = s.slice(0, n);
      const cut = stableCut(src);
      assert.deepEqual([...parse(src.slice(0, cut)), ...parse(src.slice(cut))], parse(src), `cut ${cut} of ${JSON.stringify(src)}`);
      assert.deepEqual(parseStreaming(src, cache), parse(src), JSON.stringify(src));
    }
  }
  assert.equal(stableCut("```\na\n\nb"), 0, "never inside a fence");
});

// 9. Keyboard
test("layers: one Escape closes only the top layer", () => {
  const closed: string[] = [];
  const offA = pushLayer(() => closed.push("menu"));
  const offB = pushLayer(() => closed.push("popover"));
  let stopped = 0;
  const key = (k: string) => ({ key: k, preventDefault() {}, stopPropagation() { stopped++; } });
  assert.equal(escape(key("Escape")), true);
  assert.deepEqual(closed, ["popover"]);
  assert.equal(stopped, 1, "nothing underneath (the composer's interrupt) sees it");
  offB();
  escape(key("Escape"));
  assert.deepEqual(closed, ["popover", "menu"]);
  offA();
  assert.equal(escape(key("Escape")), false, "no layer: the key goes on");
  assert.equal(escape(key("a")), false);
});

test("menus: arrows wrap, Home and End jump; Tab cycles inside a trap", () => {
  assert.equal(nextIndex("ArrowDown", -1, 3), 0);
  assert.equal(nextIndex("ArrowDown", 2, 3), 0);
  assert.equal(nextIndex("ArrowUp", 0, 3), 2);
  assert.equal(nextIndex("Home", 2, 3), 0);
  assert.equal(nextIndex("End", 0, 3), 2);
  assert.equal(nextIndex("a", 0, 3), -1);
  assert.equal(trapIndex(2, 3, false), 0);
  assert.equal(trapIndex(1, 3, false), -1);
  assert.equal(trapIndex(0, 3, true), 2);
  assert.equal(trapIndex(-1, 3, false), 0);
});

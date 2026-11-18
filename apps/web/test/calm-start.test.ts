// A new session from Send to its first turn is one steady view (ui/Opening.tsx). Each test here is
// one flash seen against the slow mock (test/mock, --boot-ms/--create-ms/--welcome-ms), checked
// on the whole App (test/app-harness.ts) with the POST held open and a fake socket:
//   - the sent message was three different nodes (App's placeholder, the outbox's, the turn's)
//   - the composer remounted when the id arrived, dropping what you were typing
//   - a list refresh during the POST dropped the placeholder: "Session not found", no composer
//   - the title flipped from your message to "New session" when the id arrived
//   - two status lines ("Sending · …" over a three-step list) that moved, and "Frog is starting
//     on it" when the socket went live, which zest does before the sandbox has booted
//   - a failed boot hid the message and put a Delete banner in its place; a failed POST bounced
//     back to the new-session page
//   - a follow-up sent during the POST was queued under the placeholder's id and never sent
//   - a delivered message was drawn twice for a commit (the outbox was pruned in an effect)
//   - a repo session's title flipped from your message to the repo's name

import { after, test } from "node:test";
import assert from "node:assert/strict";
import { act, closeHarness, dispatch, find, hasClass, mount, shownText, type HostNode, type OnCommit, type Page } from "./app-harness.ts";

after(closeHarness);

const ME = { account: { plan: "free", name: "Ada Lovelace", handle: null, image: null, google: null, email: "ada@example.com", credit_cents: 1278, resets_at: null, subscription: null } };
const ID = "s_0123456789abcdef0123";
const summary = (over: Record<string, unknown> = {}) => ({ id: ID, title: "New session", repo: "", branch: "", state: "starting", updated: Date.now(), ...over });

/** A websocket that welcomes when told to and lets the test push the engine's envelopes. */
class FakeWS {
  static all: FakeWS[] = [];
  onopen: (() => void) | null = null;
  onmessage: ((m: { data: string }) => void) | null = null;
  onclose: ((e: { code: number; reason: string }) => void) | null = null;
  onerror: (() => void) | null = null;
  sent: Record<string, unknown>[] = [];
  seq = 0;
  constructor(public url: string) { FakeWS.all.push(this); setTimeout(() => this.onopen?.(), 0); }
  send(t: string) { this.sent.push(JSON.parse(t)); }
  close() {}
  welcome() { this.onmessage?.({ data: JSON.stringify({ welcome: { protocol: 1, session: ID, engine: "fake", last_seq: 0 } }) }); }
  emit(ev: Record<string, unknown>) { this.onmessage?.({ data: JSON.stringify({ seq: ++this.seq, created: Date.now(), ...ev }) }); }
}

const tick = (ms = 20) => act(async () => { await new Promise((r) => setTimeout(r, ms)); });

interface World { p: Page; answer: (r: { status?: number; body: unknown }) => Promise<void>; list: Record<string, unknown>[]; state: { s: Record<string, unknown> }; posts: () => number }

/** Signed in on the new-session page, with POST /v1/sessions held until `answer`. */
async function world(onCommit?: OnCommit): Promise<World> {
  FakeWS.all = [];
  const list: Record<string, unknown>[] = [];
  const state = { s: summary() };
  let release: ((r: { status?: number; body: unknown }) => void) | null = null;
  let posts = 0;
  const p = await mount("/", {
    storage: { "frog.key": "frog_test" },
    globals: { WebSocket: FakeWS },
    onCommit,
    concurrent: true,
    respond: (url, init) => {
      const path = new URL(url, "https://frog.toys").pathname;
      const method = init.method ?? "GET";
      if (path === "/v1/me") return { body: ME };
      if (path === "/v1/sessions" && method === "GET") return { body: { sessions: list, preview: false } };
      if (path === "/v1/sessions" && method === "POST") { posts++; return new Promise((r) => { release = r; }); }
      if (path.startsWith("/v1/sessions/") && method === "GET") return { body: state.s };
      if (path.startsWith("/v1/sessions/") && method === "DELETE") return { status: 204, body: null };
      return undefined;
    },
  });
  // Answered, the session is in the gateway's list too, as zest's index has it.
  const answer = async (r: { status?: number; body: unknown }) => {
    if ((r.status ?? 200) < 300 && !list.some((x) => x.id === ID)) list.push(summary());
    await act(async () => { release?.(r); release = null; });
    await tick();
  };
  return { p, answer, list, state, posts: () => posts };
}

const box = (p: Page) => find(p, (n) => n.type === "textarea");
async function type(p: Page, text: string) {
  const t = box(p)!;
  await act(async () => { (t.props.onChange as (e: unknown) => void)({ target: { value: text, style: {}, scrollHeight: 20 } }); });
}
async function enter(p: Page) {
  const t = box(p)!;
  await act(async () => { (t.props.onKeyDown as (e: unknown) => void)({ key: "Enter", shiftKey: false, metaKey: false, ctrlKey: false, nativeEvent: { isComposing: false }, preventDefault() {} }); });
  await tick();
}
const bubbles = (p: Page) => find(p, hasClass("tx")) ? (p.root.root.findAll((n) => n.type === "div" && typeof n.props.className === "string" && n.props.className.split(/\s+/).includes("me")) as unknown as HostNode[]) : [];
/** The host node itself (the renderer's instance, one per mount). `.instance` won't do: for a host
 * element it is a fresh createNodeMock object on every read. */
const inst = (n: HostNode | undefined) => (n as unknown as { _fiber: { stateNode: unknown } } | undefined)?._fiber.stateNode;
const statusRows = (p: Page) => (p.root.root.findAll((n) => typeof n.type === "string" && n.props.role === "status") as unknown as HostNode[])
  .filter((n) => !hasClass("dock")(n)).map((n) => shownText(n)).filter(Boolean);

test("the sent message is one node from Send, through the session's id, to its first turn", async () => {
  const w = await world();
  await type(w.p, "Make a tiny pomodoro timer");
  await enter(w.p);
  const first = bubbles(w.p);
  assert.equal(first.length, 1, "the message shows at once");
  const node = inst(first[0]);
  await w.answer({ status: 201, body: { ...summary(), ws: "wss://x" } });
  assert.equal(bubbles(w.p).length, 1);
  assert.equal(inst(bubbles(w.p)[0]), node, "the same node once the id is in");
  const ws = FakeWS.all.at(-1)!;
  await act(async () => { ws.welcome(); });
  await tick();
  assert.equal(inst(bubbles(w.p)[0]), node, "the same node once the socket is live");
  await act(async () => { ws.emit({ event: "turn_started", turn: 1, input: "Make a tiny pomodoro timer" }); });
  await tick(40);
  assert.equal(bubbles(w.p).length, 1, "one bubble when the turn starts");
  assert.equal(inst(bubbles(w.p)[0]), node, "the same node when the first turn starts");
  w.p.unmount();
});

test("the composer stays the same, with what you're typing, when the id arrives", async () => {
  const w = await world();
  await type(w.p, "Make a tiny pomodoro timer");
  await enter(w.p);
  await type(w.p, "and a sou");
  const before = inst(box(w.p));
  await w.answer({ status: 201, body: { ...summary(), ws: "wss://x" } });
  assert.equal(inst(box(w.p)), before, "not remounted");
  assert.equal(box(w.p)!.props.value, "and a sou", "what you typed is still there");
  w.p.unmount();
});

test("a list refresh while the POST is out keeps the new session on screen", async () => {
  const w = await world();
  await type(w.p, "Make a tiny pomodoro timer");
  await enter(w.p);
  const node = inst(bubbles(w.p)[0]);
  // Window focus refreshes the list; the gateway doesn't have the session yet.
  await act(async () => { dispatch("focus", {}); });
  await tick();
  assert.ok(!statusRows(w.p).some((t) => /not found/i.test(t)) && !shownText(w.p.root.root as unknown as HostNode).includes("Session not found"), "no Session not found");
  assert.equal(inst(bubbles(w.p)[0]), node, "the message is still there, the same node");
  assert.ok(box(w.p), "the composer is still there");
  await w.answer({ status: 201, body: { ...summary(), ws: "wss://x" } });
  // And a refresh that left before the POST answered can't drop the real one either.
  await act(async () => { dispatch("focus", {}); });
  await tick();
  assert.equal(inst(bubbles(w.p)[0]), node);
  w.p.unmount();
});

test("the title stays your message when the gateway lists the session as New session", async () => {
  const w = await world();
  await type(w.p, "Make a tiny pomodoro timer");
  await enter(w.p);
  const title = () => shownText(find(w.p, (n) => n.type === "b" && shownText(n).length > 0 && (n.props.title === "Double-click to rename"))!);
  assert.equal(title(), "Make a tiny pomodoro timer");
  await w.answer({ status: 201, body: { ...summary(), ws: "wss://x" } });
  await act(async () => { dispatch("focus", {}); });
  await tick();
  assert.equal(title(), "Make a tiny pomodoro timer");
  w.p.unmount();
});

test("one status row, the live row, its words following what the gateway says", async () => {
  const w = await world();
  await type(w.p, "Make a tiny pomodoro timer");
  await enter(w.p);
  const rows = () => statusRows(w.p).filter((t) => !/^(Make a tiny|Ada)/.test(t));
  /** The row's words as shown (the layer fading in, not the one fading out). */
  const said = () => { const l = w.p.root.root.findAll((n) => n.type === "span" && typeof n.props.className === "string" && /^tf( tf-now)?$/.test(n.props.className)); return l.length ? shownText(l[l.length - 1] as unknown as HostNode) : ""; };
  assert.equal(rows().length, 1, "one row before the id");
  assert.equal(said(), "Reserving a sandbox");
  await w.answer({ status: 201, body: { ...summary(), ws: "wss://x" } });
  await tick(1300);
  assert.equal(rows().length, 1, "still one row after the id: no Sending line");
  assert.equal(said(), "Booting it");
  await act(async () => { FakeWS.all.at(-1)!.welcome(); });
  await tick(1300);
  // zest welcomes before wake() is done: a live socket is not a booted sandbox.
  assert.equal(said(), "Booting it", "a live socket changes nothing");
  assert.ok(!shownText(w.p.root.root as unknown as HostNode).includes("Connecting"), "no Connecting… in the title bar");
  w.list.splice(0, w.list.length, summary({ state: "running" }));
  w.state.s = summary({ state: "running" });
  await act(async () => { dispatch("focus", {}); });
  await tick(1300);
  assert.equal(said(), "Starting Frog", "running: the engine is up, the turn is next");
  assert.ok(!shownText(w.p.root.root as unknown as HostNode).includes("starting the sandbox"), "nothing under the bubble says it again");
  w.p.unmount();
});

test("a boot that fails turns the row into the error, in place, and Try again starts over there", async () => {
  const w = await world();
  await type(w.p, "Fix the flaky test");
  await enter(w.p);
  await w.answer({ status: 201, body: { ...summary(), ws: "wss://x" } });
  const node = inst(bubbles(w.p)[0]);
  const composer = inst(box(w.p));
  w.list.splice(0, w.list.length, summary({ state: "error", error: "Couldn't clone ecto/pond: the repository wasn't found." }));
  await act(async () => { dispatch("focus", {}); });
  await tick(1300); // the row changes at most once every 1.2 s
  assert.equal(inst(bubbles(w.p)[0]), node, "the message stays");
  assert.ok(statusRows(w.p).some((t) => t.includes("Failed Couldn't clone ecto/pond")), statusRows(w.p).join(" | "));
  assert.ok(!find(w.p, hasClass("banner")), "no banner under it");
  const again = find(w.p, (n) => n.type === "button" && shownText(n) === "Try again");
  assert.ok(again, "Try again");
  const before = w.posts();
  await act(async () => { (again!.props.onClick as () => void)(); });
  await tick();
  assert.equal(w.posts(), before + 1, "a new sandbox is asked for");
  assert.equal(inst(bubbles(w.p)[0]), node, "the same message node");
  assert.equal(inst(box(w.p)), composer, "the same composer");
  w.p.unmount();
});

test("a POST that fails says so in place, with the message still there", async () => {
  const w = await world();
  await type(w.p, "Fix the flaky test");
  await enter(w.p);
  const node = inst(bubbles(w.p)[0]);
  await w.answer({ status: 503, body: { error: "Frog Cloud is busy." } });
  await tick(1300);
  assert.equal(bubbles(w.p).length, 1, "still in the session, not back on the new-session page");
  assert.equal(inst(bubbles(w.p)[0]), node);
  assert.ok(statusRows(w.p).some((t) => t.includes("Failed Couldn't start a sandbox")), statusRows(w.p).join(" | "));
  w.p.unmount();
});

test("a follow-up sent while the POST is out goes after the first turn", async () => {
  const w = await world();
  await type(w.p, "Make a tiny pomodoro timer");
  await enter(w.p);
  await type(w.p, "and a sound");
  await enter(w.p);
  await w.answer({ status: 201, body: { ...summary(), ws: "wss://x" } });
  const ws = FakeWS.all.at(-1)!;
  await act(async () => { ws.welcome(); });
  await tick();
  await act(async () => { ws.emit({ event: "turn_started", turn: 1, input: "Make a tiny pomodoro timer" }); });
  await tick(40);
  await act(async () => { ws.emit({ event: "turn_ended", turn: 1, reason: { type: "complete" } }); });
  await tick(40);
  const submits = ws.sent.filter((o) => o.op === "submit").map((o) => o.text);
  assert.deepEqual(submits, ["Make a tiny pomodoro timer", "and a sound"]);
  w.p.unmount();
});

test("a message is never drawn twice: it leaves the outbox in the commit its turn shows", async () => {
  let worst = 0;
  const w = await world((root) => {
    const n = root.root.findAll((x) => x.type === "div" && typeof x.props.className === "string" && x.props.className.split(/\s+/).includes("me") && shownText(x as unknown as HostNode).includes("and a sound")).length;
    worst = Math.max(worst, n);
  });
  await type(w.p, "Make a tiny pomodoro timer");
  await enter(w.p);
  await w.answer({ status: 201, body: { ...summary(), ws: "wss://x" } });
  const ws = FakeWS.all.at(-1)!;
  await act(async () => { ws.welcome(); });
  await tick();
  await act(async () => { ws.emit({ event: "turn_started", turn: 1, input: "Make a tiny pomodoro timer" }); });
  await tick(40);
  await act(async () => { ws.emit({ event: "turn_ended", turn: 1, reason: { type: "complete" } }); });
  await tick(40);
  await type(w.p, "and a sound");
  await enter(w.p);
  await act(async () => { ws.emit({ event: "turn_started", turn: 2, input: "and a sound" }); });
  await tick(40);
  assert.equal(worst, 1, "two bubbles for one message in some commit");
  w.p.unmount();
});

test("a repo session: the same message node, composer and title when the id arrives", async () => {
  const w = await world();
  const pick = w.p.root.root.find((n) => typeof n.props.onRepo === "function" && typeof n.props.onSend === "function");
  await act(async () => { (pick.props.onRepo as (r: string) => void)("ecto/pond"); });
  await tick();
  await type(w.p, "Fix the flaky test");
  await enter(w.p);
  const title = () => shownText(find(w.p, (n) => n.type === "b" && n.props.title === "Double-click to rename")!);
  const node = inst(bubbles(w.p)[0]);
  const composer = inst(box(w.p));
  assert.equal(title(), "Fix the flaky test");
  assert.ok(statusRows(w.p).some((t) => t.includes("Reserving a sandbox")), statusRows(w.p).join(" | "));
  // zest titles a repo session with the repo until the engine names it.
  await w.answer({ status: 201, body: { ...summary({ repo: "ecto/pond", title: "ecto/pond", branch: "frog/pond-012345" }), ws: "wss://x" } });
  await act(async () => { dispatch("focus", {}); });
  await tick();
  assert.equal(title(), "Fix the flaky test", "not the repo's name");
  await tick(1300);
  assert.ok(statusRows(w.p).some((t) => t.includes("Booting it and cloning ecto/pond")), statusRows(w.p).join(" | "));
  assert.equal(inst(bubbles(w.p)[0]), node);
  assert.equal(inst(box(w.p)), composer);
  w.p.unmount();
});

test("a failed POST's placeholder can be deleted: it was never on the gateway", async () => {
  const w = await world();
  await type(w.p, "Fix the flaky test");
  await enter(w.p);
  await w.answer({ status: 503, body: { error: "Frog Cloud is busy." } });
  const menu = find(w.p, (n) => n.type === "button" && n.props["aria-label"] === "Session menu");
  await act(async () => { (menu!.props.onClick as () => void)(); });
  const del = find(w.p, (n) => n.type === "button" && shownText(n) === "Delete session");
  await act(async () => { (del!.props.onClick as () => void)(); });
  await tick();
  assert.ok(!w.p.calls.some((c) => c.method === "DELETE"), "no DELETE for an id the gateway never gave");
  assert.equal(bubbles(w.p).length, 0, "gone, back to a new session");
  assert.ok(!shownText(w.p.root.root as unknown as HostNode).includes("Couldn't delete"));
  w.p.unmount();
});

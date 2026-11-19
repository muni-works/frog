// The window controls and the turn rail on the whole App (docs/design/chrome/spec.md, 1 and 2),
// against what the web had before: only an inspector button, which vanished while the inspector
// was open, no ⌥⌘0, no palette button and no rail.
import { after, test } from "node:test";
import assert from "node:assert/strict";
import { act, click, closeHarness, dispatch, find, mount, type HostNode, type Page } from "./app-harness.ts";

after(closeHarness);

const ME = { account: { plan: "free", name: "Ada Lovelace", handle: null, image: null, google: null, email: "ada@example.com", credit_cents: 1278, resets_at: null, subscription: null } };
const ID = "s_0123456789abcdef0123";
const session = { id: ID, title: "Fix flaky upload retry", repo: "", branch: "", state: "running", updated: Date.now() };

class FakeWS {
  static all: FakeWS[] = [];
  onopen: (() => void) | null = null;
  onmessage: ((m: { data: string }) => void) | null = null;
  onclose: ((e: { code: number; reason: string }) => void) | null = null;
  onerror: (() => void) | null = null;
  seq = 0;
  constructor(public url: string) { FakeWS.all.push(this); setTimeout(() => this.onopen?.(), 0); }
  send() {}
  close() {}
  welcome() { this.onmessage?.({ data: JSON.stringify({ welcome: { protocol: 1, session: ID, engine: "fake", last_seq: 0 } }) }); }
  emit(ev: Record<string, unknown>) { this.onmessage?.({ data: JSON.stringify({ seq: ++this.seq, created: Date.now(), ...ev }) }); }
}

const tick = (ms = 30) => act(async () => { await new Promise((r) => setTimeout(r, ms)); });
const labelled = (l: string | RegExp) => (n: HostNode) => typeof n.props["aria-label"] === "string" && (typeof l === "string" ? n.props["aria-label"] === l : l.test(n.props["aria-label"] as string));
const button = (p: Page, l: string) => find(p, (n) => n.type === "button" && labelled(l)(n));

async function open(): Promise<Page> {
  FakeWS.all = [];
  const p = await mount(`/s/${ID}`, {
    storage: { "frog.key": "frog_test" },
    globals: { WebSocket: FakeWS },
    respond: (url) => {
      const path = new URL(url, "https://frog.toys").pathname;
      if (path === "/v1/me") return { body: ME };
      if (path === "/v1/sessions") return { body: { sessions: [session], preview: false } };
      if (path === `/v1/sessions/${ID}`) return { body: session };
      return undefined;
    },
  });
  await tick();
  const ws = FakeWS.all.at(-1);
  assert.ok(ws, "the open session streams");
  await act(async () => { ws.welcome(); });
  await act(async () => { ws.emit({ event: "turn_started", turn: 1, input: "fix the flaky upload retry" }); });
  await tick();
  return p;
}

test("the window controls: one group, Commands then Inspector, no Split on the web", async () => {
  const p = await open();
  const group = find(p, labelled("Window controls"));
  assert.ok(group, "the group is drawn");
  const labels = (group as unknown as { findAll: (f: (n: HostNode) => boolean) => HostNode[] }).findAll((n) => n.type === "button").map((c) => c.props["aria-label"]);
  assert.deepEqual(labels, ["Commands", "Inspector"]);
  assert.equal(button(p, "Commands")!.props.title, "Command palette (⌘K)");
  assert.equal(button(p, "Inspector")!.props.title, "Inspector (⌥⌘0)");
  p.unmount();
});

test("the inspector toggle stays while the inspector is open, and says it's on", async () => {
  const p = await open();
  assert.equal(button(p, "Inspector")!.props["aria-pressed"], false);
  await click(button(p, "Inspector"));
  const on = button(p, "Inspector");
  assert.ok(on, "still there with the inspector open");
  assert.equal(on!.props["aria-pressed"], true);
  assert.ok(find(p, (n) => n.type === "section" && labelled("Inspector")(n)), "the inspector shows");
  await click(on);
  assert.equal(button(p, "Inspector")!.props["aria-pressed"], false);
  p.unmount();
});

test("⌥⌘0 toggles the inspector, as on the Mac", async () => {
  const p = await open();
  // ⌥ turns 0 into º: the key code is what's read.
  await act(async () => { dispatch("keydown", { key: "º", code: "Digit0", metaKey: true, altKey: true }); });
  await tick();
  assert.equal(button(p, "Inspector")!.props["aria-pressed"], true);
  await act(async () => { dispatch("keydown", { key: "º", code: "Digit0", metaKey: true, altKey: true }); });
  await tick();
  assert.equal(button(p, "Inspector")!.props["aria-pressed"], false);
  p.unmount();
});

test("the turn rail shows once the conversation has a turn", async () => {
  const p = await open();
  const rail = find(p, labelled(/^Timeline, 1 turn/));
  assert.ok(rail, "the rail is drawn");
  assert.equal(rail!.props.role, "slider");
  p.unmount();
});

// The header (spec.md, 3): the whole title is the session menu's button, as on the Mac, and
// Rename… edits it in place. Before, the title was bold text with a separate chevron button.
test("the title is the session menu's button, with the Mac's items", async () => {
  const p = await open();
  const b = button(p, "Session menu");
  assert.ok(b, "one button");
  assert.equal(b!.props.title, "Rename, archive or delete this session");
  assert.ok(find(p, (n) => n.type === "b" && n.props.className === "title-text"), "the title is inside it");
  await click(b);
  const items = (p.root.root.findAll((n) => n.type === "button" && n.props.role === "menuitem") as unknown as HostNode[]).map((n) => (n.children as unknown[]).join(""));
  assert.deepEqual(items, ["Rename…", "Archive", "Delete…"]);
  await click(find(p, (n) => n.type === "button" && n.props.role === "menuitem" && (n.children as unknown[]).join("") === "Rename…"));
  const field = find(p, (n) => n.type === "input" && labelled("Session name")(n));
  assert.ok(field, "Rename… puts a field where the title was");
  assert.ok(!button(p, "Session menu"), "in place of the title");
  p.unmount();
});

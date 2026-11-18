// The web Preview pane: PreviewHub against the Mac's behaviour (ToolPanes.swift, PreviewPane.swift),
// the capture script in a stub page, the mock gateway's preview host, and the pane's markup.
import { after, before, test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { request, createServer, type Server } from "node:http";
import { runInNewContext } from "node:vm";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { startMock } from "./mock/mock-gateway.mjs";
import { Gateway } from "../src/cloud/client.ts";
import type { Envelope, Op } from "../src/cloud/protocol.ts";
import { CloudEngine } from "../src/engine/cloud.ts";
import { addressURL, displayAddress, localTarget, NO_SCREENSHOT, PreviewHub, type Frame } from "../src/preview.ts";
import { GatewayError } from "../src/cloud/client.ts";
import { DEVICES, fitDevice } from "../src/ui/PreviewPane.tsx";
import { Inspector } from "../src/ui/Inspector.tsx";

const PREVIEW = "https://abc.frog-preview.dev";

/** A hub with a recording engine, a fake gateway and timers that fire when told. */
function rig(now = { t: 1_000 }) {
  const sent: Op[] = [];
  const minted: number[] = [];
  const timers: (() => void)[] = [];
  const hub = new PreviewHub(
    (op) => sent.push(op),
    async (port) => (minted.push(port), { url: `${PREVIEW}/`, expires: now.t + 8 * 3600_000 }),
    () => now.t,
    (f) => timers.push(f),
  );
  const posted: Record<string, unknown>[] = [];
  const loads: string[] = [];
  const frame: Frame = { post: (m) => posted.push(m), load: (src) => loads.push(src) };
  const ops = (kind: string) => sent.filter((o) => o.op === kind);
  return { hub, sent, minted, timers, frame, posted, loads, ops, now };
}

const settle = () => new Promise((r) => setTimeout(r, 0));
const msg = (m: Record<string, unknown>) => ({ frog: 1, ...m });

test("addresses and sandbox URLs read as the Mac reads them", () => {
  assert.equal(addressURL("5173"), "http://localhost:5173");
  assert.equal(addressURL(":3000/x"), "http://localhost:3000/x");
  assert.equal(addressURL("localhost:8080"), "http://localhost:8080");
  assert.equal(addressURL("https://example.com"), "https://example.com");
  assert.equal(addressURL("  "), null);
  assert.deepEqual(localTarget("http://localhost:5173/a?b=1"), { port: 5173, path: "/a?b=1" });
  assert.deepEqual(localTarget("http://127.0.0.1:3000"), { port: 3000, path: "/" });
  assert.deepEqual(localTarget("http://0.0.0.0:8000/"), { port: 8000, path: "/" });
  assert.equal(localTarget("https://example.com/"), null);
  assert.equal(localTarget("file:///workspace/repo/index.html"), null);
});

test("the address field takes a URL, a bare port or host:port", () => {
  assert.equal(addressURL("3000"), "http://localhost:3000");
  assert.equal(addressURL(" 3000 "), "http://localhost:3000");
  assert.equal(addressURL("127.0.0.1:4321/docs"), "http://127.0.0.1:4321/docs");
  assert.equal(addressURL("example.com/a"), "http://example.com/a");
  assert.equal(addressURL("http://localhost:5173/x?y=1"), "http://localhost:5173/x?y=1");
});

test("the address shows plainly: host and path, the port kept, no scheme or lone slash", () => {
  assert.equal(displayAddress("http://localhost:5173/"), "localhost:5173");
  assert.equal(displayAddress("http://localhost:5173"), "localhost:5173");
  assert.equal(displayAddress("http://localhost:3000/pond?x=1"), "localhost:3000/pond?x=1");
  assert.equal(displayAddress("https://example.com/docs/"), "example.com/docs/");
  assert.equal(displayAddress("about:preview"), "about:preview");
  assert.equal(displayAddress(undefined), "");
});

test("device sizes: Fit fills, the others keep their shape and scale down, never up", () => {
  assert.deepEqual(DEVICES.map((d) => d.label), ["Fit", "Phone", "Tablet", "Desktop"]);
  assert.equal(fitDevice("fit", 400, 500), null);
  assert.deepEqual(fitDevice("phone", 1000, 1000), { width: 390, height: 844, scale: 1 });
  const t = fitDevice("tablet", 400, 500)!;
  assert.ok(t.width <= 400 && t.height <= 500 && Math.abs(t.height / t.width - 1180 / 820) < 1e-9);
  const d = fitDevice("desktop", 400, 500)!;
  assert.equal(d.width, 400);
  assert.equal(fitDevice("phone", 0, 500), null);
});

test("a gateway without previews makes the hub unavailable; one that mints makes it available", async () => {
  const off = new PreviewHub(() => {}, async () => { throw new GatewayError(503, "previews are not configured"); });
  assert.equal(off.available, undefined);
  await off.probe();
  assert.equal(off.available, false);
  const loadOff = new PreviewHub(() => {}, async () => { throw new GatewayError(503, "previews are not configured"); });
  await loadOff.load("p1", "http://localhost:3000/");
  assert.equal(loadOff.available, false);
  // A dead dev server is a failed page, not a missing feature.
  const dead = new PreviewHub(() => {}, async () => { throw new GatewayError(502, "nothing is listening"); });
  await dead.probe();
  assert.equal(dead.available, undefined);
  const { hub, minted } = rig();
  await hub.probe();
  assert.equal(hub.available, true);
  await hub.load("p1", "http://localhost:3000/");
  assert.deepEqual(minted, [3000], "the probe's mint is reused");
});

test("back and forward follow the page's history; stop ends a load", async () => {
  const { hub, frame, posted } = rig();
  hub.attach("p1", frame);
  await hub.load("p1", "http://localhost:5173/");
  const nav = (path: string) => hub.received("p1", msg({ type: "navigated", url: `${PREVIEW}${path}` }));
  nav("/");
  assert.equal(hub.canBack("p1"), false);
  nav("/a");
  nav("/b");
  assert.equal(hub.canBack("p1"), true);
  assert.equal(hub.canForward("p1"), false);
  hub.back("p1");
  assert.deepEqual(posted.at(-1), { frog: 1, type: "back" });
  nav("/a");
  assert.equal(hub.canForward("p1"), true);
  hub.forward("p1");
  assert.deepEqual(posted.at(-1), { frog: 1, type: "forward" });
  nav("/b");
  assert.equal(hub.canForward("p1"), false);
  hub.back("p1"); nav("/a");
  nav("/c");
  assert.equal(hub.canForward("p1"), false, "a new page drops what was ahead");
  hub.reload("p1");
  assert.equal(hub.state("p1").loading, true);
  hub.stop("p1");
  assert.deepEqual(posted.at(-1), { frog: 1, type: "stop" });
  assert.equal(hub.state("p1").loading, false);
  nav("/c");
  assert.equal(hub.canBack("p1"), true, "a reload stays put in history");
  assert.equal(hub.canForward("p1"), false);
});

test("reload of a page outside the sandbox loads it again from here; Frog can't pick on it", async () => {
  const { hub, frame, loads, posted } = rig();
  hub.attach("p1", frame);
  await hub.load("p1", "https://example.com/");
  hub.reload("p1");
  assert.deepEqual(loads, ["https://example.com/", "https://example.com/"]);
  assert.ok(!posted.some((m) => m.type === "reload"));
  assert.equal(hub.drivable("p1"), false);
  await hub.load("p1", "http://localhost:5173/");
  assert.equal(hub.drivable("p1"), true);
});

test("a sandbox URL loads through the gateway's preview host, minted once per port", async () => {
  const { hub, frame, loads, minted } = rig();
  hub.attach("p1", frame, "http://localhost:5173/about?x=1");
  await settle();
  assert.deepEqual(loads, [`${PREVIEW}/about?x=1`]);
  assert.equal(hub.state("p1").url, "http://localhost:5173/about?x=1");
  assert.equal(hub.state("p1").loading, true);
  await hub.load("p1", "http://localhost:5173/");
  assert.deepEqual(minted, [5173]);
  assert.equal(hub.browserURL("p1"), `${PREVIEW}/`);
  hub.loaded("p1");
  assert.equal(hub.state("p1").loading, false);
});

test("what the page says reaches the engine as the Mac's pane_reports, in the sandbox's URLs", async () => {
  const { hub, frame, ops } = rig();
  hub.attach("p1", frame, "http://localhost:3000/");
  await settle();
  hub.received("p1", msg({ type: "navigated", url: `${PREVIEW}/` }));
  hub.received("p1", msg({ type: "console", level: "error", message: "boom", source: "/src/app.js:3:7" }));
  hub.received("p1", msg({ type: "error", message: `TypeError: x is undefined  (${PREVIEW}/src/app.js:3:7)`, url: `${PREVIEW}/` }));
  hub.received("p1", msg({ type: "network", message: `GET ${PREVIEW}/api → 500`, url: `${PREVIEW}/api`, status: 500 }));
  hub.received("p1", msg({ type: "network", message: "GET /x failed: Failed to fetch", url: "/x", status: null }));
  hub.received("p1", msg({ type: "title", message: "Shop" }));
  hub.received("p1", { type: "console", message: "the page's own postMessage" });
  assert.deepEqual(ops("pane_report"), [
    { op: "pane_report", id: "p1", kind: "navigated", message: "http://localhost:3000/", url: "http://localhost:3000/" },
    { op: "pane_report", id: "p1", kind: "console", level: "error", message: "boom  (/src/app.js:3:7)" },
    { op: "pane_report", id: "p1", kind: "error", level: "error", message: "TypeError: x is undefined  (http://localhost:3000/src/app.js:3:7)", url: "http://localhost:3000/" },
    // Byte for byte what the Mac's ProtocolTests pin for a failed request.
    { op: "pane_report", id: "p1", kind: "network", level: "error", message: "GET http://localhost:3000/api → 500", url: "http://localhost:3000/api", status: 500 },
    { op: "pane_report", id: "p1", kind: "network", level: "error", message: "GET /x failed: Failed to fetch", url: "/x" },
    { op: "pane_report", id: "p1", kind: "title", message: "Shop", url: "http://localhost:3000/" },
  ]);
  assert.equal(hub.state("p1").title, "Shop");
});

test("reports are capped at ten a second and a repeat within two seconds is dropped", () => {
  const { hub, ops, now } = rig();
  for (let i = 0; i < 3; i++) hub.report({ id: "p1", kind: "console", level: "warn", message: "same" });
  assert.equal(ops("pane_report").length, 1);
  for (let i = 0; i < 20; i++) hub.report({ id: "p1", kind: "console", level: "info", message: `line ${i}` });
  assert.equal(ops("pane_report").length, 10);
  now.t += 2_500;
  hub.report({ id: "p1", kind: "console", level: "warn", message: "same" });
  assert.equal(ops("pane_report").length, 11);
});

test("a pick in inspect mode sends pane_mention, fills the composer and ends inspecting", async () => {
  const { hub, frame, posted, sent } = rig();
  hub.attach("p1", frame, "http://localhost:3000/");
  await settle();
  hub.setInspecting(true);
  assert.deepEqual(posted.at(-1), { frog: 1, type: "inspect", on: true });
  const context = `tag: button\nrole: button\ntext: "Buy"\nselector: #buy\nbox: 10,20 80×32\npage: ${PREVIEW}/`;
  hub.received("p1", msg({ type: "mention", token: "@#buy", context }));
  assert.deepEqual(sent.at(-1), { op: "pane_mention", id: "p1", mention: "@#buy", context: context.replace(PREVIEW, "http://localhost:3000") });
  assert.deepEqual(hub.insert, { text: "@#buy ", n: 1 });
  assert.equal(hub.inspecting, false);
  assert.deepEqual(posted.at(-1), { frog: 1, type: "inspect", on: false });
  assert.equal(hub.mentionInDraft, true);
  hub.noteDraft("look at this");
  assert.equal(hub.mentionInDraft, false);
  // Esc in the page stops inspecting too.
  hub.setInspecting(true);
  hub.received("p1", msg({ type: "inspect", on: false }));
  assert.equal(hub.inspecting, false);
});

test("the engine's requests get one pane_reply each, as the Mac answers them", async () => {
  const { hub, frame, posted, ops, timers } = rig();
  hub.attach("p1", frame, "http://localhost:3000/");
  await settle();
  hub.loaded("p1");
  hub.report({ id: "p1", kind: "console", level: "error", message: "boom" });

  hub.request({ call: "c1", id: "p1", action: "console" });
  assert.deepEqual(ops("pane_reply").at(-1), { op: "pane_reply", call: "c1", result: [{ kind: "console", level: "error", message: "boom" }] });

  hub.request({ call: "c2", id: "p1", action: "read" });
  const call = posted.at(-1)!;
  assert.equal(call.type, "call");
  assert.equal(call.fn, "read");
  hub.received("p1", msg({ type: "reply", n: call.n, result: "Title: Shop" }));
  assert.deepEqual(ops("pane_reply").at(-1), { op: "pane_reply", call: "c2", result: "Title: Shop" });

  hub.request({ call: "c3", id: "p1", action: "click", args: { selector: "#nope" } });
  hub.received("p1", msg({ type: "reply", n: posted.at(-1)!.n, error: "no element matches #nope" }));
  assert.deepEqual(ops("pane_reply").at(-1), { op: "pane_reply", call: "c3", result: null, error: "no element matches #nope" });

  hub.request({ call: "c4", id: "p1", action: "type" });
  assert.deepEqual(ops("pane_reply").at(-1), { op: "pane_reply", call: "c4", result: null, error: "type needs a selector" });

  const seen = hub.attention;
  hub.request({ call: "c5", id: "p1", action: "screenshot", args: { for: "checkpoint" } });
  assert.deepEqual(ops("pane_reply").at(-1), { op: "pane_reply", call: "c5", result: null, error: NO_SCREENSHOT });
  assert.equal(hub.attention, seen, "a turn's checkpoint doesn't bring the preview forward");

  // Nothing comes back: answered just before the engine's 20s, and only once.
  hub.request({ call: "c6", id: "p1", action: "eval", args: { js: "1" } });
  timers.forEach((f) => f());
  assert.deepEqual(ops("pane_reply").filter((o) => o.op === "pane_reply" && o.call === "c6"), [{ op: "pane_reply", call: "c6", result: null, error: "the preview didn't answer in time" }]);
  assert.equal(ops("pane_reply").length, 6);
  assert.ok(hub.attention > 0);
});

test("the tool's open waits for the load, and a dead dev server is the answer", async () => {
  // The engine opens a pane (pane_opened) and asks navigate {wait}; the iframe mounts after.
  const { hub, frame, ops, loads } = rig();
  hub.request({ call: "n1", id: "p1", action: "navigate", args: { url: "http://localhost:3000/", wait: true } });
  assert.equal(ops("pane_reply").length, 0, "parked until the pane mounts");
  hub.attach("p1", frame, "http://localhost:3000/");
  await settle();
  assert.deepEqual(loads, [`${PREVIEW}/`]);
  hub.received("p1", msg({ type: "title", message: "Home" }));
  hub.loaded("p1");
  assert.deepEqual(ops("pane_reply").at(-1), { op: "pane_reply", call: "n1", result: { url: "http://localhost:3000/", title: "Home", loaded: true } });

  hub.request({ call: "n2", id: "p1", action: "navigate", args: { url: "http://localhost:4000/" } });
  await settle();
  hub.received("p1", msg({ type: "load_failed", message: "Nothing is answering on port 4000 in the sandbox. Is the dev server running?" }));
  hub.loaded("p1");
  assert.deepEqual(ops("pane_reply").at(-1), { op: "pane_reply", call: "n2", result: null, error: "Nothing is answering on port 4000 in the sandbox. Is the dev server running?" });
  assert.deepEqual(ops("pane_report").at(-1), { op: "pane_report", id: "p1", kind: "error", level: "error", message: "Couldn't load: Nothing is answering on port 4000 in the sandbox. Is the dev server running?", url: "http://localhost:4000/" });
  assert.match(hub.state("p1").error ?? "", /port 4000/);

  // A file the engine resolved in the project: the web can't show it, and says how to.
  hub.request({ call: "n3", id: "p1", action: "navigate", args: { url: "file:///workspace/repo/index.html" } });
  await settle();
  assert.match(String((ops("pane_reply").at(-1) as { error?: string }).error), /npx serve/);
});

test("the client tells the engine it hosts preview panes, and routes pane_request to the hub", async () => {
  const sent: unknown[] = [];
  let deliver: ((e: Envelope) => void) | undefined;
  const fake = { connect: (_id: string, h: { onEnvelope: (e: Envelope) => void }) => ((deliver = h.onEnvelope), { send: (op: unknown) => sent.push(op), close() {} }), preview: async () => ({ url: `${PREVIEW}/`, port: 3000, expires: Date.now() + 1e7 }) };
  const engine = new CloudEngine(fake as unknown as Gateway);
  const seen: Envelope[] = [];
  engine.subscribe("s1", 0, (e) => seen.push(e));
  assert.deepEqual(sent[0], { op: "set_client_caps", ask: true, panes: true });
  deliver!({ seq: 9, session: "s1", created: 0, event: "pane_request", call: "c1", id: "p1", action: "console" } as Envelope);
  assert.deepEqual(sent.at(-1), { op: "pane_reply", call: "c1", result: [] });
  assert.equal(seen.length, 1);
  assert.equal(engine.preview("s1"), engine.preview("s1"));
});

// --- the capture script, in a stub page ---------------------------------------------------

function page() {
  const posted: Record<string, unknown>[] = [];
  const listeners: Record<string, ((e: unknown) => void)[]> = {};
  const parent = { postMessage: (m: Record<string, unknown>) => posted.push(JSON.parse(JSON.stringify(m))) };
  const meta: { content?: string } = {};
  const doc = {
    readyState: "complete", title: "Shop", body: { children: [] }, documentElement: { style: {}, appendChild() {} },
    querySelector: (s: string) => (s.startsWith("meta") && meta.content ? { getAttribute: () => meta.content } : null),
    querySelectorAll: () => [], addEventListener() {}, removeEventListener() {}, createElement: () => ({ style: {}, appendChild() {} }),
  };
  const win: Record<string, unknown> = {
    parent, location: { href: "https://abc.frog-preview.dev/", origin: "https://abc.frog-preview.dev" }, document: doc,
    console: { log() {}, info() {}, warn() {}, error() {}, debug() {} },
    addEventListener: (t: string, f: (e: unknown) => void) => ((listeners[t] ??= []).push(f)),
    fetch: async (url: string) => ({ status: url.includes("bad") ? 500 : 200 }),
    XMLHttpRequest: function () {}, MutationObserver: function () { return { observe() {} } },
    history: { back() {} }, Error, JSON, Object, Array, Promise, setTimeout,
  };
  (win.XMLHttpRequest as { prototype: unknown }).prototype = { open() {}, addEventListener() {} };
  win.window = win;
  const run = () => runInNewContext(readFileSync(new URL("../public/preview.js", import.meta.url), "utf8"), win);
  const fire = (t: string, e: unknown) => Promise.all((listeners[t] ?? []).map((f) => f(e)));
  return { win, posted, parent, meta, run, fire };
}

test("the capture script reports the console, failed requests and the page it's on to its parent", async () => {
  const p = page();
  p.run();
  assert.deepEqual(p.posted.find((m) => m.type === "navigated"), { frog: 1, type: "navigated", url: "https://abc.frog-preview.dev/" });
  assert.deepEqual(p.posted.find((m) => m.type === "title"), { frog: 1, type: "title", message: "Shop" });
  (p.win.console as { error(...a: unknown[]): void }).error("boom", { a: 1 });
  const c = p.posted.find((m) => m.type === "console")!;
  assert.equal(c.level, "error");
  assert.equal(c.message, 'boom {"a":1}');
  await (p.win.fetch as (u: string) => Promise<unknown>)("/api/bad");
  assert.deepEqual(p.posted.find((m) => m.type === "network"), { frog: 1, type: "network", message: "GET /api/bad → 500", url: "/api/bad", status: 500 });
  await p.fire("error", { message: "x is undefined", filename: "https://abc.frog-preview.dev/src/a.js", lineno: 3, colno: 7 });
  assert.deepEqual(p.posted.find((m) => m.type === "error"), { frog: 1, type: "error", message: "x is undefined  (/src/a.js:3:7)", url: "https://abc.frog-preview.dev/" });
});

test("the capture script answers its parent's calls, and nobody else's", async () => {
  const p = page();
  p.run();
  await p.fire("message", { source: p.parent, data: { frog: 1, type: "call", n: 1, fn: "eval", js: "6 * 7" } });
  assert.deepEqual(p.posted.at(-1), { frog: 1, type: "reply", n: 1, result: 42 });
  await p.fire("message", { source: p.parent, data: { frog: 1, type: "call", n: 2, fn: "eval", js: "Promise.resolve({ ok: true })" } });
  assert.deepEqual(p.posted.at(-1), { frog: 1, type: "reply", n: 2, result: { ok: true } });
  await p.fire("message", { source: p.parent, data: { frog: 1, type: "call", n: 3, fn: "eval", js: "throw new Error('nope')" } });
  assert.deepEqual(p.posted.at(-1), { frog: 1, type: "reply", n: 3, error: "nope" });
  const before = p.posted.length;
  await p.fire("message", { source: {}, data: { frog: 1, type: "call", n: 4, fn: "eval", js: "1" } });
  assert.equal(p.posted.length, before, "a frame that isn't the parent gets nothing");
});

test("the capture script says a gateway error page is a failed load", () => {
  const p = page();
  p.meta.content = "This session is asleep. Send Frog a message to wake it, then reload.";
  p.run();
  assert.deepEqual(p.posted.find((m) => m.type === "load_failed"), { frog: 1, type: "load_failed", message: p.meta.content });
  assert.equal(p.posted.find((m) => m.type === "navigated"), undefined);
});

// --- the mock gateway's preview host --------------------------------------------------------

let mock: Awaited<ReturnType<typeof startMock>>;
let dev: Server;
before(async () => {
  mock = await startMock({ port: 0, delayMs: 1, previewScript: new URL("../public/preview.js", import.meta.url).pathname });
  dev = createServer((req, res) => res.writeHead(200, { "content-type": "text/html" }).end(`<!doctype html><html><head><title>${req.headers.host}</title></head><body>hi</body></html>`));
  await new Promise<void>((r) => dev.listen(0, "127.0.0.1", r));
});
after(async () => { await mock.close(); await new Promise((r) => dev.close(r)); });

const get = (port: number, host: string, path: string) => new Promise<{ status: number; type: string; body: string }>((resolve, reject) => {
  request({ host: "127.0.0.1", port, path, headers: { host } }, (r) => {
    let body = "";
    r.on("data", (c) => (body += c));
    r.on("end", () => resolve({ status: r.statusCode ?? 0, type: String(r.headers["content-type"] ?? ""), body }));
  }).on("error", reject).end();
});

test("Gateway.preview mints a host that serves the sandbox's dev server with the capture script", async () => {
  const gw = new Gateway({ origin: `http://127.0.0.1:${mock.port}`, token: "acct-a" });
  const s = await gw.create({ repo: "ecto/frog" });
  const devPort = (dev.address() as { port: number }).port;
  const { url } = await gw.preview(s.id, devPort);
  const host = new URL(url).host;
  assert.match(host, /^[0-9a-f]{20}-\d+\.localhost:\d+$/);
  const html = await get(mock.port, host, "/");
  assert.equal(html.body, `<!doctype html><html><head><script src="/__frog/preview.js"></script><title>localhost:${devPort}</title></head><body>hi</body></html>`);
  const script = await get(mock.port, host, "/__frog/preview.js");
  assert.match(script.type, /javascript/);
  assert.equal(script.body, readFileSync(new URL("../public/preview.js", import.meta.url), "utf8"));
  await assert.rejects(new Gateway({ origin: `http://127.0.0.1:${mock.port}`, token: "acct-b" }).preview(s.id, devPort), /no such session/);
  await assert.rejects(gw.preview(s.id, 7070), /port/);
});

// --- the pane -------------------------------------------------------------------------------

test("the Inspector's Preview tab is a live pane: toolbar, address and the hint", () => {
  const noop = () => {};
  const { hub } = rig();
  const thread = { changes: [], panes: { p1: { id: "p1", kind: "preview", title: "Preview", url: "http://localhost:5173/", closed: false } } } as unknown as Parameters<typeof Inspector>[0]["thread"];
  const html = renderToStaticMarkup(createElement(Inspector, { thread, hasPr: false, onClose: noop, onCommit: noop, send: noop, preview: hub, pane: "preview" }));
  assert.match(html, /aria-label="Reload"/);
  assert.match(html, /placeholder="URL or port"/);
  assert.match(html, /value="localhost:5173"/);
  assert.match(html, /aria-label="Pick an element"/);
  assert.match(html, /aria-label="Back"/);
  assert.match(html, /aria-label="Forward"/);
  assert.match(html, /aria-label="Device size"/);
  assert.match(html, /aria-label="Open in browser"/);
  assert.match(html, /aria-label="More"/);
  assert.ok(!/role="radio"/.test(html), "device size is one menu button, not three loose buttons");
  assert.match(html, /<iframe[^>]*sandbox="allow-scripts allow-same-origin allow-forms allow-popups allow-modals allow-downloads"/);
  assert.ok(!/allow-top-navigation/.test(html), "a preview can't navigate the app away");
  assert.ok(!/The Mac app has Preview/.test(html));
  const empty = renderToStaticMarkup(createElement(Inspector, { thread: { ...thread, panes: {} }, hasPr: false, onClose: noop, onCommit: noop, send: noop, preview: hub, pane: "preview" }));
  assert.match(empty, /class="insp-empty"/);
  assert.match(empty, /Nothing to preview yet/);
  assert.match(empty, /Run your dev server, then enter its URL or port, or ask Frog to open it\./);
  hub.available = false;
  const off = renderToStaticMarkup(createElement(Inspector, { thread, hasPr: false, onClose: noop, onCommit: noop, send: noop, preview: hub, pane: "preview" }));
  assert.match(off, /Preview isn’t on the web yet/);
  assert.match(off, /The Mac app has Preview/);
  assert.ok(!/pv-bar/.test(off), "no toolbar that can't do anything");
});

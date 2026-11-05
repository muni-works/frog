// Runs the client against the zest mock gateway (vendored in test/mock).
import { after, before, test } from "node:test";
import assert from "node:assert/strict";
import WebSocket from "ws";
import { startMock } from "./mock/mock-gateway.mjs";
import { Gateway, type Connection, type ConnectionState } from "../src/cloud/client.ts";
import type { Envelope } from "../src/cloud/protocol.ts";
import { apply, empty, pending } from "../src/cloud/transcript.ts";

let mock: Awaited<ReturnType<typeof startMock>>;
const gateway = (token = "acct-a", protocol?: number) =>
  new Gateway({ origin: `http://127.0.0.1:${mock.port}`, token, protocol, WebSocket: WebSocket as any });

before(async () => (mock = await startMock({ port: 0, delayMs: 1 })));
after(() => mock.close());

/** A connection plus everything it has seen, and a way to wait for something. */
function attach(gw: Gateway, id: string, resumeAfter = 0) {
  const envs: Envelope[] = [];
  const states: ConnectionState[] = [];
  const waiters: (() => void)[] = [];
  const poke = () => waiters.splice(0).forEach((w) => w());
  const conn: Connection = gw.connect(
    id,
    {
      onEnvelope: (e) => (envs.push(e), poke()),
      onState: (s) => (states.push(s), poke()),
    },
    resumeAfter,
  );
  const until = async (pred: () => boolean, what: string) => {
    const deadline = Date.now() + 3000;
    while (!pred()) {
      if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
      await new Promise<void>((r) => (waiters.push(r), setTimeout(r, 50)));
    }
  };
  return { conn, envs, states, until };
}

test("routes: create, list, get, delete", async () => {
  const gw = gateway("acct-routes");
  const s = await gw.create({ repo: "ecto/frog" });
  assert.match(s.id, /^s_/);
  assert.ok(s.ws.endsWith(`/v1/sessions/${s.id}/ws`));
  assert.deepEqual((await gw.list()).map((x) => x.id), [s.id]);
  assert.equal((await gw.get(s.id)).repo, "ecto/frog");
  assert.deepEqual(await gateway("someone-else").list(), []);
  await gw.remove(s.id);
  await assert.rejects(gw.get(s.id), { status: 404 });
  await assert.rejects(gw.create({ repo: "not a repo" }), { status: 400 });
});

test("handshake: welcome, then the stored log replays in order", async () => {
  const gw = gateway();
  const { id } = await gw.create({ repo: "ecto/frog" });
  const c = attach(gw, id);
  await c.until(() => c.states.some((s) => s.state === "live"), "welcome");
  const live = c.states.find((s) => s.state === "live")!;
  assert.equal(live.state === "live" && live.welcome.protocol, 1);
  assert.equal(live.state === "live" && live.welcome.session, id);
  const last = live.state === "live" ? live.welcome.last_seq : 0;
  await c.until(() => c.conn.lastSeq === last, "replay");
  assert.equal(c.envs[0].event, "turn_started");
  assert.equal(c.envs.at(-1)!.event, "turn_ended");
  assert.ok(c.envs.every((e, i) => i === 0 || e.seq > c.envs[i - 1].seq));
  // Only durable events are replayed.
  assert.ok(!c.envs.some((e) => e.event === "item_delta" || e.event === "permission_request"));
  c.conn.close();
});

test("refused: an old protocol gets 'update' and doesn't reconnect", async () => {
  const gw = gateway();
  const { id } = await gw.create({ repo: "ecto/frog" });
  const c = attach(gateway("acct-a", 0), id);
  await c.until(() => c.states.some((s) => s.state === "refused"), "refused");
  const r = c.states.find((s) => s.state === "refused")!;
  assert.equal(r.state === "refused" && r.refused.upgrade, "https://frog.toys/download");
  await new Promise((r) => setTimeout(r, 400));
  assert.equal(c.states.filter((s) => s.state === "connecting").length, 1, "no reconnect after refusal");
  assert.equal(c.envs.length, 0);
});

test("reconnect resumes after the last seen seq, with no gaps or repeats", async () => {
  const gw = gateway();
  const { id } = await gw.create({ repo: "ecto/frog" });
  const c = attach(gw, id);
  await c.until(() => c.states.some((s) => s.state === "live"), "welcome");
  c.conn.send({ op: "submit", text: "again" });
  await c.until(() => c.envs.some((e) => e.event === "permission_request"), "permission request");
  const req = c.envs.find((e) => e.event === "permission_request")!;
  const before = c.conn.lastSeq;

  c.conn.drop();
  await c.until(() => c.states.filter((s) => s.state === "live").length === 2, "second welcome");
  c.conn.send({ op: "permission", id: (req as any).id, decision: "allow" });
  await c.until(() => c.envs.filter((e) => e.event === "turn_ended").length === 2, "turn end");

  const seqs = c.envs.map((e) => e.seq);
  assert.equal(new Set(seqs).size, seqs.length, "no repeats");
  assert.ok(seqs.every((s, i) => i === 0 || s > seqs[i - 1]));
  assert.ok(c.envs.some((e) => e.seq > before && e.event === "permission_resolved"));

  // A fresh client resuming mid-log gets only what's after its seq.
  const late = attach(gw, id, before);
  await late.until(() => late.envs.some((e) => e.event === "turn_ended"), "late replay");
  assert.ok(late.envs.every((e) => e.seq > before));
  c.conn.close();
  late.conn.close();
});

test("permission round trip: first answer wins and every client sees it", async () => {
  const gw = gateway();
  const { id } = await gw.create({ repo: "ecto/frog" });
  const a = attach(gw, id);
  const b = attach(gw, id);
  await a.until(() => a.states.some((s) => s.state === "live"), "a live");
  await b.until(() => b.states.some((s) => s.state === "live"), "b live");
  const replayed = a.conn.lastSeq;

  a.conn.send({ op: "submit", text: "install" });
  let ta = empty();
  await a.until(() => a.envs.some((e) => e.seq > replayed && e.event === "permission_request"), "request");
  for (const e of a.envs.filter((e) => e.seq > replayed)) ta = apply(ta, e);
  const [ask] = pending(ta);
  assert.ok(ask && ask.kind === "permission");

  a.conn.send({ op: "permission", id: ask.id, decision: "allow" });
  b.conn.send({ op: "permission", id: ask.id, decision: "deny" });
  for (const c of [a, b]) await c.until(() => c.envs.filter((e) => e.event === "turn_ended").length === 2, "turn end");

  for (const c of [a, b]) {
    const resolved: Envelope[] = c.envs.filter((e) => e.event === "permission_resolved" && e.id === ask.id);
    assert.equal(resolved.length, 1);
    assert.equal((resolved[0] as any).decision, "allow");
  }
  ta = a.envs.filter((e) => e.seq > replayed).reduce(apply, empty());
  assert.equal(pending(ta).length, 0);
  assert.equal(ta.running, false);
  a.conn.close();
  b.conn.close();
});

test("errors reach the UI as sentences, not server text", async () => {
  const { friendly, GatewayError } = await import("../src/cloud/client.ts");
  assert.equal(friendly(new GatewayError(400, "repo must be owner/name")), "That repo doesn't look right. Use owner/name, like ecto/frog.");
  assert.equal(friendly(new GatewayError(500, "Internal Server Error")), "Frog Cloud is unreachable. Try again in a moment.");
  assert.equal(friendly(new TypeError("Failed to fetch")), "Frog Cloud is unreachable. Check your connection and try again.");
  assert.equal(friendly(new GatewayError(401, "missing or invalid key")), "Your sign-in expired. Sign in again.");
  assert.match(friendly(new GatewayError(402, "insufficient_credit")), /credit/);
});

test("a session needs no repo, but a repo given must be owner/name", async () => {
  const s = await gateway().create({});
  assert.equal(s.repo, "");
  await assert.rejects(gateway().create({ repo: "not a repo" }), { status: 400 });
});

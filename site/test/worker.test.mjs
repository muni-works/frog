import test from "node:test";
import assert from "node:assert/strict";
import worker, { toGateway } from "../worker.js";

test("/v1 goes to the gateway with its path, query, method and upgrade", async () => {
  const r = toGateway(new Request("https://frog.toys/v1/sessions/s_1/ws?x=1", { headers: { upgrade: "websocket", authorization: "Bearer k" } }), "https://cloud.frog.toys");
  assert.equal(r.url, "https://cloud.frog.toys/v1/sessions/s_1/ws?x=1");
  assert.equal(r.headers.get("upgrade"), "websocket");
  assert.equal(r.headers.get("authorization"), "Bearer k");
  const p = toGateway(new Request("https://frog.toys/v1/sessions", { method: "POST", body: "{}" }), "https://cloud.frog.toys");
  assert.equal(p.method, "POST");
  assert.equal(await p.text(), "{}");
});

test("/v1 with no gateway is a 503 that points at the status page", async () => {
  const j = await worker.fetch(new Request("https://frog.toys/v1/models"), {});
  assert.equal(j.status, 503);
  assert.match(j.headers.get("content-type"), /json/);
  assert.equal((await j.json()).error.status, "https://api.frog.toys/status");
  const h = await worker.fetch(new Request("https://frog.toys/v1", { headers: { accept: "text/html" } }), {});
  assert.equal(h.status, 503);
  assert.match(await h.text(), /api\.frog\.toys\/status/);
});

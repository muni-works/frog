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

test("/node serves the node installer as plain text", async () => {
  const ASSETS = { fetch: async (u) => (new URL(u).pathname === "/node.sh" ? new Response("#!/bin/sh\n") : new Response("", { status: 404 })) };
  const r = await worker.fetch(new Request("https://frog.toys/node"), { ASSETS });
  assert.equal(r.status, 200);
  assert.match(r.headers.get("content-type"), /text\/plain/);
  assert.equal(await r.text(), "#!/bin/sh\n");
});

import { platformOf, appVersionOf } from "../worker.js";

function recorder() {
  const points = [];
  return { points, ANALYTICS: { writeDataPoint: (p) => points.push(p) } };
}

test("install hits write one point each: path, platform, country, and no IP", async () => {
  const { points, ANALYTICS } = recorder();
  const ASSETS = { fetch: async () => new Response("#!/bin/sh\n") };
  const req = (path, ua) => {
    const r = new Request(`https://frog.toys${path}`, { headers: { "user-agent": ua, "cf-connecting-ip": "203.0.113.9" } });
    Object.defineProperty(r, "cf", { value: { country: "DE" } });
    return r;
  };
  await worker.fetch(req("/install.sh", "curl/8.7.1"), { ANALYTICS, ASSETS });
  await worker.fetch(req("/download", "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_5)"), { ANALYTICS, ASSETS });
  await worker.fetch(req("/node?platform=linux", "curl/8.7.1"), { ANALYTICS, ASSETS });
  assert.deepEqual(points.map((p) => p.blobs), [
    ["install", "/install.sh", "unknown", "DE", ""],
    ["install", "/download", "mac", "DE", ""],
    ["install", "/node", "linux", "DE", ""],
  ]);
  assert.ok(!JSON.stringify(points).includes("203.0.113.9"));
});

test("/install.sh still serves the script", async () => {
  const ASSETS = { fetch: async (r) => new Response(new URL(r.url).pathname === "/install.sh" ? "#!/bin/sh\n" : "", { status: 200 }) };
  const r = await worker.fetch(new Request("https://frog.toys/install.sh"), { ASSETS });
  assert.equal(await r.text(), "#!/bin/sh\n");
});

test("/appcast.xml proxies the release asset and counts the app version", async () => {
  const { points, ANALYTICS } = recorder();
  const real = globalThis.fetch;
  globalThis.fetch = async (u) => {
    assert.equal(String(u), "https://github.com/muni-works/frog/releases/latest/download/appcast.xml");
    return new Response("<rss/>");
  };
  try {
    const r = await worker.fetch(new Request("https://frog.toys/appcast.xml", { headers: { "user-agent": "Frog/0.2.0 Sparkle/2.7.1" } }), { ANALYTICS });
    assert.equal(r.status, 200);
    assert.match(r.headers.get("content-type"), /xml/);
    assert.equal(await r.text(), "<rss/>");
    assert.deepEqual(points[0].blobs, ["appcast", "/appcast.xml", "mac", "XX", "0.2.0"]);
  } finally {
    globalThis.fetch = real;
  }
});

test("platform and version parsing", () => {
  const u = new URL("https://frog.toys/download");
  assert.equal(platformOf(u, "Mozilla/5.0 (Windows NT 10.0)"), "windows");
  assert.equal(platformOf(u, "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)"), "ios");
  assert.equal(platformOf(new URL("https://frog.toys/x?platform=evil"), ""), "unknown");
  assert.equal(appVersionOf("Frog/0.3.0-rc1 Sparkle/2"), "0.3.0-rc1");
  assert.equal(appVersionOf("curl/8"), "unknown");
});

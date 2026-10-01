import test from "node:test";
import assert from "node:assert";
import crypto from "node:crypto";
import { validate, jwt, request, _reset } from "../worker/apns.js";
import worker from "../worker/index.js";

const token = "a".repeat(64);
const ok = { token, topic: "eco.frog.remote", payload: JSON.stringify({ aps: { alert: "hi" } }) };

test("accepts a frog push and defaults to production alerts", () => {
  const p = validate(ok);
  assert.equal(p.env, "production");
  assert.equal(p.push_type, "alert");
});

test("refuses other apps, bad tokens and oversized payloads", () => {
  assert.throws(() => validate({ ...ok, topic: "com.example.app" }), /not a frog app/);
  assert.throws(() => validate({ ...ok, token: "xyz" }), /bad device token/);
  assert.throws(() => validate({ ...ok, payload: JSON.stringify({ x: "y".repeat(5000) }) }), /over 4096/);
  assert.throws(() => validate({ ...ok, payload: "{nope" }));
  assert.throws(() => validate({ ...ok, push_type: "liveactivity" }), /disagree/);
});

test("live activity pushes use their own topic and a larger limit", () => {
  const p = validate({ ...ok, topic: "eco.frog.remote.push-type.liveactivity", push_type: "liveactivity",
    payload: JSON.stringify({ x: "y".repeat(4500) }) });
  assert.equal(request(p, "t").headers["apns-push-type"], "liveactivity");
});

test("signs an ES256 provider token that verifies, and reuses it", async () => {
  _reset();
  const { privateKey, publicKey } = crypto.generateKeyPairSync("ec", { namedCurve: "P-256" });
  const key = privateKey.export({ type: "pkcs8", format: "pem" });
  const t = await jwt({ key, keyId: "KEY123", teamId: "TEAM45" }, 1000);
  const [h, c, s] = t.split(".");
  assert.deepEqual(JSON.parse(Buffer.from(h, "base64url")), { alg: "ES256", kid: "KEY123" });
  assert.deepEqual(JSON.parse(Buffer.from(c, "base64url")), { iss: "TEAM45", iat: 1000 });
  assert.ok(crypto.verify("sha256", Buffer.from(`${h}.${c}`), { key: publicKey, dsaEncoding: "ieee-p1363" }, Buffer.from(s, "base64url")));
  assert.equal(await jwt({ key, keyId: "KEY123", teamId: "TEAM45" }, 1000 + 49 * 60), t);
  assert.notEqual(await jwt({ key, keyId: "KEY123", teamId: "TEAM45" }, 1000 + 51 * 60), t);
});

test("builds the APNs request", () => {
  const r = request(validate({ ...ok, env: "sandbox", collapse_id: "perm-1" }), "jwt");
  assert.equal(r.url, `https://api.sandbox.push.apple.com/3/device/${token}`);
  assert.equal(r.headers["apns-collapse-id"], "perm-1");
  assert.equal(r.headers.authorization, "bearer jwt");
});

// A stand-in for the R2 binding: enough of get() for whole objects and ranges.
function bucket(objects) {
  return {
    async get(key, { range } = {}) {
      const data = objects[key];
      if (!data) return null;
      const m = range?.get?.("range")?.match(/^bytes=(\d+)-(\d+)$/);
      const r = m ? { offset: +m[1], length: +m[2] - +m[1] + 1 } : undefined;
      return {
        size: data.length, httpEtag: '"e"', range: r,
        body: r ? data.slice(r.offset, r.offset + r.length) : data,
        writeHttpMetadata: (h) => h.set("content-type", "application/x-apple-diskimage"),
      };
    },
  };
}
const env = { RELEASES: bucket({ "Frog.dmg": "DMGDATA", "releases/0.1.0/Frog.dmg": "OLD", "appcast.xml": "<rss/>" }), ASSETS: { fetch: () => new Response("asset") } };
const get = (path, init) => worker.fetch(new Request(`https://frog.eco${path}`, init), env);

test("serves downloads from R2, with ranges", async () => {
  const r = await get("/download");
  assert.equal(r.status, 200);
  assert.equal(await r.text(), "DMGDATA");
  assert.match(r.headers.get("content-disposition"), /Frog\.dmg/);
  const part = await get("/download", { headers: { range: "bytes=0-2" } });
  assert.equal(part.status, 206);
  assert.equal(part.headers.get("content-range"), "bytes 0-2/7");
  assert.equal(await (await get("/releases/0.1.0/Frog.dmg")).text(), "OLD");
  assert.equal((await get("/releases/9.9.9/Frog.dmg")).status, 404);
  assert.equal(await (await get("/appcast.xml")).text(), "<rss/>");
});

test("everything else is the static site; the relay wants a POST and a key", async () => {
  assert.equal(await (await get("/energy")).text(), "asset");
  assert.equal((await get("/api/push")).status, 405);
  assert.equal((await get("/api/push", { method: "POST", body: "{}" })).status, 400);
  assert.equal((await get("/api/push", { method: "POST", body: JSON.stringify(ok) })).status, 503);
});

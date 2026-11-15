const test = require("node:test");
const assert = require("node:assert");
const crypto = require("node:crypto");
const { validate, jwt, request, _reset } = require("../api/_apns.js");

const token = "a".repeat(64);
const ok = { token, topic: "toys.frog.remote", payload: JSON.stringify({ aps: { alert: "hi" } }) };

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
  const p = validate({ ...ok, topic: "toys.frog.remote.push-type.liveactivity", push_type: "liveactivity",
    payload: JSON.stringify({ x: "y".repeat(4500) }) });
  assert.equal(request(p, "t").headers["apns-push-type"], "liveactivity");
});

test("signs an ES256 provider token that verifies, and reuses it", () => {
  _reset();
  const { privateKey, publicKey } = crypto.generateKeyPairSync("ec", { namedCurve: "P-256" });
  const key = privateKey.export({ type: "pkcs8", format: "pem" });
  const t = jwt({ key, keyId: "KEY123", teamId: "TEAM45" }, 1000);
  const [h, c, s] = t.split(".");
  assert.deepEqual(JSON.parse(Buffer.from(h, "base64url")), { alg: "ES256", kid: "KEY123" });
  assert.deepEqual(JSON.parse(Buffer.from(c, "base64url")), { iss: "TEAM45", iat: 1000 });
  assert.ok(crypto.verify("sha256", Buffer.from(`${h}.${c}`), { key: publicKey, dsaEncoding: "ieee-p1363" }, Buffer.from(s, "base64url")));
  assert.equal(jwt({ key, keyId: "KEY123", teamId: "TEAM45" }, 1000 + 49 * 60), t);
  assert.notEqual(jwt({ key, keyId: "KEY123", teamId: "TEAM45" }, 1000 + 51 * 60), t);
});

test("builds the APNs request", () => {
  const r = request(validate({ ...ok, env: "sandbox", collapse_id: "perm-1" }), "jwt");
  assert.equal(r.host, "https://api.sandbox.push.apple.com");
  assert.equal(r.headers[":path"], `/3/device/${token}`);
  assert.equal(r.headers["apns-collapse-id"], "perm-1");
  assert.equal(r.headers.authorization, "bearer jwt");
});

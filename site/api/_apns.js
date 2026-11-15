// The frog push relay's logic: check a request from a Mac, sign an APNs token, send the push.
// Files starting with _ aren't functions on Vercel; push.js is the endpoint.
const crypto = require("node:crypto");
const http2 = require("node:http2");

const HOSTS = { production: "https://api.push.apple.com", sandbox: "https://api.sandbox.push.apple.com" };
const TOPIC = /^toys\.frog\.remote(\.push-type\.liveactivity)?$/;

/** A request from a Mac, checked; throws a message a Mac can show. */
function validate(body) {
  if (!body || typeof body !== "object") throw new Error("expected a JSON object");
  const { token, env = "production", topic, push_type = "alert", payload, collapse_id } = body;
  if (typeof token !== "string" || !/^[0-9a-f]{64,200}$/i.test(token)) throw new Error("bad device token");
  if (!HOSTS[env]) throw new Error("env is production or sandbox");
  if (typeof topic !== "string" || !TOPIC.test(topic)) throw new Error("not a frog app");
  if (!["alert", "liveactivity"].includes(push_type)) throw new Error("push_type is alert or liveactivity");
  if ((push_type === "liveactivity") !== topic.endsWith(".push-type.liveactivity")) throw new Error("topic and push_type disagree");
  if (typeof payload !== "string") throw new Error("payload is a JSON string");
  const limit = push_type === "liveactivity" ? 5120 : 4096;
  if (Buffer.byteLength(payload) > limit) throw new Error(`payload over ${limit} bytes`);
  JSON.parse(payload);
  if (collapse_id !== undefined && (typeof collapse_id !== "string" || Buffer.byteLength(collapse_id) > 64)) throw new Error("bad collapse_id");
  return { token, env, topic, push_type, payload, collapse_id };
}

let cached = null;

/** The provider token APNs wants, reused for 50 minutes (Apple allows up to 60). */
function jwt({ key, keyId, teamId }, now = Math.floor(Date.now() / 1000)) {
  if (cached && cached.keyId === keyId && now - cached.iat < 50 * 60) return cached.token;
  const b64 = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
  const unsigned = `${b64({ alg: "ES256", kid: keyId })}.${b64({ iss: teamId, iat: now })}`;
  const sig = crypto.sign("sha256", Buffer.from(unsigned), { key, dsaEncoding: "ieee-p1363" }).toString("base64url");
  cached = { keyId, iat: now, token: `${unsigned}.${sig}` };
  return cached.token;
}

/** The HTTP/2 request APNs expects for one push. */
function request(p, auth) {
  const headers = {
    ":method": "POST",
    ":path": `/3/device/${p.token}`,
    authorization: `bearer ${auth}`,
    "apns-topic": p.topic,
    "apns-push-type": p.push_type,
    "apns-priority": "10",
    "apns-expiration": "0",
  };
  if (p.collapse_id) headers["apns-collapse-id"] = p.collapse_id;
  return { host: HOSTS[p.env], headers, body: p.payload };
}

function send({ host, headers, body }) {
  return new Promise((resolve, reject) => {
    const client = http2.connect(host);
    client.on("error", reject);
    const req = client.request(headers);
    let status = 0;
    let data = "";
    req.on("response", (h) => (status = h[":status"]));
    req.on("data", (c) => (data += c));
    req.on("end", () => {
      client.close();
      resolve({ status, reason: data ? JSON.parse(data).reason : undefined });
    });
    req.on("error", reject);
    req.end(body);
  });
}

module.exports = { validate, jwt, request, send, _reset: () => (cached = null) };

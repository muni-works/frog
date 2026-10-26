// The frog push relay's logic: check a request from a Mac, sign an APNs token, send the push.
// This is the Cloudflare Pages (Workers) copy: ES modules, WebCrypto and fetch, because Workers
// only stubs node:http2. The Vercel copy (site/api/) keeps node:crypto and node:http2.
// Files starting with _ aren't functions; push.js is the endpoint.

const HOSTS = { production: "https://api.push.apple.com", sandbox: "https://api.sandbox.push.apple.com" };
const TOPIC = /^eco\.frog\.remote(\.push-type\.liveactivity)?$/;

const enc = new TextEncoder();

/** The env vars the relay needs set (beyond APNS_*): PUSH_RELAY_SECRET. */
function checkAuth(auth, secret) {
  if (!secret) throw Object.assign(new Error("the relay has no caller secret yet"), { status: 503 });
  if (auth !== `Bearer ${secret}`) throw Object.assign(new Error("unauthorized"), { status: 401 });
}

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
  if (enc.encode(payload).byteLength > limit) throw new Error(`payload over ${limit} bytes`);
  JSON.parse(payload);
  if (collapse_id !== undefined && (typeof collapse_id !== "string" || enc.encode(collapse_id).byteLength > 64)) throw new Error("bad collapse_id");
  return { token, env, topic, push_type, payload, collapse_id };
}

let cached = null;

/** The provider token APNs wants, reused for 50 minutes (Apple allows up to 60). ES256, WebCrypto. */
async function jwt({ key, keyId, teamId }, now = Math.floor(Date.now() / 1000)) {
  if (cached && cached.keyId === keyId && now - cached.iat < 50 * 60) return cached.token;
  const pkcs8 = pemBody(key);
  const privateKey = await crypto.subtle.importKey("pkcs8", pkcs8, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const b64 = (o) => btoa(String.fromCharCode(...enc.encode(JSON.stringify(o)))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  const unsigned = `${b64({ alg: "ES256", kid: keyId })}.${b64({ iss: teamId, iat: now })}`;
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, privateKey, enc.encode(unsigned));
  const raw = new Uint8Array(sig);
  const sigB64 = btoa(String.fromCharCode(...raw)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  cached = { keyId, iat: now, token: `${unsigned}.${sigB64}` };
  return cached.token;
}

/** A PEM "-----BEGIN PRIVATE KEY-----" body as the DER bytes WebCrypto imports. */
function pemBody(pem) {
  const b64 = pem.replace(/-----(BEGIN|END) [^-]+-----/g, "").replace(/\s+/g, "");
  const bin = atob(b64);
  return Uint8Array.from(bin, (c) => c.charCodeAt(0));
}

/** One push, over fetch. Workers has no http2.connect; fetch speaks HTTP/2 to APNs itself. */
async function send({ host, headers, body }) {
  const r = await fetch(`${host}/3/device/${headers[":path"].split("/").pop()}`, {
    method: "POST",
    headers: {
      authorization: headers.authorization,
      "apns-topic": headers["apns-topic"],
      "apns-push-type": headers["apns-push-type"],
      "apns-priority": "10",
      "apns-expiration": "0",
      ...(headers["apns-collapse-id"] ? { "apns-collapse-id": headers["apns-collapse-id"] } : {}),
    },
    body,
  });
  const text = await r.text();
  return { status: r.status, reason: text ? JSON.parse(text).reason : undefined };
}

/** The HTTP/2-shaped request APNs expects for one push (shared shape with the Vercel copy). */
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

// --- Rate limiting: a per-key, per-window counter in the isolate. Best effort: one worker may
// see only its own share. Honest for a single-user relay; a Durable Object would be the real fix.
const WINDOW_MS = 60_000;
const WINDOW_MAX = 30;
const buckets = new Map();

function rateLimit(key, now = Date.now()) {
  const start = Math.floor(now / WINDOW_MS) * WINDOW_MS;
  let b = buckets.get(key);
  if (!b || b.start !== start) { b = { start, count: 0 }; buckets.set(key, b); }
  b.count++;
  if (buckets.size > 1000) for (const [k, v] of buckets) if (v.start !== start) buckets.delete(k);
  return b.count <= WINDOW_MAX;
}

export function _reset() { cached = null; buckets.clear(); }

export { checkAuth, validate, jwt, request, send, rateLimit };


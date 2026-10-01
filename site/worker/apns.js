// The frog push relay's logic: check a request from a Mac, sign an APNs token, send the push.
// Web APIs only (WebCrypto, fetch), so it runs on Workers and under node --test alike.

const HOSTS = { production: "https://api.push.apple.com", sandbox: "https://api.sandbox.push.apple.com" };
const TOPIC = /^eco\.frog\.remote(\.push-type\.liveactivity)?$/;
const bytes = (s) => new TextEncoder().encode(s).length;

/** A request from a Mac, checked; throws a message a Mac can show. */
export function validate(body) {
  if (!body || typeof body !== "object") throw new Error("expected a JSON object");
  const { token, env = "production", topic, push_type = "alert", payload, collapse_id } = body;
  if (typeof token !== "string" || !/^[0-9a-f]{64,200}$/i.test(token)) throw new Error("bad device token");
  if (!HOSTS[env]) throw new Error("env is production or sandbox");
  if (typeof topic !== "string" || !TOPIC.test(topic)) throw new Error("not a frog app");
  if (!["alert", "liveactivity"].includes(push_type)) throw new Error("push_type is alert or liveactivity");
  if ((push_type === "liveactivity") !== topic.endsWith(".push-type.liveactivity")) throw new Error("topic and push_type disagree");
  if (typeof payload !== "string") throw new Error("payload is a JSON string");
  const limit = push_type === "liveactivity" ? 5120 : 4096;
  if (bytes(payload) > limit) throw new Error(`payload over ${limit} bytes`);
  JSON.parse(payload);
  if (collapse_id !== undefined && (typeof collapse_id !== "string" || bytes(collapse_id) > 64)) throw new Error("bad collapse_id");
  return { token, env, topic, push_type, payload, collapse_id };
}

const b64url = (buf) => btoa(String.fromCharCode(...new Uint8Array(buf))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const b64json = (o) => b64url(new TextEncoder().encode(JSON.stringify(o)));

/** An Apple .p8 (PKCS#8 PEM) as a WebCrypto signing key. */
async function importKey(pem) {
  const der = Uint8Array.from(atob(pem.replace(/-----[^-]+-----|\s/g, "")), (c) => c.charCodeAt(0));
  return crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
}

let cached = null;

/** The provider token APNs wants, reused for 50 minutes (Apple allows up to 60). */
export async function jwt({ key, keyId, teamId }, now = Math.floor(Date.now() / 1000)) {
  if (cached && cached.keyId === keyId && now - cached.iat < 50 * 60) return cached.token;
  const unsigned = `${b64json({ alg: "ES256", kid: keyId })}.${b64json({ iss: teamId, iat: now })}`;
  // WebCrypto's ECDSA signature is already r||s (IEEE P1363), which is what JWS wants.
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, await importKey(key), new TextEncoder().encode(unsigned));
  cached = { keyId, iat: now, token: `${unsigned}.${b64url(sig)}` };
  return cached.token;
}

/** The request APNs expects for one push. Workers' fetch is HTTP/1.1; Cloudflare's edge speaks HTTP/2 to Apple. */
export function request(p, auth) {
  const headers = {
    authorization: `bearer ${auth}`,
    "apns-topic": p.topic,
    "apns-push-type": p.push_type,
    "apns-priority": "10",
    "apns-expiration": "0",
  };
  if (p.collapse_id) headers["apns-collapse-id"] = p.collapse_id;
  return { url: `${HOSTS[p.env]}/3/device/${p.token}`, headers, body: p.payload };
}

export async function send({ url, headers, body }) {
  const r = await fetch(url, { method: "POST", headers, body });
  const text = await r.text();
  return { status: r.status, reason: text ? JSON.parse(text).reason : undefined };
}

export const _reset = () => (cached = null);

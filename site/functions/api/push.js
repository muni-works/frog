// POST /api/push: a Mac running frog asks for a push to a phone it's paired with. The APNs key
// lives here (APNS_KEY, APNS_KEY_ID, APNS_TEAM_ID), never in the app. Callers identify with the
// shared relay secret: `Authorization: Bearer <PUSH_RELAY_SECRET>` (the Mac sends what Settings ›
// General holds, or FROG_PUSH_SECRET). Secrets: `npx wrangler secret put <NAME>` from site/.
// A static import: Pages' module workers hoist top-level await badly across bundling modes, and
// the first deploy failed on `await import` at the top level.
import { checkAuth, validate, jwt, request, send, rateLimit } from "./_apns.js";

export async function onRequest(context) {
  const { request: req, env } = context;
  const json = (status, body) =>
    new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

  if (req.method !== "POST") return json(405, { error: "POST only" });

  try {
    checkAuth(req.headers.get("Authorization"), env.PUSH_RELAY_SECRET);
  } catch (e) {
    return json(e.status ?? 401, { error: e.message });
  }

  // 30 pushes a minute per secret (per isolate; see _apns.js).
  if (!rateLimit("relay")) return json(429, { error: "too many pushes, slow down" });

  let p;
  try {
    const body = await req.text();
    p = validate(body ? JSON.parse(body) : {});
  } catch (e) {
    return json(400, { error: e.message });
  }

  const key = env.APNS_KEY?.replace(/\\n/g, "\n");
  if (!key || !env.APNS_KEY_ID || !env.APNS_TEAM_ID) {
    return json(503, { error: "the relay has no APNs key yet" });
  }

  try {
    const auth = await jwt({ key, keyId: env.APNS_KEY_ID, teamId: env.APNS_TEAM_ID });
    const r = await send(request(p, auth));
    // 410: the phone deleted the app or turned pushes off; the Mac should forget it.
    const status = r.status === 200 ? 200 : r.status === 410 ? 410 : 502;
    return json(status, r);
  } catch (e) {
    return json(502, { error: "APNs unreachable" });
  }
}

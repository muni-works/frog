// POST /api/push: a Mac running frog asks for a push to a phone it's paired with. The APNs key
// lives here (APNS_KEY, APNS_KEY_ID, APNS_TEAM_ID), never in the app.
const { validate, jwt, request, send } = require("./_apns.js");

export async function onRequest(context) {
  const { request } = context.env;
  const url = new URL(request.url);
  
  if (request.method !== "POST") {
    return new Response(JSON.stringify({ error: "POST only" }), {
      status: 405,
      headers: { "Content-Type": "application/json" }
    });
  }
  
  let p;
  try {
    const body = await request.text();
    p = validate(body ? JSON.parse(body) : {});
  } catch (e) {
    return new Response(JSON.stringify({ error: e.message }), {
      status: 400,
      headers: { "Content-Type": "application/json" }
    });
  }
  
  const key = context.env.APNS_KEY?.replace(/\\n/g, "\n");
  if (!key || !context.env.APNS_KEY_ID || !context.env.APNS_TEAM_ID) {
    return new Response(JSON.stringify({ error: "the relay has no APNs key yet" }), {
      status: 503,
      headers: { "Content-Type": "application/json" }
    });
  }
  
  try {
    const auth = jwt({
      key,
      keyId: context.env.APNS_KEY_ID,
      teamId: context.env.APNS_TEAM_ID
    });
    const r = await send(request(p, auth));
    // 410: the phone deleted the app or turned pushes off; the Mac should forget it.
    const status = r.status === 200 ? 200 : r.status === 410 ? 410 : 502;
    return new Response(JSON.stringify(r), {
      status,
      headers: { "Content-Type": "application/json" }
    });
  } catch (e) {
    return new Response(JSON.stringify({ error: "APNs unreachable" }), {
      status: 502,
      headers: { "Content-Type": "application/json" }
    });
  }
}

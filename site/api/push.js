// POST /api/push: a Mac running frog asks for a push to a phone it's paired with. The APNs key
// lives here (APNS_KEY, APNS_KEY_ID, APNS_TEAM_ID), never in the app.
const { validate, jwt, request, send } = require("./_apns.js");

module.exports = async (req, res) => {
  if (req.method !== "POST") return res.status(405).json({ error: "POST only" });
  let p;
  try {
    p = validate(typeof req.body === "string" ? JSON.parse(req.body) : req.body);
  } catch (e) {
    return res.status(400).json({ error: e.message });
  }
  const key = process.env.APNS_KEY?.replace(/\\n/g, "\n");
  if (!key || !process.env.APNS_KEY_ID || !process.env.APNS_TEAM_ID) {
    return res.status(503).json({ error: "the relay has no APNs key yet" });
  }
  try {
    const auth = jwt({ key, keyId: process.env.APNS_KEY_ID, teamId: process.env.APNS_TEAM_ID });
    const r = await send(request(p, auth));
    // 410: the phone deleted the app or turned pushes off; the Mac should forget it.
    return res.status(r.status === 200 ? 200 : r.status === 410 ? 410 : 502).json(r);
  } catch (e) {
    return res.status(502).json({ error: "APNs unreachable" });
  }
};

// frog.eco: the static site (Workers static assets), plus the few paths that need code.
//   POST /api/push      the push relay; the APNs key lives here, never in the app
//   GET  /download      the latest Frog.dmg, from R2
//   GET  /appcast.xml   Sparkle's feed, from R2
//   GET  /releases/…    every version's DMG, from R2 (what the appcast's enclosures point at)
// scripts/release.sh uploads to the RELEASES bucket.
import { validate, jwt, request, send } from "./apns.js";

const json = (body, status = 200) => Response.json(body, { status });

async function push(req, env) {
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  let p;
  try {
    p = validate(await req.json());
  } catch (e) {
    return json({ error: e.message }, 400);
  }
  if (!env.APNS_KEY || !env.APNS_KEY_ID || !env.APNS_TEAM_ID) return json({ error: "the relay has no APNs key yet" }, 503);
  try {
    const auth = await jwt({ key: env.APNS_KEY.replace(/\\n/g, "\n"), keyId: env.APNS_KEY_ID, teamId: env.APNS_TEAM_ID });
    const r = await send(request(p, auth));
    // 410: the phone deleted the app or turned pushes off; the Mac should forget it.
    return json(r, r.status === 200 ? 200 : r.status === 410 ? 410 : 502);
  } catch {
    return json({ error: "APNs unreachable" }, 502);
  }
}

/** One object from the releases bucket, with ranges (resumed downloads) and conditional GETs. */
async function release(req, env, key, { cache, filename } = {}) {
  if (req.method !== "GET" && req.method !== "HEAD") return new Response("GET only", { status: 405 });
  const obj = await env.RELEASES.get(key, { range: req.headers, onlyIf: req.headers });
  if (!obj) return new Response("Not found", { status: 404 });
  const headers = new Headers();
  obj.writeHttpMetadata(headers);
  headers.set("etag", obj.httpEtag);
  headers.set("accept-ranges", "bytes");
  headers.set("cache-control", cache);
  if (filename) headers.set("content-disposition", `attachment; filename="${filename}"`);
  if (!("body" in obj)) return new Response(null, { status: 304, headers });
  if (obj.range && req.headers.has("range")) {
    const { offset = 0, length = obj.size - offset } = obj.range;
    headers.set("content-range", `bytes ${offset}-${offset + length - 1}/${obj.size}`);
    headers.set("content-length", String(length));
    return new Response(req.method === "HEAD" ? null : obj.body, { status: 206, headers });
  }
  headers.set("content-length", String(obj.size));
  return new Response(req.method === "HEAD" ? null : obj.body, { headers });
}

export default {
  async fetch(req, env) {
    const { pathname } = new URL(req.url);
    if (pathname === "/api/push") return push(req, env);
    if (pathname === "/download") return release(req, env, "Frog.dmg", { cache: "public, max-age=300", filename: "Frog.dmg" });
    if (pathname === "/appcast.xml") return release(req, env, "appcast.xml", { cache: "public, max-age=300" });
    const m = pathname.match(/^\/releases\/(\d+\.\d+\.\d+)\/Frog\.dmg$/);
    if (m) return release(req, env, `releases/${m[1]}/Frog.dmg`, { cache: "public, max-age=31536000, immutable", filename: "Frog.dmg" });
    return env.ASSETS.fetch(req);
  },
};

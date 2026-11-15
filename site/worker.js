// frog.toys: static assets (site/build.sh: the web app at /, marketing at /mac), plus the routes
// that aren't files. Assets win; the worker only sees requests no file matched (wrangler.jsonc:
// not_found_handling "none"). /v1/* is the web app's Frog Cloud API: forwarded to the gateway,
// websocket upgrades included, so the browser only ever talks to frog.toys.
import { onRequest as push } from "./functions/api/push.js";

const RELEASES = "https://github.com/muni-works/frog/releases/latest/download";
const REDIRECTS = { "/download": `${RELEASES}/Frog.dmg` };

// Launch analytics (docs/privacy.md): one Analytics Engine point per install hit and per
// appcast fetch, written in the background by the runtime. Path, platform, country, app
// version. Never the IP, the full User-Agent, a cookie or anything that tells two people apart.
// blobs: [kind, path, platform, country, version]; doubles: [1]; index: kind.
const INSTALL_PATHS = new Set(["/install.sh", "/node", "/download"]);
const PLATFORMS = new Set(["mac", "linux", "windows", "ios", "android", "unknown"]);

/** The platform a hit came from: `?platform=` when it names one, else a guess from the
 * User-Agent's OS. curl and friends say nothing about the OS, so they're "unknown". */
export function platformOf(url, ua) {
  const q = (url.searchParams.get("platform") || "").toLowerCase();
  if (PLATFORMS.has(q)) return q;
  if (/iPhone|iPad|iPod/.test(ua)) return "ios";
  if (/Android/.test(ua)) return "android";
  if (/Mac OS X|Macintosh|Darwin/.test(ua)) return "mac";
  if (/Windows/.test(ua)) return "windows";
  if (/Linux|X11/.test(ua)) return "linux";
  return "unknown";
}

/** The app version in Sparkle's User-Agent ("Frog/0.2.0 Sparkle/2.7.1"), or "unknown". */
export function appVersionOf(ua) {
  const m = /^Frog\/([0-9][\w.+-]{0,31})/.exec(ua || "");
  return m ? m[1] : "unknown";
}

/** Two-letter country from Cloudflare, "XX" when it has none. */
const countryOf = (request) => (request.cf && /^[A-Z0-9]{2}$/.test(request.cf.country || "") ? request.cf.country : "XX");

export function count(env, request, kind, path, extra = {}) {
  if (!env.ANALYTICS) return;
  const url = new URL(request.url);
  const ua = request.headers.get("user-agent") || "";
  try {
    env.ANALYTICS.writeDataPoint({
      indexes: [kind],
      blobs: [kind, path, extra.platform ?? platformOf(url, ua), countryOf(request), extra.version ?? ""],
      doubles: [1],
    });
  } catch (e) {
    console.error(JSON.stringify({ msg: "analytics write failed", error: String(e) }));
  }
}

/** Sparkle's feed, proxied from the latest release so fetches can be counted per version.
 * Cached at the edge for five minutes; GitHub follows its own redirect to the asset. */
async function appcast(request, env) {
  count(env, request, "appcast", "/appcast.xml", { platform: "mac", version: appVersionOf(request.headers.get("user-agent")) });
  const r = await fetch(`${RELEASES}/appcast.xml`, { cf: { cacheTtl: 300, cacheEverything: true } });
  if (!r.ok) return new Response("appcast unavailable\n", { status: 502, headers: { "Content-Type": "text/plain", "Cache-Control": "no-store" } });
  return new Response(r.body, { status: 200, headers: { "Content-Type": "application/xml; charset=utf-8", "Cache-Control": "max-age=300" } });
}

/** /v1/* to the gateway, same path and query, body and upgrade passed through. */
export function toGateway(request, origin) {
  const url = new URL(request.url);
  const target = new URL(url.pathname + url.search, origin);
  return new Request(target, request);
}

const STATUS = "https://api.frog.toys/status";

/** Frog Cloud unreachable from here: a 503 the web app (JSON) and a person (HTML) can both read. */
export function outage(request) {
  const headers = { "Retry-After": "30", "Cache-Control": "no-store" };
  const message = "Frog Cloud is unreachable right now. Try again in a minute.";
  if ((request.headers.get("accept") || "").includes("text/html")) {
    const html = `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Frog Cloud is down</title><body style="font:16px/1.5 -apple-system,sans-serif;max-width:32rem;margin:15vh auto;padding:0 16px"><h1 style="font-size:22px">Frog Cloud is down</h1><p>${message}</p><p><a href="${STATUS}">Check the status page</a></p>`;
    return new Response(html, { status: 503, headers: { ...headers, "Content-Type": "text/html; charset=utf-8" } });
  }
  const body = { error: { type: "unavailable", code: "gateway_unavailable", message, status: STATUS } };
  return new Response(JSON.stringify(body), { status: 503, headers: { ...headers, "Content-Type": "application/json" } });
}

export default {
  async fetch(request, env) {
    const { pathname } = new URL(request.url);
    if (pathname === "/v1" || pathname.startsWith("/v1/")) {
      if (!env.GATEWAY_ORIGIN) return outage(request);
      return fetch(toGateway(request, env.GATEWAY_ORIGIN));
    }
    if (pathname === "/api/push") return push({ request, env });
    if (INSTALL_PATHS.has(pathname)) count(env, request, "install", pathname);
    if (pathname === "/appcast.xml") return appcast(request, env);
    // /install.sh is a file, but wrangler.jsonc runs the worker first for it so it's counted.
    if (pathname === "/install.sh" && env.ASSETS) return env.ASSETS.fetch(request);
    // curl -fsSL https://frog.toys/node | sh: the node installer, as a script.
    if (pathname === "/node" && env.ASSETS) {
      const r = await env.ASSETS.fetch(new URL("/node.sh", request.url));
      return new Response(r.body, { status: r.status, headers: { "Content-Type": "text/plain; charset=utf-8", "Cache-Control": "max-age=300" } });
    }
    if (REDIRECTS[pathname]) return Response.redirect(REDIRECTS[pathname], 302);
    // A conversation's own URL (/s/<id>) is the app: serve its page and let it route.
    if (/^\/s\/[\w-]+\/?$/.test(pathname) && env.ASSETS) return env.ASSETS.fetch(new URL("/", request.url));
    return new Response("not found\n", { status: 404, headers: { "Content-Type": "text/plain" } });
  },
};

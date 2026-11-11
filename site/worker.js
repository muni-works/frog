// frog.toys: static assets (site/build.sh: the web app at /, marketing at /mac), plus the routes
// that aren't files. Assets win; the worker only sees requests no file matched (wrangler.jsonc:
// not_found_handling "none"). /v1/* is the web app's Frog Cloud API: forwarded to the gateway,
// websocket upgrades included, so the browser only ever talks to frog.toys.
import { onRequest as push } from "./functions/api/push.js";

const RELEASES = "https://github.com/muni-works/frog/releases/latest/download";
const REDIRECTS = { "/download": `${RELEASES}/Frog.dmg`, "/appcast.xml": `${RELEASES}/appcast.xml` };

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

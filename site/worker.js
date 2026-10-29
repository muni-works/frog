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

export default {
  async fetch(request, env) {
    const { pathname } = new URL(request.url);
    if (pathname === "/v1" || pathname.startsWith("/v1/")) {
      if (!env.GATEWAY_ORIGIN) return new Response("no gateway\n", { status: 503 });
      return fetch(toGateway(request, env.GATEWAY_ORIGIN));
    }
    if (pathname === "/api/push") return push({ request, env });
    if (REDIRECTS[pathname]) return Response.redirect(REDIRECTS[pathname], 302);
    return new Response("not found\n", { status: 404, headers: { "Content-Type": "text/plain" } });
  },
};

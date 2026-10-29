// frog.toys: static assets from this folder, plus the few routes that aren't files. Assets win;
// the worker only sees requests no file matched (wrangler.jsonc: not_found_handling "none").
import { onRequest as push } from "./functions/api/push.js";

const RELEASES = "https://github.com/muni-works/frog/releases/latest/download";
const REDIRECTS = { "/download": `${RELEASES}/Frog.dmg`, "/appcast.xml": `${RELEASES}/appcast.xml` };

export default {
  async fetch(request, env) {
    const { pathname } = new URL(request.url);
    if (pathname === "/api/push") return push({ request, env });
    if (REDIRECTS[pathname]) return Response.redirect(REDIRECTS[pathname], 302);
    return new Response("not found\n", { status: 404, headers: { "Content-Type": "text/plain" } });
  },
};

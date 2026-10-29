// Bundles src/app.ts and copies the static files into dist/, ready for Cloudflare Pages.
// `--watch` also serves on :5173 and proxies /v1 (HTTP and websockets) to the gateway in
// $GATEWAY (default the mock on :8788), so the page and the gateway share an origin.
import { context, build } from "esbuild";
import { copyFileSync, mkdirSync } from "node:fs";
import { createServer, request } from "node:http";
import { connect } from "node:net";

mkdirSync("dist", { recursive: true });
for (const f of ["index.html", "style.css", "../../site/favicon.svg"]) copyFileSync(f, `dist/${f.split("/").pop()}`);
const opts = { entryPoints: ["src/app.ts"], bundle: true, format: "esm", target: "es2022", outfile: "dist/app.js", sourcemap: true };

if (!process.argv.includes("--watch")) {
  await build({ ...opts, minify: true });
} else {
  const ctx = await context(opts);
  await ctx.watch();
  const files = await ctx.serve({ servedir: "dist", host: "127.0.0.1", port: 0 });
  const gateway = new URL(process.env.GATEWAY ?? "http://127.0.0.1:8788");
  const target = (path) => (path.startsWith("/v1/") || path === "/v1" ? { host: gateway.hostname, port: gateway.port } : { host: files.host, port: files.port });
  const server = createServer((req, res) => {
    const up = request({ ...target(req.url), path: req.url, method: req.method, headers: req.headers }, (r) => {
      res.writeHead(r.statusCode, r.headers);
      r.pipe(res);
    });
    up.on("error", () => res.writeHead(502).end("gateway unreachable"));
    req.pipe(up);
  });
  server.on("upgrade", (req, socket, head) => {
    const t = target(req.url);
    const up = connect(t.port, t.host, () => {
      const lines = [`${req.method} ${req.url} HTTP/1.1`, ...Object.entries(req.headers).map(([k, v]) => `${k}: ${v}`)];
      up.write(lines.join("\r\n") + "\r\n\r\n");
      up.write(head);
      up.pipe(socket).pipe(up);
    });
    up.on("error", () => socket.destroy());
    socket.on("error", () => up.destroy());
  });
  server.listen(5173, () => console.log(`http://localhost:5173 (gateway ${gateway.origin})`));
}

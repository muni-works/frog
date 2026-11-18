#!/usr/bin/env node
// The web shell's screenshots: runs the mock gateway and vite, then drives headless Chrome over
// the DevTools protocol (no Puppeteer; the `ws` package the web app already has), light and dark.
//
//   node docs/design/app-shell/capture.mjs [name-filter]
//
// Needs `npm ci` in apps/web and Google Chrome (CHROME= to point elsewhere). Signed-in shots seed a
// key in localStorage and talk to the mock (apps/web/test/mock), whose data is made up.
import { spawn } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const HERE = fileURLToPath(new URL(".", import.meta.url));
const WEB = fileURLToPath(new URL("../../../apps/web/", import.meta.url));
const require = createRequire(join(WEB, "package.json"));
const WebSocket = require("ws");
const { startMock } = await import(join(WEB, "test/mock/mock-gateway.mjs"));
const SHOTS = (await import(join(HERE, "shots.mjs"))).default;
const only = process.argv[2];

const mock = await startMock({ port: 0, delayMs: 1 });
const VPORT = Number(process.env.VITE_PORT ?? 5287);
const ORIGIN = `http://127.0.0.1:${VPORT}`;
const vite = spawn(join(WEB, "node_modules/.bin/vite"), ["--host", "127.0.0.1", "--port", String(VPORT), "--strictPort"], {
  cwd: WEB, stdio: ["ignore", "pipe", "pipe"], env: { ...process.env, GATEWAY: `http://127.0.0.1:${mock.port}`, VITE_API: ORIGIN, VITE_GATEWAY: ORIGIN },
});
for (let i = 0; i < 80; i++) {
  if (await fetch(ORIGIN).then((r) => r.ok, () => false)) break;
  await new Promise((r) => setTimeout(r, 250));
}

const chrome = process.env.CHROME ?? "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const profile = mkdtempSync(join(tmpdir(), "frog-shell-"));
const proc = spawn(chrome, ["--headless=new", "--remote-debugging-port=0", `--user-data-dir=${profile}`, "--hide-scrollbars", "about:blank"], { stdio: ["ignore", "ignore", "pipe"] });
const wsUrl = await new Promise((resolve, reject) => {
  let buf = "";
  proc.stderr.on("data", (d) => { buf += d; const m = /DevTools listening on (ws:\/\/\S+)/.exec(buf); if (m) resolve(m[1]); });
  setTimeout(() => reject(new Error("chrome didn't start")), 15000);
});
const port = new URL(wsUrl).port;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function shoot(shot, look) {
  // A fresh target per shot: clean storage, its own size.
  const t = await (await fetch(`http://127.0.0.1:${port}/json/new?about:blank`, { method: "PUT" })).json();
  const ws = new WebSocket(t.webSocketDebuggerUrl);
  await new Promise((r) => ws.on("open", r));
  let n = 0;
  const call = (method, params = {}) => new Promise((resolve) => {
    const id = ++n;
    const on = (m) => { const v = JSON.parse(m); if (v.id === id) { ws.off("message", on); resolve(v.result); } };
    ws.on("message", on);
    ws.send(JSON.stringify({ id, method, params }));
  });
  const [w, h] = shot.size ?? [1280, 800];
  await call("Emulation.setDeviceMetricsOverride", { width: w, height: h, deviceScaleFactor: 2, mobile: false });
  await call("Emulation.setEmulatedMedia", { features: [{ name: "prefers-color-scheme", value: look }, { name: "prefers-reduced-motion", value: "reduce" }] });
  await call("Page.enable");
  await call("Runtime.enable");
  const storage = { "frog.newModel": "glm-5.3-flash", ...(shot.storage ?? {}) };
  await call("Page.addScriptToEvaluateOnNewDocument", { source: `try { localStorage.clear(); for (const [k, v] of Object.entries(${JSON.stringify(storage)})) localStorage.setItem(k, v) } catch {}` });
  await call("Page.navigate", { url: ORIGIN + (shot.path ?? "/") });
  await sleep(2500);
  for (const step of shot.steps ?? []) {
    if (typeof step === "number") { await sleep(step); continue; }
    const r = await call("Runtime.evaluate", { expression: `(async () => { ${step} })()`, awaitPromise: true });
    if (r?.exceptionDetails) console.error(`${shot.name}: step failed: ${step}\n${r.exceptionDetails.exception?.description ?? r.exceptionDetails.text}`);
    await sleep(500);
  }
  await call("Runtime.evaluate", { expression: "document.activeElement?.blur?.()" });
  const { data } = await call("Page.captureScreenshot", { format: "png" });
  const out = join(HERE, `${shot.name}-${look}.png`);
  writeFileSync(out, Buffer.from(data, "base64"));
  ws.close();
  await fetch(`http://127.0.0.1:${port}/json/close/${t.id}`).catch(() => {});
  console.log(out.replace(process.cwd() + "/", ""));
}

try {
  for (const shot of SHOTS.filter((s) => !only || s.name.includes(only))) for (const look of ["light", "dark"]) await shoot(shot, look);
} finally {
  proc.kill();
  vite.kill();
  await mock.close();
  await new Promise((r) => proc.once("exit", r));
  try { rmSync(profile, { recursive: true, force: true, maxRetries: 5 }); } catch {}
}

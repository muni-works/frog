// Headless Chrome over the DevTools protocol, as in docs/design/parity/web-shot.mjs: no Puppeteer,
// just the `ws` package the web app already has. Its own throwaway profile, never a window.
import { spawn } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { createRequire } from "node:module";

const require = createRequire(new URL("../../../apps/web/package.json", import.meta.url));
const WebSocket = require("ws");
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

export async function launch({ width, height, scale = 2, look = "dark", storage = {} }) {
  const chrome = process.env.CHROME ?? "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
  const profile = mkdtempSync(join(tmpdir(), "frog-reel-"));
  const proc = spawn(chrome, ["--headless=new", "--remote-debugging-port=0", `--user-data-dir=${profile}`, "--hide-scrollbars", "--no-first-run", "--no-default-browser-check", "about:blank"], { stdio: ["ignore", "ignore", "pipe"] });
  const wsUrl = await new Promise((resolve, reject) => {
    let buf = "";
    proc.stderr.on("data", (d) => { buf += d; const m = /DevTools listening on (ws:\/\/\S+)/.exec(buf); if (m) resolve(m[1]); });
    setTimeout(() => reject(new Error("chrome didn't start")), 15000);
  });
  const port = new URL(wsUrl).port;
  const target = (await (await fetch(`http://127.0.0.1:${port}/json/list`)).json()).find((t) => t.type === "page");
  const ws = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((r) => ws.on("open", r));
  let n = 0;
  const call = (method, params = {}) => new Promise((resolve, reject) => {
    const id = ++n;
    const on = (m) => { const v = JSON.parse(m); if (v.id === id) { ws.off("message", on); v.error ? reject(new Error(`${method}: ${v.error.message}`)) : resolve(v.result); } };
    ws.on("message", on);
    ws.send(JSON.stringify({ id, method, params }));
  });
  await call("Emulation.setDeviceMetricsOverride", { width, height, deviceScaleFactor: scale, mobile: false });
  await call("Emulation.setEmulatedMedia", { features: [{ name: "prefers-color-scheme", value: look }, { name: "prefers-reduced-motion", value: "reduce" }] });
  await call("Page.enable");
  await call("Page.addScriptToEvaluateOnNewDocument", { source: `try { for (const [k, v] of Object.entries(${JSON.stringify(storage)})) localStorage.setItem(k, v) } catch {}` });

  const page = {
    call,
    sleep,
    async go(url, wait = 4000) { await call("Page.navigate", { url }); await sleep(wait); },
    async eval(expression) {
      const r = await call("Runtime.evaluate", { expression, returnByValue: true, awaitPromise: true });
      if (r.exceptionDetails) throw new Error(`eval: ${r.exceptionDetails.exception?.description ?? r.exceptionDetails.text}`);
      return r.result.value;
    },
    async rect(selector) {
      return page.eval(`(() => { const e = document.querySelector(${JSON.stringify(selector)}); if (!e) return null; const r = e.getBoundingClientRect(); return { x: r.x, y: r.y, w: r.width, h: r.height }; })()`);
    },
    async click(selector) {
      const r = await page.rect(selector);
      if (!r) throw new Error(`no element ${selector}`);
      const x = r.x + r.w / 2, y = r.y + r.h / 2;
      for (const type of ["mouseMoved", "mousePressed", "mouseReleased"]) await call("Input.dispatchMouseEvent", { type, x, y, button: "left", clickCount: 1 });
      return { x, y };
    },
    async focus(selector) { await page.eval(`document.querySelector(${JSON.stringify(selector)})?.focus()`); },
    async type(text) { await call("Input.insertText", { text }); },
    async key(key, code = key, keyCode = 0) {
      await call("Input.dispatchKeyEvent", { type: "keyDown", key, code, windowsVirtualKeyCode: keyCode });
      await call("Input.dispatchKeyEvent", { type: "keyUp", key, code, windowsVirtualKeyCode: keyCode });
    },
    async shot(out) {
      mkdirSync(dirname(out), { recursive: true });
      const { data } = await call("Page.captureScreenshot", { format: "png" });
      writeFileSync(out, Buffer.from(data, "base64"));
    },
    async close() {
      ws.close(); proc.kill();
      await new Promise((r) => proc.once("exit", r));
      try { rmSync(profile, { recursive: true, force: true, maxRetries: 5 }); } catch {}
    },
  };
  return page;
}

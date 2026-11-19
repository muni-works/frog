// The App in headless Chrome over the DevTools protocol, for tests that need real layout and
// real input (test/scroll-to-reply.test.ts, test/open-at-rest.test.ts). Callers skip without
// Chrome (`chrome` from chrome.ts is null).
import { spawn } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import WebSocket from "ws";
import { chrome } from "./chrome.ts";

export type Page = { eval: <T>(expr: string) => Promise<T>; call: (method: string, params?: object) => Promise<unknown>; close: () => Promise<void> };

/** The App at w × h in headless Chrome over the DevTools protocol. */
export async function open(url: string, w: number, h: number, reducedMotion = false, init?: string): Promise<Page> {
  const profile = mkdtempSync(join(tmpdir(), "frog-scroll-chrome-"));
  const linux = process.platform === "linux" ? ["--no-sandbox"] : [];
  const proc = spawn(chrome!, ["--headless=new", "--remote-debugging-port=0", `--user-data-dir=${profile}`, "--hide-scrollbars", ...linux, "about:blank"], { stdio: ["ignore", "ignore", "pipe"] });
  const wsUrl = await new Promise<string>((resolve, reject) => {
    let buf = "";
    proc.stderr!.on("data", (d) => { buf += d; const m = /DevTools listening on (ws:\/\/\S+)/.exec(buf); if (m) resolve(m[1]); });
    setTimeout(() => reject(new Error("chrome didn't start")), 15000);
  });
  const targets = await (await fetch(`http://127.0.0.1:${new URL(wsUrl).port}/json/list`)).json() as { type: string; webSocketDebuggerUrl: string }[];
  const ws = new WebSocket(targets.find((t) => t.type === "page")!.webSocketDebuggerUrl);
  await new Promise((r) => ws.on("open", r));
  let n = 0;
  const call = (method: string, params: object = {}) => new Promise<unknown>((resolve) => {
    const id = ++n;
    const on = (m: WebSocket.RawData) => { const v = JSON.parse(String(m)); if (v.id === id) { ws.off("message", on); resolve(v.result); } };
    ws.on("message", on);
    ws.send(JSON.stringify({ id, method, params }));
  });
  await call("Emulation.setDeviceMetricsOverride", { width: w, height: h, deviceScaleFactor: 1, mobile: false });
  await call("Emulation.setEmulatedMedia", { features: [{ name: "prefers-reduced-motion", value: reducedMotion ? "reduce" : "no-preference" }] });
  await call("Page.enable");
  // A script that runs before the page's own (a recorder, say).
  if (init) await call("Page.addScriptToEvaluateOnNewDocument", { source: init });
  await call("Page.navigate", { url });
  const evalJS = async <T,>(expr: string) => ((await call("Runtime.evaluate", { expression: expr, returnByValue: true, awaitPromise: true })) as { result: { value: T } }).result.value;
  return {
    eval: evalJS, call,
    // Chrome's helpers can still be writing the profile after the browser exits (Linux CI:
    // ENOTEMPTY): retry, and never fail a test over a temp folder.
    close: async () => { ws.close(); proc.kill(); await new Promise((r) => proc.once("exit", r)); try { rmSync(profile, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 }); } catch { /* left in tmp */ } },
  };
}

export const until = async (f: () => Promise<boolean>, ms = 20000) => { const end = Date.now() + ms; while (Date.now() < end) { if (await f()) return true; await new Promise((r) => setTimeout(r, 100)); } return false; };
export const pause = (ms: number) => new Promise((r) => setTimeout(r, ms));

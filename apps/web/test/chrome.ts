// Headless Chrome for layout tests: a vite dev server on a free port serving parity/, and Chrome's
// --dump-dom and --screenshot to read and draw a parity page. No Chrome (CI's runners, a Linux box
// without it): `chrome` is null and the tests that need it skip.
import { execFile } from "node:child_process";
import { existsSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const run = promisify(execFile);

const CANDIDATES = [
  process.env.CHROME,
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
  "/Applications/Chromium.app/Contents/MacOS/Chromium",
  "/usr/bin/google-chrome",
  "/usr/bin/chromium",
  "/usr/bin/chromium-browser",
];

export const chrome: string | null = CANDIDATES.find((p): p is string => !!p && existsSync(p)) ?? null;

/** A vite dev server for this app on a free port; `close` when done. */
export async function serve(): Promise<{ origin: string; close: () => Promise<void> }> {
  const { createServer } = await import("vite");
  const root = fileURLToPath(new URL("..", import.meta.url));
  const server = await createServer({ root, configFile: join(root, "vite.config.ts"), logLevel: "error", server: { port: 0, host: "127.0.0.1", strictPort: false } });
  await server.listen();
  const addr = server.httpServer?.address();
  if (!addr || typeof addr === "string") throw new Error("vite didn't listen");
  return { origin: `http://127.0.0.1:${addr.port}`, close: () => server.close() };
}

/** Chrome's flags for one throwaway profile at a window size. */
function flags(profile: string, w: number, h: number): string[] {
  return [
    "--headless=new", "--disable-gpu", "--no-first-run", "--no-default-browser-check", "--hide-scrollbars",
    "--disable-extensions", "--mute-audio", `--user-data-dir=${profile}`, `--window-size=${w},${h}`,
    "--virtual-time-budget=6000", "--run-all-compositor-stages-before-draw",
    // Ubuntu's AppArmor stops Chrome's own sandbox on CI runners; the pages here are ours.
    ...(process.platform === "linux" ? ["--no-sandbox"] : []),
  ];
}

async function withProfile<T>(f: (profile: string) => Promise<T>): Promise<T> {
  const profile = mkdtempSync(join(tmpdir(), "frog-chrome-"));
  try { return await f(profile); } finally { rmSync(profile, { recursive: true, force: true }); }
}

/** The page's DOM once its scripts have run (and virtual time has passed). */
export function dumpDOM(url: string, w: number, h: number): Promise<string> {
  if (!chrome) throw new Error("no Chrome");
  const bin = chrome;
  return withProfile(async (profile) => (await run(bin, [...flags(profile, Math.max(800, w + 200), h + 200), "--dump-dom", url], { maxBuffer: 32 << 20, timeout: 60_000 })).stdout);
}

/** A PNG of the page's top-left w × h. Headless Chrome won't make a window under about 500 px
 * wide, so it draws a roomy window and crops it (macOS's sips) from (1, 1), where parity pages start. */
export function screenshot(url: string, w: number, h: number, out: string): Promise<void> {
  if (!chrome) throw new Error("no Chrome");
  const bin = chrome;
  return withProfile(async (profile) => {
    await run(bin, [...flags(profile, Math.max(800, w + 200), h + 200), `--screenshot=${out}`, url], { timeout: 60_000 });
    await run("sips", ["--cropToHeightWidth", String(h), String(w), "--cropOffset", "1", "1", out, "--out", out]);
  });
}

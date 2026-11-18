// Draws the credit wall's states from the real App against the mock gateway into
// docs/design/credit-wall as <state>-<theme>.png (headless Chrome; macOS, for sips).
// `node --import tsx test/shoot-wall.ts`
import { execFile } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { createServer as listen } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import WebSocket from "ws";
import { startMock } from "./mock/mock-gateway.mjs";
import { chrome } from "./chrome.ts";

if (!chrome) throw new Error("no Chrome");
const out = fileURLToPath(new URL("../../../docs/design/credit-wall/", import.meta.url));
const KEY = "frog_shots";
const W = 1000, H = 720;

const run = promisify(execFile);
const freePort = () => new Promise<number>((r) => { const s = listen().listen(0, "127.0.0.1", () => { const p = (s.address() as { port: number }).port; s.close(() => r(p)); }); });

const mock = await startMock({ port: 0, delayMs: 0, autoAllow: true, previewScript: "" });
const api = `http://127.0.0.1:${mock.port}`;
// The page's /v1 (account routes and sessions) goes to the vite server, which proxies to the mock:
// nothing reaches api.frog.toys.
const port = await freePort();
process.env.GATEWAY = api;
process.env.VITE_API = `http://127.0.0.1:${port}`;
const { createServer } = await import("vite");
const vite = await createServer({ root: fileURLToPath(new URL("..", import.meta.url)), logLevel: "error", server: { port, host: "127.0.0.1", strictPort: true } });
await vite.listen();
const site = { origin: `http://127.0.0.1:${port}`, close: () => vite.close() };

/** The page at exactly W × H. */
async function screenshot(url: string, file: string) {
  const profile = mkdtempSync(join(tmpdir(), "frog-wall-"));
  try {
    await run(chrome!, ["--headless=new", "--disable-gpu", "--no-first-run", "--no-default-browser-check", "--hide-scrollbars", "--disable-extensions", "--mute-audio",
      `--user-data-dir=${profile}`, `--window-size=${W},${H}`, "--virtual-time-budget=8000", "--run-all-compositor-stages-before-draw", `--screenshot=${file}`, url], { timeout: 60_000 });
  } finally { rmSync(profile, { recursive: true, force: true }); }
}

const call = (path: string, body?: unknown) => fetch(api + path, { method: body ? "POST" : "GET", headers: { authorization: `Bearer ${KEY}`, "content-type": "application/json" }, body: body ? JSON.stringify(body) : undefined }).then((r) => r.json());

try {
  const s = (await call("/v1/sessions", { repo: "ada/notes" })) as { id: string; ws: string };
  const ws = new WebSocket(s.ws, ["frog", `bearer.${KEY}`]);
  const ended: ((e: { reason: { type: string } }) => void)[] = [];
  ws.on("message", (d) => {
    const v = JSON.parse(String(d));
    if (v.event === "turn_ended") ended.shift()?.(v);
  });
  await new Promise((r) => ws.on("open", r));
  ws.send(JSON.stringify({ hello: { protocol: 1, client: "shoot-wall", resume_after: 1e9 } }));
  const turn = (op: Record<string, unknown>) => new Promise<{ reason: { type: string } }>((r) => { ended.push(r); ws.send(JSON.stringify(op)); });
  for (const text of ["add a README", "now add tests", "run the linter", "fix the warnings", "update the changelog"]) await turn({ op: "submit", text });

  const shoot = async (name: string, extra = "") => {
    for (const theme of ["dark", "light"]) {
      await screenshot(`${site.origin}/parity/app.html?key=${KEY}&session=${s.id}&theme=${theme}${extra}`, `${out}${name}-${theme}.png`);
      console.log(`${name}-${theme}.png`);
    }
  };

  // A: the warning, with $10 last added and $1.94 left (six 6¢ turns to average).
  await call("/v1/mock/credit", { cents: 194 });
  await shoot("warning");

  // B: the wall, after a turn that stopped on credit between steps.
  await call("/v1/mock/credit", { cents: 2 });
  const stop = await turn({ op: "submit", text: "refactor auth/session.ts and run the tests" });
  if (stop.reason.type !== "billing_limit") throw new Error(`expected billing_limit, got ${stop.reason.type}`);
  await shoot("wall");
  await shoot("wall-code", `&click=${encodeURIComponent("Have a code?")}`);

  // C: after paying: a code redeemed, and the turn resumed with the wall's note.
  await call("/v1/coupons/redeem", { code: "LAUNCH5" });
  await turn({ op: "continue", note: "<resumed after $5.00 of Frog Cloud credit was added; your previous turn stopped when credit ran out, between steps; continue where you left off>" });
  await shoot("resumed");
  ws.close();
} finally {
  await site.close();
  await mock.close();
}

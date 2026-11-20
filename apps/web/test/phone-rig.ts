// The real App on a phone-sized screen against the mock gateway, for the phone layout tests
// (test/phone-layout.test.ts) and screenshots (test/shoot-phone.ts). The page's /v1 goes to a
// vite server that proxies to the mock, so nothing reaches api.frog.toys; any key is an account.
// Chrome over the DevTools protocol (test/cdp.ts) at w × h, as a touch phone.
import { writeFileSync } from "node:fs";
import { createServer as listen } from "node:net";
import { fileURLToPath } from "node:url";
import WebSocket from "ws";
import { startMock } from "./mock/mock-gateway.mjs";
import { open, until, type Page } from "./cdp.ts";

const freePort = () => new Promise<number>((r) => { const s = listen().listen(0, "127.0.0.1", () => { const p = (s.address() as { port: number }).port; s.close(() => r(p)); }); });

export interface Rig {
  origin: string
  /** An account route on the mock, as `key`. */
  call: (key: string, path: string, body?: unknown) => Promise<unknown>
  /** A session for `key` with these turns played (each a 6¢ mock turn). */
  session: (key: string, turns: string[], repo?: string) => Promise<string>
  /** More turns in a session. */
  play: (key: string, id: string, turns: string[]) => Promise<void>
  /** The app at `path`, signed in as `key` (or signed out), on a w × h touch screen. */
  phone: (path: string, w: number, h: number, key?: string | null, theme?: "dark" | "light") => Promise<Page>
  close: () => Promise<void>
}

/** `fixture`: the recording a turn plays (test/mock/wide.jsonl has a long diff, table and code
 *  line); `fresh`: a new session's log starts empty, so what it cost is what was played. */
export async function rig({ fixture, fresh = false }: { fixture?: string; fresh?: boolean } = {}): Promise<Rig> {
  const mock = await startMock({ port: 0, delayMs: 0, autoAllow: true, previewScript: "", fresh, ...(fixture ? { fixture } : {}) });
  const api = `http://127.0.0.1:${mock.port}`;
  const port = await freePort();
  process.env.GATEWAY = api;
  process.env.VITE_API = `http://127.0.0.1:${port}`;
  const { createServer } = await import("vite");
  const vite = await createServer({ root: fileURLToPath(new URL("..", import.meta.url)), logLevel: "error", server: { port, host: "127.0.0.1", strictPort: true } });
  await vite.listen();
  const origin = `http://127.0.0.1:${port}`;
  const call = (key: string, path: string, body?: unknown) => fetch(api + path, { method: body ? "POST" : "GET", headers: { authorization: `Bearer ${key}`, "content-type": "application/json" }, body: body ? JSON.stringify(body) : undefined }).then((r) => r.json());
  /** Plays these turns in a session (each a 6¢ mock turn, or a stop on credit). */
  const play = async (key: string, id: string, turns: string[], url = `ws://127.0.0.1:${mock.port}/v1/sessions/${id}/ws`) => {
    if (!turns.length) return;
    const ws = new WebSocket(url, ["frog", `bearer.${key}`]);
    const ended: (() => void)[] = [];
    ws.on("message", (d) => { if (JSON.parse(String(d)).event === "turn_ended") ended.shift()?.(); });
    await new Promise((r) => ws.on("open", r));
    ws.send(JSON.stringify({ hello: { protocol: 1, client: "phone-rig", resume_after: 1e9 } }));
    for (const text of turns) await new Promise<void>((r) => { ended.push(r); ws.send(JSON.stringify({ op: "submit", text })); });
    ws.close();
  };
  const session = async (key: string, turns: string[], repo?: string) => {
    const s = (await call(key, "/v1/sessions", repo ? { repo } : {})) as { id: string; ws: string };
    await play(key, s.id, turns, s.ws);
    return s.id;
  };
  const phone = async (path: string, w: number, h: number, key: string | null = null, theme: "dark" | "light" = "dark") => {
    const init = `try { ${key ? `localStorage.setItem('frog.key', ${JSON.stringify(key)});` : "localStorage.removeItem('frog.key');"} localStorage.setItem('frog.theme', ${JSON.stringify(theme)}) } catch (e) {}`;
    const page = await open(`${origin}${path}`, w, h, false, init);
    // A touch phone: mobile viewport and touch, then load again so the page sees them from the start.
    await page.call("Emulation.setDeviceMetricsOverride", { width: w, height: h, deviceScaleFactor: 2, mobile: true });
    await page.call("Emulation.setTouchEmulationEnabled", { enabled: true, maxTouchPoints: 5 });
    await page.call("Emulation.setEmulatedMedia", { features: [{ name: "prefers-color-scheme", value: theme }] });
    await page.call("Page.reload");
    await until(() => page.eval<boolean>("!!document.querySelector('#root > *')"));
    return page;
  };
  return { origin, call, session, play: (k: string, id: string, t: string[]) => play(k, id, t), phone, close: async () => { await vite.close(); await mock.close(); } };
}

/** A PNG of what's on screen. */
export async function shot(page: Page, file: string) {
  const r = (await page.call("Page.captureScreenshot", { format: "png" })) as { data: string };
  writeFileSync(file, Buffer.from(r.data, "base64"));
}

/** Boxes that scroll sideways on purpose: code, diffs, tables, a terminal. Everything else fits. */
export const SIDEWAYS = "pre, .diff, .hunks, .md-table, .md-code, .term, .tp-body, .cz-q";

/** What a phone layout must hold: no box scrolls sideways but SIDEWAYS ones (the transcript, a
 *  sheet, Settings never do), nothing reaches past the screen's edges outside them, every visible
 *  control at least 44 px tall (its ::after hit area counts; inline links in running text don't
 *  need it), and named. */
export const AUDIT = `(() => {
  const W = innerWidth;
  const SIDEWAYS = ${JSON.stringify("pre, .diff, .hunks, .md-table, .md-code, .term, .tp-body, .cz-q")};
  const name = (el) => el.tagName + '.' + String(el.className).split(' ').filter(Boolean).slice(0, 2).join('.');
  const shown = (el) => { const r = el.getBoundingClientRect(); if (!r.width || !r.height) return false; const s = getComputedStyle(el); return s.visibility !== 'hidden' && s.display !== 'none'; };
  const over = Math.max(0, document.documentElement.scrollWidth - W);
  const all = [...document.querySelectorAll('body *')];
  const sideways = all.filter((el) => { const s = getComputedStyle(el); return (s.overflowX === 'auto' || s.overflowX === 'scroll') && el.clientWidth > 0 && el.scrollWidth > el.clientWidth + 1 && !el.matches(SIDEWAYS); }).slice(0, 5).map(name);
  const wide = all.filter(shown).filter((el) => !el.closest(SIDEWAYS) && !el.closest('.sr, .sr-only')).filter((el) => { const r = el.getBoundingClientRect(); return r.right > W + 0.5 || r.left < -0.5; }).slice(0, 5).map(name);
  const visible = (el) => { if (!shown(el)) return false; const r = el.getBoundingClientRect(); return r.bottom > 0 && r.top < innerHeight && r.right > 0 && r.left < innerWidth; };
  // The tap area: the box, or a larger ::after hit area (app.css's touch insets).
  const tap = (el) => { const h = el.getBoundingClientRect().height; const a = getComputedStyle(el, '::after'); return a.content !== 'none' && a.position === 'absolute' ? Math.max(h, h - (parseFloat(a.top) || 0) - (parseFloat(a.bottom) || 0)) : h; };
  const small = [...document.querySelectorAll('button, a[href], [role=radio], input, select, textarea')]
    .filter(visible).filter((el) => !el.closest('p, .det, .md, [aria-hidden=true]'))
    // A switch inside its row's label: the row is what takes the tap.
    .filter((el) => !(el.tagName === 'INPUT' && el.closest('label') && el.closest('label').getBoundingClientRect().height >= 43.5))
    .filter((el) => tap(el) < 43.5)
    .slice(0, 8).map((el) => (el.getAttribute('aria-label') || el.textContent || el.tagName).trim().slice(0, 30) + ' ' + Math.round(tap(el)));
  return { over, sideways, wide, small };
})()`;

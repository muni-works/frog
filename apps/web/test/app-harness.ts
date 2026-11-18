// Renders the whole App under node: Vite's SSR loader runs src/App.tsx with import.meta.env and
// the docs bundle's import.meta.glob, and a few browser globals are stubbed here. Every fetch is
// recorded, so a test can say which calls a page made (and with which key).
import { createServer, type ViteDevServer } from "vite";
import { createElement as h } from "react";
import TestRenderer, { act, type ReactTestRenderer } from "react-test-renderer";

(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

export interface Call { url: string; method: string; auth: string | null; body?: string }
export type Responder = (url: string, init: RequestInit) => { status?: number; body: unknown } | undefined

class MemStorage {
  m = new Map<string, string>();
  getItem(k: string) { return this.m.has(k) ? this.m.get(k)! : null; }
  setItem(k: string, v: string) { this.m.set(k, String(v)); }
  removeItem(k: string) { this.m.delete(k); }
  clear() { this.m.clear(); }
  key(i: number) { return [...this.m.keys()][i] ?? null; }
  get length() { return this.m.size; }
}

let server: ViteDevServer | null = null;
let App: (() => JSX.Element) | null = null;

/** The App module, loaded once per test file. */
async function app() {
  if (App) return App;
  server ??= await createServer({ root: new URL("..", import.meta.url).pathname, logLevel: "silent", server: { middlewareMode: true, hmr: false, watch: null }, appType: "custom", optimizeDeps: { noDiscovery: true, include: [] } });
  App = ((await server.ssrLoadModule("/src/App.tsx")) as { default: () => JSX.Element }).default;
  return App;
}

export async function closeHarness() { await server?.close(); server = null; App = null; }

const listeners = new Map<string, Set<(e: unknown) => void>>();
export function dispatch(type: string, e: Record<string, unknown>) {
  for (const f of [...(listeners.get(type) ?? [])]) f({ preventDefault() {}, stopPropagation() {}, ...e });
}

const nodeMock = () => {
  const el: Record<string, unknown> = { style: {}, getContext: () => null, focus() {}, blur() {}, scrollTo() {}, scrollIntoView() {}, addEventListener() {}, removeEventListener() {}, setSelectionRange() {},
    getBoundingClientRect: () => ({ top: 0, left: 0, right: 0, bottom: 0, width: 0, height: 0 }), querySelector: () => null, querySelectorAll: () => [], contains: () => false,
    closest: () => null, scrollTop: 0, scrollHeight: 0, clientHeight: 0, offsetHeight: 0, value: "", selectionStart: 0, selectionEnd: 0, dataset: {}, classList: { add() {}, remove() {}, toggle() {}, contains: () => false } };
  return el;
};

export interface Page { root: ReactTestRenderer; calls: Call[]; storage: MemStorage; path: () => string; unmount: () => void }

/** Mounts the App at `path` with `storage` in localStorage. */
export async function mount(path: string, { storage = {}, respond }: { storage?: Record<string, string>; respond?: Responder } = {}): Promise<Page> {
  const A = await app();
  const g = globalThis as Record<string, unknown>;
  const url = new URL(path, "https://frog.toys");
  const loc = { get pathname() { return url.pathname; }, get search() { return url.search; }, get origin() { return url.origin; }, get href() { return url.href; }, assign(u: string) { loc.assigned = u; }, reload() {}, assigned: "" as string };
  let state: unknown = null;
  const hist = { get state() { return state; }, pushState(s: unknown, _t: string, p: string) { state = s; const n = new URL(p, url); url.pathname = n.pathname; url.search = n.search; }, replaceState(s: unknown, _t: string, p: string) { hist.pushState(s, _t, p); } };
  const local = new MemStorage();
  for (const [k, v] of Object.entries(storage)) local.setItem(k, v);
  const calls: Call[] = [];
  listeners.clear();
  Object.assign(g, {
    location: loc, history: hist, localStorage: local, sessionStorage: new MemStorage(),
    addEventListener: (t: string, f: (e: unknown) => void) => { if (!listeners.has(t)) listeners.set(t, new Set()); listeners.get(t)!.add(f); },
    removeEventListener: (t: string, f: (e: unknown) => void) => { listeners.get(t)?.delete(f); },
    matchMedia: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
    requestAnimationFrame: (f: () => void) => setTimeout(f, 0), cancelAnimationFrame: (t: number) => clearTimeout(t),
    navigator: { clipboard: { writeText: async () => {} }, userAgent: "node" },
    confirm: () => true,
    Notification: undefined,
    document: { hidden: false, title: "", documentElement: { dataset: {} as Record<string, string>, style: {} }, querySelector: () => null, querySelectorAll: () => [], getElementById: () => null, addEventListener() {}, removeEventListener() {}, body: nodeMock(), activeElement: null },
    fetch: async (u: string | URL, init: RequestInit = {}) => {
      const s = String(u);
      const headers = (init.headers ?? {}) as Record<string, string>;
      calls.push({ url: s, method: init.method ?? "GET", auth: headers.authorization ?? null, body: typeof init.body === "string" ? init.body : undefined });
      const r = respond?.(s, init) ?? { status: 404, body: { error: { code: "not_found", message: "Not here." } } };
      const status = r.status ?? 200;
      return { ok: status >= 200 && status < 300, status, json: async () => r.body } as Response;
    },
  });
  g.window = g;
  let root!: ReactTestRenderer;
  await act(async () => { root = TestRenderer.create(h(A), { createNodeMock: nodeMock }); });
  await act(async () => { await new Promise((r) => setTimeout(r, 20)); });
  return { root, calls, storage: local, path: () => url.pathname + url.search, unmount: () => act(() => root.unmount()) };
}

/** All the text under a node, squashed. */
export const textOf = (n: { children?: unknown } | string): string =>
  typeof n === "string" ? n : ((n as { children?: unknown[] }).children ?? []).map((c) => textOf(c as never)).join(" ").replace(/\s+/g, " ");

export { act };

type Node = { type: unknown; props: Record<string, unknown>; children: (Node | string)[] };

/** Host elements that are on screen: not under a `display: none` (a mode's kept-but-hidden subtree). */
export function visible(n: Node | string, out: Node[] = []): Node[] {
  if (typeof n === "string") return out;
  if (typeof n.type === "string") {
    if ((n.props.style as { display?: string } | undefined)?.display === "none") return out;
    out.push(n);
  }
  for (const c of n.children) visible(c as Node, out);
  return out;
}

/** The visible text under a node. */
export function shownText(n: Node | string): string {
  if (typeof n === "string") return n;
  if (typeof n.type === "string" && (n.props.style as { display?: string } | undefined)?.display === "none") return "";
  return n.children.map((c) => shownText(c as Node)).join(" ").replace(/\s+/g, " ").trim();
}

/** The first visible host element matching. */
export function find(p: Page, pred: (n: Node) => boolean): Node | undefined {
  return visible(p.root.root as unknown as Node).find(pred);
}
export const hasClass = (c: string) => (n: Node) => typeof n.props.className === "string" && (n.props.className as string).split(/\s+/).includes(c);
export const byText = (type: string, t: string | RegExp) => (n: Node) => n.type === type && (typeof t === "string" ? shownText(n) === t || shownText(n).startsWith(t) : t.test(shownText(n)));
export async function click(n: Node | undefined, e: Record<string, unknown> = {}) {
  if (!n) throw new Error("nothing to click");
  await act(async () => { (n.props.onClick as (e: unknown) => void)({ preventDefault() {}, stopPropagation() {}, button: 0, ...e }); });
  await act(async () => { await new Promise((r) => setTimeout(r, 10)); });
}
export async function key(k: string, mods: Record<string, boolean> = { metaKey: true }) {
  await act(async () => { dispatch("keydown", { key: k, ...mods }); });
}
export type { Node as HostNode };

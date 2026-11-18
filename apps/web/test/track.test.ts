// Funnel events from the web app (src/track.ts): off unless the gateway says so, nothing but
// allow-listed words, and every web → Mac link counted from one click listener.
import { test, beforeEach } from "node:test";
import assert from "node:assert/strict";
import { configureTracking, handoffOf, noteSessions, sessionEvents, track, trackingOn } from "../src/track.ts";
import type { SessionSummary } from "../src/cloud/protocol.ts";

function recorder() {
  const sent: { url: string; init: RequestInit; body: any }[] = [];
  const send = (async (url: string, init: RequestInit) => {
    sent.push({ url, init, body: JSON.parse(String(init.body)) });
    return new Response(null, { status: 204 });
  }) as unknown as typeof fetch;
  return { sent, send };
}

const s = (id: string, f: Partial<SessionSummary> = {}): SessionSummary => ({ id, title: "t", repo: "ecto/secret", branch: "frog/x", state: "idle", updated: 1, ...f });

beforeEach(() => configureTracking(null, null));

test("off unless the gateway says events are on", () => {
  const { sent, send } = recorder();
  track("turn_finished", { client: "web" }, send);
  configureTracking("frog_k", { events: false });
  track("turn_finished", { client: "web" }, send);
  configureTracking("frog_k", {});
  track("turn_finished", { client: "web" }, send);
  configureTracking(null, { events: true });
  track("turn_finished", { client: "web" }, send);
  assert.equal(trackingOn(), false);
  assert.deepEqual(sent, []);
});

test("sends to the gateway with the key, never to PostHog, and only the event and its words", () => {
  const { sent, send } = recorder();
  configureTracking("frog_k", { events: true });
  track("handoff_clicked", { from: "web", to: "mac", where: "chip" }, send);
  assert.equal(sent.length, 1);
  assert.match(sent[0].url, /\/v1\/events$/);
  assert.doesNotMatch(sent[0].url, /posthog/);
  assert.equal((sent[0].init.headers as Record<string, string>).authorization, "Bearer frog_k");
  assert.equal(sent[0].init.keepalive, true);
  assert.deepEqual(sent[0].body, { event: "handoff_clicked", props: { from: "web", to: "mac", where: "chip" } });
});

test("a session list yields turn_finished and pr_opened, never the repo or the PR", () => {
  const prev = new Map([["a", s("a", { last_turn: 10 })], ["b", s("b")]]);
  const events = sessionEvents(prev, [s("a", { last_turn: 20 }), s("b", { pr: "ecto/secret#7" }), s("c", { last_turn: 5, pr: "ecto/secret#8" })]);
  assert.deepEqual(events, [
    { event: "turn_finished", props: { client: "web" } },
    { event: "pr_opened", props: { client: "web" } },
  ]);
  assert.doesNotMatch(JSON.stringify(events), /secret|#7|frog\/x/);
  // Nothing moved: nothing to say.
  assert.deepEqual(sessionEvents(new Map([["a", s("a", { last_turn: 20, pr: "x#1" })]]), [s("a", { last_turn: 20, pr: "x#1" })]), []);
});

test("the first list after sign-in is a baseline, the next one is diffed", () => {
  const { sent, send } = recorder();
  configureTracking("frog_k", { events: true });
  noteSessions([s("a", { last_turn: 1, pr: "x#1" })], send);
  assert.equal(sent.length, 0);
  noteSessions([s("a", { last_turn: 2, pr: "x#1" })], send);
  assert.deepEqual(sent.map((x) => x.body.event), ["turn_finished"]);
  // A different key starts over.
  configureTracking("frog_other", { events: true });
  noteSessions([s("a", { last_turn: 3 })], send);
  assert.equal(sent.length, 1);
});

// A tiny element tree with just enough of closest() for handoffOf.
interface El { tag: string; attrs: Record<string, string>; cls: string[]; parent: El | null; closest(sel: string): El | null; getAttribute(n: string): string | null }
function el(tag: string, attrs: Record<string, string> = {}, parent: El | null = null): El {
  const cls = (attrs.class ?? "").split(/\s+/).filter(Boolean);
  const self: El = {
    tag, attrs, cls, parent,
    getAttribute: (n) => attrs[n] ?? null,
    closest(sel) {
      const one = (e: El, q: string): boolean => {
        q = q.trim();
        if (q === "a[href]") return e.tag === "a" && "href" in e.attrs;
        if (q.startsWith(".")) return e.cls.includes(q.slice(1));
        const m = /^\[([\w-]+)(?:="([^"]*)")?\]$/.exec(q);
        if (m) return m[2] === undefined ? m[1] in e.attrs : e.attrs[m[1]] === m[2];
        return false;
      };
      for (let e: El | null = self; e; e = e.parent) if (sel.split(",").some((q) => one(e!, q))) return e;
      return null;
    },
  };
  return self;
}
const link = (href: string, container: El | null) => el("a", { href }, container) as unknown as Element;

test("hand-off clicks: where comes from the container, only Mac links count", () => {
  assert.equal(handoffOf(link("/download", el("div", { "data-chip": "mac-app" }))), "chip");
  assert.equal(handoffOf(link("/mac", el("section", { "aria-label": "Out of credit" }))), "credit_wall");
  assert.equal(handoffOf(link("/mac", el("div", { class: "cz-menu" }, el("div", { class: "cz" })))), "composer");
  assert.equal(handoffOf(link("/mac", el("div", { class: "set-row" }))), "settings");
  assert.equal(handoffOf(link("/mac", el("nav", { class: "foot-links" }))), "footer");
  assert.equal(handoffOf(link("https://frog.toys/mac?x=1", el("div"))), "other");
  assert.equal(handoffOf(link("/pricing", el("nav", { class: "foot-links" }))), null);
  assert.equal(handoffOf(el("button") as unknown as Element), null);
  assert.equal(handoffOf(null), null);
});

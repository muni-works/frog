// The credit wall (onboarding funnel, board 3): the 80% warning, the wall card, and pay and
// resume. Pure parts from src/wall.ts; the card and the warning rendered; the resume through
// ui/wallResume.ts with a fake socket and /v1/me, as the App wires it.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createElement as h, StrictMode } from "react";
import TestRenderer, { act } from "react-test-renderer";
import { renderToStaticMarkup } from "react-dom/server";
import { Transcript } from "../src/ui/Transcript.tsx";
import type { Account } from "../src/auth.ts";
import type { EndReason, Op } from "../src/cloud/protocol.ts";
import { emptyThread, type Thread } from "../src/engine/thread.ts";
import type { Model } from "../src/models.ts";
import { aboutTurns, averageTurn, cardFeeCents, lastAddedCents, leftLine, lowCredit, MIN_TURNS, resumedLine, resumeNote, savePending, sessionSpend, shouldResume, stoppedTurn, takePending } from "../src/wall.ts";
import { CreditWall } from "../src/ui/CreditWall.tsx";
import { CreditWarning } from "../src/ui/CreditWarning.tsx";
import { useWallResume, type WallResumeDeps } from "../src/ui/wallResume.ts";

(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

// A model at 1¢ per 1,000 output tokens; each turn below writes 6,000: 6¢ a turn.
const MODELS: Model[] = [{ id: "glm-5.3-flash", context: 131072, input: 0, output: 0.00001, cached: 0 }];
const usage = (out = 6000) => ({ context_tokens: null, input_tokens: 0, output_tokens: out, model_calls: 1, model: "cloud/glm-5.3-flash" });
type Turn = Thread["turns"][number];
const turn = (n: number, reason: EndReason = { type: "complete" }, input = `task ${n}`): Turn => ({ turn: n, input, entries: [], usage: usage(), reason });
const thread = (n: number, last: EndReason = { type: "complete" }): Thread => {
  const turns = Array.from({ length: n }, (_, i) => turn(i + 1, i === n - 1 ? last : { type: "complete" }))
  return { ...emptyThread, turns, ended: turns.at(-1)?.reason ?? null }
};
const stopped = (n: number) => thread(n, { type: "billing_limit", window: "credit", reason: "out of credit" });
const acct = (credit: number, over: Partial<Account> = {}): Account => ({ plan: "free", handle: "ada", email: null, credit_cents: credit, resets_at: null, subscription: null, ...over });

type Node = TestRenderer.ReactTestInstance;
const text = (n: Node | string): string => (typeof n === "string" ? n : n.children.map(text).join(""));
const all = (r: TestRenderer.ReactTestRenderer) => text(r.root as unknown as Node).replace(/\s+/g, " ");
const button = (r: TestRenderer.ReactTestRenderer, t: string | RegExp) => r.root.find((n) => n.type === "button" && (typeof t === "string" ? text(n) === t : t.test(text(n))));

// ---------- the warning ----------

test("the warning shows once 80% of the last credit added is spent, not before, and never at zero", () => {
  // $10 added: the line at $2 left (80% spent), not at $2.01.
  assert.equal(lowCredit(acct(201), 1000), false);
  assert.equal(lowCredit(acct(200), 1000), true);
  assert.equal(lowCredit(acct(1), 1000), true);
  assert.equal(lowCredit(acct(0), 1000), false, "empty is the wall, not the warning");
  // On a plan inside its allowance, credit isn't paying: no line.
  assert.equal(lowCredit(acct(100, { subscription: { plan: "pro", name: "Pro", windows: [], over: false } }), 1000), false);
  assert.equal(lowCredit(acct(100, { subscription: { plan: "pro", name: "Pro", windows: [], over: true } }), 1000), true);
});

test("the warning measures against the newest credit added, else the free credit", () => {
  assert.equal(lastAddedCents([{ kind: "coupon", at: "x", amount_micro_usd: 5_000_000, status: "succeeded" }, { kind: "topup", at: "y", amount_micro_usd: 25_000_000 }], { handle: null }), 500);
  assert.equal(lastAddedCents([{ kind: "topup", at: "x", amount_micro_usd: 25_000_000, status: "failed" }, { kind: "topup", at: "y", amount_micro_usd: 10_000_000, status: "succeeded" }], { handle: null }), 1000, "a failed top-up added nothing");
  assert.equal(lastAddedCents([], { handle: null }), 25);
  assert.equal(lastAddedCents(null, { handle: "ada" }), 100);
});

test("the warning line: what's left and Add credit, the estimate only with five turns to average", () => {
  const onAdd: string[] = [];
  const r = TestRenderer.create(h(CreditWarning, { account: acct(20), addedCents: 100, avg: null, onAdd: () => onAdd.push("billing") }));
  assert.equal(all(r), "20¢ of credit leftAdd credit");
  act(() => { button(r, "Add credit").props.onClick(); });
  assert.deepEqual(onAdd, ["billing"]);
  act(() => { r.update(h(CreditWarning, { account: acct(20), addedCents: 100, avg: 0.06, onAdd: () => {} })); });
  assert.match(all(r), /^20¢ of credit left, about 3 turns at your average/);
  act(() => { r.update(h(CreditWarning, { account: acct(3), addedCents: 100, avg: 0.06, onAdd: () => {} })); });
  assert.match(all(r), /^3¢ of credit left, less than a turn at your average/, "never \"about 0 turns\"");
  act(() => { r.update(h(CreditWarning, { account: acct(21), addedCents: 100, avg: 0.06, onAdd: () => {} })); });
  assert.equal(r.toJSON(), null, "above 20% left: no line");
  r.unmount();
});

test("the estimate is left out under five turns, from the account's own average after", () => {
  assert.equal(averageTurn([thread(MIN_TURNS - 1)], MODELS), null);
  // Spread over sessions, it's still the account's turns.
  assert.ok(Math.abs(averageTurn([thread(2), thread(3)], MODELS)! - 0.06) < 1e-9);
  // Unpriced and free turns don't count toward the five.
  assert.equal(averageTurn([thread(4), thread(3)], []), null);
  assert.equal(aboutTurns(5, 0.06), 83);
  assert.equal(aboutTurns(5, null), null);
  assert.equal(leftLine(20.7), "20¢");
  assert.equal(leftLine(412), "$4.12");
});

// ---------- the wall ----------

test("the wall: saved work, the session's cost and turns, amounts with estimates, the smallest selected", () => {
  const r = TestRenderer.create(h(CreditWall, { thread: stopped(14), models: MODELS, avg: 0.06, apiKey: "k", onTopUp: async () => {} }));
  const s = all(r);
  assert.match(s, /You're out of Frog Cloud credit\. Your work is saved\./);
  assert.match(s, /This session has cost 84¢ over 14 turns\./);
  assert.match(s, /stopped between steps/);
  const tiles = r.root.findAll((n) => n.props.role === "radio");
  assert.deepEqual(tiles.map((n) => text(n)), ["$5about 83 turns", "$10about 166", "$25about 416", "$100about 1,666"]);
  assert.deepEqual(tiles.map((n) => n.props["aria-checked"]), [true, false, false, false]);
  assert.ok(button(r, "Add $5 and resume"));
  assert.match(s, new RegExp(`Plus a ${cardFeeCents(5)}¢ card fee`));
  assert.equal(cardFeeCents(5), 46, "the edge's cardFeeCents for $5");
  // No promise the web can't keep: no Mac hand-off, no plan pitch, no saved card.
  assert.doesNotMatch(s, /Finish on your Mac|Pro|saved card/);
  act(() => { tiles[1].props.onClick(); });
  assert.ok(button(r, "Add $10 and resume"));
  r.unmount();
});

test("the wall leaves the estimates out under five turns, and the cost when no turn could be priced", () => {
  const r = TestRenderer.create(h(CreditWall, { thread: stopped(3), models: [], avg: null, apiKey: "k", onTopUp: async () => {} }));
  assert.deepEqual(r.root.findAll((n) => n.props.role === "radio").map((n) => text(n)), ["$5", "$10", "$25", "$100"]);
  assert.match(all(r), /This session has run 3 turns\./);
  assert.doesNotMatch(all(r), /cost [<$\d]/);
  r.unmount();
});

test("Add $N and resume leaves for checkout with that amount; Have a code? opens the field inline", async () => {
  const paid: number[] = [];
  const seen: string[] = [];
  let r!: TestRenderer.ReactTestRenderer;
  await act(async () => { r = TestRenderer.create(h(CreditWall, { thread: stopped(6), models: MODELS, avg: 0.06, apiKey: "k", onTopUp: async (d: number) => { paid.push(d) } }), { createNodeMock: (el) => ({ focus: () => seen.push(String(el.props["aria-label"])) }) }); });
  await act(async () => { button(r, "Add $5 and resume").props.onClick(); });
  assert.deepEqual(paid, [5]);
  assert.equal(r.root.findAll((n) => n.props["aria-label"] === "Coupon code").length, 0);
  await act(async () => { button(r, "Have a code?").props.onClick(); });
  assert.equal(r.root.findAll((n) => n.type === "input" && n.props["aria-label"] === "Coupon code").length, 1, "the coupon field, in the card");
  assert.deepEqual(seen, ["Coupon code"], "with the cursor in it");
  r.unmount();
});

test("today's card's Finish on your Mac (a link to the download page) is gone from the App", () => {
  const src = readFileSync(new URL("../src/App.tsx", import.meta.url), "utf8");
  assert.doesNotMatch(src, /Finish on your Mac/);
  assert.match(src, /\{paused && \(\n\s*<CreditWall /);
  assert.match(src, /\{!paused && <Composer key=\{current\.id\}/, "the wall takes the composer's place");
});

// ---------- pay and resume ----------

function harness(deps: Partial<WallResumeDeps> & { thread: Thread }) {
  const sent: { session: string; op: Op }[] = [];
  const opened: string[] = [];
  const accounts: Account[] = [];
  let api!: ReturnType<typeof useWallResume>;
  let props: WallResumeDeps = { session: "s1", send: (session, op) => sent.push({ session, op }), fetchMe: null, onAccount: (a) => accounts.push(a), openSession: (id) => opened.push(id), pollMs: 1, pollTries: 5, ...deps };
  const Probe = (p: WallResumeDeps) => { api = useWallResume(p); return null };
  let r!: TestRenderer.ReactTestRenderer;
  // Under StrictMode, as main.tsx renders the App: initializers and effects run twice in dev.
  act(() => { r = TestRenderer.create(h(StrictMode, null, h(Probe, props)), { unstable_isConcurrent: true } as never); });
  return {
    sent, opened, accounts, get api() { return api },
    update(next: Partial<WallResumeDeps>) { props = { ...props, ...next }; act(() => { r.update(h(StrictMode, null, h(Probe, props))); }); },
    unmount: () => act(() => r.unmount()),
  };
}
const mem = () => { const m = new Map<string, string>(); return { getItem: (k: string) => m.get(k) ?? null, setItem: (k: string, v: string) => void m.set(k, v), removeItem: (k: string) => void m.delete(k), m } };

test("a code redeemed on the wall resumes the stopped turn at once, with one line's worth of note", () => {
  const t = stopped(6);
  const w = harness({ thread: t });
  act(() => { w.api.redeemed({ added_cents: 500, credit_cents: 500 }); });
  assert.deepEqual(w.sent, [{ session: "s1", op: { op: "continue", note: resumeNote(500) } }]);
  assert.equal(resumedLine(resumeNote(500)), "$5.00 added. Frog picked up where it stopped.");
  // The same stopped turn, rendered again: still once.
  w.update({ thread: { ...t } });
  assert.equal(w.sent.length, 1);
  w.unmount();
});

test("a later billing_limit doesn't resume by itself: only credit added again does", () => {
  const w = harness({ thread: stopped(6) });
  act(() => { w.api.redeemed({ added_cents: 500, credit_cents: 500 }); });
  assert.equal(w.sent.length, 1);
  // The resumed turn ran and stopped on credit again: a positive balance (the 20 s poll) is not a resume.
  w.update({ thread: stopped(7) });
  assert.equal(w.sent.length, 1, "no continue → 402 → continue loop");
  act(() => { w.api.redeemed({ added_cents: 1000, credit_cents: 1000 }); });
  assert.equal(w.sent.length, 2);
  // A code redeemed with nothing stopped resumes nothing.
  const idle = harness({ thread: thread(3) });
  act(() => { idle.api.redeemed({ added_cents: 500, credit_cents: 500 }); });
  assert.equal(idle.sent.length, 0);
  w.unmount(); idle.unmount();
});

test("back from Stripe: the session reopens, and the turn resumes once the webhook's credit is in", async () => {
  const storage = mem();
  savePending(storage, { session: "s1", turn: 6, cents: 500, before: 0, at: Date.now() });
  let calls = 0;
  // /v1/me: the webhook hasn't landed for the first two polls.
  const fetchMe = async () => acct(++calls < 3 ? 0 : 497); // $5 in, less a late 3¢ debit
  const w = harness({ thread: stopped(6), session: null, storage, search: "?session_id=cs_test_1", fetchMe });
  assert.deepEqual(w.opened, ["s1"]);
  assert.match(w.api.waiting ?? "", /Waiting for the credit/);
  w.update({ session: "s1" });
  await act(async () => { await new Promise((r) => setTimeout(r, 40)); });
  assert.equal(calls, 3);
  assert.deepEqual(w.sent, [{ session: "s1", op: { op: "continue", note: resumeNote(500) } }]);
  assert.equal(w.api.waiting, null);
  assert.equal(storage.m.size, 0, "the note is used up");
  w.unmount();
});

test("the Checkout note is never cleared while rendering (StrictMode runs initializers twice; the second would find nothing)", () => {
  const storage = mem();
  savePending(storage, { session: "s1", turn: 6, cents: 500, before: 0, at: Date.now() });
  let rendering = false;
  let clearedInRender = 0;
  const spy = { ...storage, removeItem: (k: string) => { if (rendering) clearedInRender++; storage.removeItem(k) } };
  const Probe = (p: WallResumeDeps) => { rendering = true; try { useWallResume(p) } finally { rendering = false } return null };
  let r!: TestRenderer.ReactTestRenderer;
  act(() => { r = TestRenderer.create(h(Probe, { session: null, thread: stopped(6), send: () => {}, fetchMe: null, onAccount: () => {}, openSession: () => {}, storage: spy, search: "" })); });
  assert.equal(clearedInRender, 0);
  assert.equal(storage.m.size, 0, "cleared, in the effect");
  act(() => r.unmount());
});

test("back from Stripe without the credit: the wall says so, and Resume by hand needs credit", async () => {
  const storage = mem();
  savePending(storage, { session: "s1", turn: 6, cents: 500, before: 0, at: Date.now() });
  const w = harness({ thread: stopped(6), storage, search: "?session_id=cs_test_2", fetchMe: async () => acct(0) });
  await act(async () => { await new Promise((r) => setTimeout(r, 40)); });
  assert.match(w.api.waiting ?? "", /hasn't shown up yet/);
  assert.equal(w.sent.length, 0);
  assert.equal(w.api.resumeByHand(0), undefined, "no Resume while there's no credit");
  act(() => { w.api.resumeByHand(500)!(); });
  assert.deepEqual(w.sent, [{ session: "s1", op: { op: "continue", note: resumeNote() } }]);
  assert.equal(resumedLine(resumeNote()), "Credit added. Frog picked up where it stopped.");
  w.unmount();
});

test("checkout cancelled: the session reopens, nothing resumes; a stale note is ignored", async () => {
  const storage = mem();
  savePending(storage, { session: "s1", turn: 6, cents: 500, before: 0, at: Date.now() });
  const w = harness({ thread: stopped(6), session: null, storage, search: "", fetchMe: async () => acct(500) });
  await act(async () => { await new Promise((r) => setTimeout(r, 20)); });
  assert.deepEqual(w.opened, ["s1"]);
  assert.equal(w.sent.length, 0);
  w.unmount();
  savePending(storage, { session: "s1", turn: 6, cents: 500, before: 0, at: Date.now() - 2 * 3600_000 });
  assert.equal(takePending(storage), null);
});

test("leaving for checkout notes the stopped turn and the balance before", () => {
  const storage = mem();
  const w = harness({ thread: stopped(6), storage });
  w.api.leaving(10, 3);
  const p = takePending(storage)!;
  assert.deepEqual({ ...p, at: 0 }, { session: "s1", turn: 6, cents: 1000, before: 3, at: 0 });
  w.unmount();
});

test("credit back by another route: the wall offers Resume (a click), only for a balance read after it appeared", async () => {
  const resumes: string[] = [];
  let r!: TestRenderer.ReactTestRenderer;
  const props = (credit: number, creditAt: number) => ({ thread: stopped(6), models: MODELS, avg: 0.06, apiKey: "k", onTopUp: async () => {}, credit, creditAt, onResume: () => resumes.push("resume") });
  act(() => { r = TestRenderer.create(h(CreditWall, props(500, Date.now() - 60_000))); });
  assert.throws(() => button(r, "Resume"), "the balance from before the stop doesn't count");
  assert.ok(button(r, "Add $5 and resume"));
  await new Promise((x) => setTimeout(x, 5));
  act(() => { r.update(h(CreditWall, props(500, Date.now()))); });
  assert.match(all(r), /You have \$5\.00 of credit now/);
  assert.equal(resumes.length, 0, "never by itself");
  act(() => { button(r, "Resume").props.onClick(); });
  assert.deepEqual(resumes, ["resume"]);
  act(() => { r.update(h(CreditWall, props(0, Date.now() + 1))); });
  assert.throws(() => button(r, "Resume"), "no credit, no Resume");
  r.unmount();
});

test("shouldResume: the credit's own session and stopped turn, and once", () => {
  const added = { session: "s1", turn: 6, cents: 500 };
  assert.equal(shouldResume(added, "s1", stopped(6), new Set()), true);
  assert.equal(shouldResume(added, "s1", stopped(6), new Set(["s1:6"])), false, "already resumed");
  assert.equal(shouldResume(added, "s1", stopped(7), new Set()), false, "a later stop isn't the one paid for");
  assert.equal(shouldResume(added, "s1", thread(6), new Set()), false, "nothing stopped");
});

test("the wall's pieces read the turn that stopped on money, and the session's spend", () => {
  assert.equal(stoppedTurn(stopped(4)), 4);
  assert.equal(stoppedTurn(thread(4)), null);
  assert.equal(stoppedTurn({ ...stopped(4), running: true }), null);
  assert.equal(stoppedTurn(thread(4, { type: "error", error: { status: 402, code: "insufficient_credit" } })), 4, "the edge's old 402 ending");
  assert.equal(stoppedTurn(thread(4, { type: "error", error: "connection reset" })), null);
  assert.equal(shouldResume({ session: "s2", turn: 4, cents: 500 }, "s1", stopped(4), new Set()), false, "another session's credit");
  const spend = sessionSpend(stopped(3), MODELS);
  assert.equal(spend.turns, 3);
  assert.ok(Math.abs(spend.dollars! - 0.18) < 1e-9);
  assert.equal(resumedLine("<resumed after the app restarted; your previous turn was interrupted; continue>"), null);
  assert.equal(resumedLine("please continue where you left off"), null);
});

test("a resumed turn shows one quiet line in the transcript, not the note as a message", () => {
  const t = stopped(2);
  const resumed: Turn = { turn: 3, input: resumeNote(500), entries: [], usage: usage(), reason: { type: "complete" } };
  const html = renderToStaticMarkup(h(Transcript, { thread: { ...t, turns: [...t.turns, resumed], ended: { type: "complete" } }, onDecide: () => {}, onAnswer: () => {}, onElicit: () => {}, onRetry: () => {} } as never));
  assert.match(html, /data-row="resumed"[^>]*>\$5\.00 added\. Frog picked up where it stopped\.</);
  assert.doesNotMatch(html, /&lt;resumed after/, "the note never shows as text");
  assert.equal((html.match(/class="me"/g) ?? []).length, 2, "the two typed messages stay bubbles");
});

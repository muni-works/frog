// The meter's words in each account state, the plan sheet's estimates, and the once-only card
// after a first result (src/plans.ts).
import { test } from "node:test";
import assert from "node:assert/strict";
import { COPY, firstResultWords, isPayPath, loadPlanCard, meter, moreTasks, onFreeCredit, PLAN_FACTS, planCard, savePlanCard, type PlanCardMemo } from "../src/plans.ts";

const plan = (weekly: number, fiveH = 0, over = false) => ({
  plan: "pro", name: "Pro", over,
  windows: [{ kind: "5h" as const, used: fiveH, limit: 100, resets_at: "2026-11-20T00:00:00Z" }, { kind: "weekly" as const, used: weekly, limit: 100, resets_at: "2026-11-23T00:00:00Z" }],
});
const acct = (credit_cents: number, subscription: ReturnType<typeof plan> | null = null) => ({ credit_cents, subscription });

test("meter: signed out, the free credit a new account gets", () => {
  const m = meter({ kind: "signedOut" });
  assert.equal(m.label, "25¢ free");
  assert.equal(m.aria, "25¢ free, open plans");
});

test("meter: on free credit, what's left in cents, the bar against what was added", () => {
  const m = meter({ kind: "account", account: acct(21), addedCents: 25 });
  assert.equal(m.label, "21¢ left");
  assert.equal(m.aria, "21¢ left, open plans");
  assert.equal(m.fill, 0.84);
  assert.equal(meter({ kind: "account", account: acct(1278), addedCents: 1000 }).label, "$12.78 left");
  assert.equal(meter({ kind: "account", account: acct(1278), addedCents: 1000 }).fill, 1);
  assert.equal(meter({ kind: "account", account: acct(0.4), addedCents: 25 }).label, "Less than 1¢ left");
});

test("meter: out of credit says what the credit wall says", () => {
  const m = meter({ kind: "account", account: acct(0), addedCents: 25 });
  assert.equal(m.label, "Out of credit");
  assert.equal(m.tone, "warn");
  assert.equal(meter({ kind: "account", account: acct(-3), addedCents: 25 }).label, "Out of credit");
});

test("meter: on a plan, the share of the week used", () => {
  const m = meter({ kind: "account", account: acct(0, plan(12)), addedCents: 25 });
  assert.equal(m.label, "12% of week");
  assert.equal(m.aria, "12% of week, open plans");
  assert.equal(m.fill, 0.12);
  assert.equal(meter({ kind: "account", account: acct(0, plan(91)), addedCents: 25 }).tone, "notice");
});

test("meter: past the plan, the credit paying", () => {
  assert.equal(meter({ kind: "account", account: acct(412, plan(100, 0, true)), addedCents: 1000 }).label, "$4.12 left");
  assert.equal(meter({ kind: "account", account: acct(0, plan(100, 0, true)), addedCents: 25 }).label, "Out of credit");
});

test("free credit: no plan and nothing paid in", () => {
  assert.equal(onFreeCredit({ subscription: null }, []), true);
  assert.equal(onFreeCredit({ subscription: null }, [{ kind: "topup", at: "x", amount_micro_usd: 5e6, status: "succeeded" }]), false);
  assert.equal(onFreeCredit({ subscription: null }, [{ kind: "topup", at: "x", amount_micro_usd: 5e6, status: "failed" }]), true);
  assert.equal(onFreeCredit({ subscription: plan(1) }, []), false);
  // History not loaded yet: not claimed as free.
  assert.equal(onFreeCredit({ subscription: null }, null), false);
});

test("plan sheet: about how many more tasks, only from a finished, priced session", () => {
  assert.equal(moreTasks(19, 0.04, true), 4);
  assert.equal(moreTasks(19, 0.04, false), null);
  assert.equal(moreTasks(19, 0, true), null);
  assert.equal(moreTasks(19, null, true), null);
  assert.equal(COPY.sheetLead(4), "About four more tasks like this one. A plan gives you a weekly amount of work at the same prices.");
  assert.equal(COPY.sheetLead(null), "A plan gives you a weekly amount of work at the same prices.");
  assert.equal(COPY.sheetLead(0), "A plan gives you a weekly amount of work at the same prices.");
  assert.deepEqual(PLAN_FACTS.map((p) => COPY.planLine(p)), ["$5 of work every week", "$25 of work every week", "$50 of work every week"]);
  assert.equal(COPY.getPlan(PLAN_FACTS[0]), "Get Pro, $20 a month");
});

test("first-result card: honest numbers, or nothing", () => {
  assert.deepEqual(firstResultWords(0.04, 25), { took: "That took 4¢ of your 25¢.", pro: "Pro is $20 a month and covers about 125 tasks like this one every week." });
  assert.equal(firstResultWords(0, 25), null);
  assert.equal(firstResultWords(null, 25), null);
});

test("first-result card: once per account, never during a turn, never on a plan", () => {
  const base = { free: true, session: "a", finished: true, running: false, cost: 0.04 };
  assert.deepEqual(planCard(null, base), { show: true, claim: true });
  assert.deepEqual(planCard(null, { ...base, running: true }), { show: false, claim: false });
  assert.deepEqual(planCard(null, { ...base, finished: false }), { show: false, claim: false });
  assert.deepEqual(planCard(null, { ...base, free: false }), { show: false, claim: false });
  assert.deepEqual(planCard(null, { ...base, cost: 0 }), { show: false, claim: false });
  // Claimed by session a: it shows there, and nowhere else.
  assert.deepEqual(planCard({ session: "a" }, base), { show: true, claim: false });
  assert.deepEqual(planCard({ session: "a" }, { ...base, session: "b" }), { show: false, claim: false });
  // Either button retires it for good.
  assert.deepEqual(planCard({ done: true }, base), { show: false, claim: false });
});

test("first-result card: the memo is per account and survives a reload", () => {
  const m = new Map<string, string>();
  const s = { getItem: (k: string) => m.get(k) ?? null, setItem: (k: string, v: string) => void m.set(k, v) } as unknown as Storage;
  savePlanCard(s, "ada@example.com", { session: "a" });
  savePlanCard(s, "bo@example.com", { done: true });
  assert.deepEqual(loadPlanCard(s, "ada@example.com"), { session: "a" } satisfies PlanCardMemo);
  assert.deepEqual(loadPlanCard(s, "bo@example.com"), { done: true });
  assert.equal(loadPlanCard(s, "cy@example.com"), null);
});

test("/pay is the plan sheet's URL", () => {
  assert.equal(isPayPath("/pay"), true);
  assert.equal(isPayPath("/pay/"), true);
  assert.equal(isPayPath("/payment"), false);
});

import { nearLimit, nextPlan, PLAN_COPY, planAction, planOf, timesMore } from "../src/plans.ts";

test("plans are a price and a weekly amount of work, nothing about how many run at once", () => {
  for (const p of PLAN_FACTS) {
    assert.doesNotMatch(COPY.planLine(p), /at once|concurren|parallel/i);
    assert.doesNotMatch(COPY.getPlan(p), /at once|concurren|parallel/i);
  }
});

test("on each plan: its own marked, bigger ones Upgrade, smaller ones Switch", () => {
  const [pro, max, ultra] = PLAN_FACTS;
  assert.deepEqual(PLAN_FACTS.map((p) => planAction(pro, p)), [null, "Upgrade to Max", "Upgrade to Ultra"]);
  assert.deepEqual(PLAN_FACTS.map((p) => planAction(max, p)), ["Switch to Pro", null, "Upgrade to Ultra"]);
  assert.deepEqual(PLAN_FACTS.map((p) => planAction(ultra, p)), ["Switch to Pro", "Switch to Max", null]);
  // No plan: the free account's button.
  assert.equal(planAction(null, max), "Get Max, $100 a month");
  // Stale: every row sets one up again, its own too.
  assert.deepEqual(PLAN_FACTS.map((p) => planAction(pro, p, true)), ["Set up Pro again", "Upgrade to Max", "Upgrade to Ultra"]);
  assert.equal(PLAN_COPY.yours, "Your plan");
});

test("the next plan up and what it gives", () => {
  const [pro, max, ultra] = PLAN_FACTS;
  assert.equal(nextPlan(pro)?.name, "Max");
  assert.equal(nextPlan(max)?.name, "Ultra");
  assert.equal(nextPlan(ultra), null);
  assert.equal(nextPlan(null), null);
  assert.equal(timesMore(pro, max), "5 times");
  assert.equal(timesMore(max, ultra), "twice");
  assert.equal(PLAN_COPY.lead(pro, max), "Max gives you 5 times the weekly work.");
  assert.equal(PLAN_COPY.lead(max, ultra), "Ultra gives you twice the weekly work.");
  assert.equal(planOf({ plan: "max5" })?.name, "Max");
  assert.equal(planOf({ plan: "nope" }), null);
  assert.equal(planOf(null), null);
});

test("the moment to offer the next plan: 80% of the week, or past the plan", () => {
  assert.equal(nearLimit(plan(79)), false);
  assert.equal(nearLimit(plan(80)), true);
  assert.equal(nearLimit(plan(30, 0, true)), true);
  assert.equal(nearLimit(null), false);
  assert.equal(PLAN_COPY.near(84), "84% of this week used");
});

test("a stale plan reads as a plain sentence with somewhere to go", () => {
  assert.equal(PLAN_COPY.stale, "This plan can't be managed from here. Choose a plan below to set it up again.");
  assert.doesNotMatch(PLAN_COPY.stale, /—/);
});

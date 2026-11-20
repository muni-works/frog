// Local to this repo (not from zest): the edge's account routes, enough for the web app's
// sidebar and Settings to render against the mock. Each key is its own account, in memory.
//   GET  /v1/models           public; two models with mock prices (USD per token)
//   GET  /v1/me               the account
//   GET  /v1/machines         one paired node (not this Mac)
//   GET  /v1/keys, POST /v1/keys, POST /v1/keys/:id/revoke
//   GET  /v1/billing/history  a top-up (and redeemed codes)
//   POST /v1/coupons/redeem   see redeem() below
//   POST /v1/billing/topup    {amount, return} → {url: <return>/?session_id=cs_mock_…}: no Stripe;
//                             the credit lands 1.5 s later, as the webhook's would
//   POST /v1/mock/credit      {cents}: sets the balance (mock only, for the credit wall)
//   POST /v1/billing/subscribe {plan, return} → {url: <return>/?session_id=cs_mock_…}: no Stripe;
//                             the plan starts 1.5 s later, as the webhook's would
//   GET  /v1/repos            the account's GitHub repos (none unless /v1/mock/account set some)
//   POST /v1/billing/portal   {return} → {url: <return>/}: no Stripe; a plan picked in the portal is
//                             /v1/mock/account's portal_plan, applied here; stale: 409 stale_subscription
//   POST /v1/mock/models      {data}: models listed in place of MODELS (long prices, for layout tests)
//   POST /v1/billing/plan     {plan} → {plan, status}: changes the plan in place, as zest#213 (the week's
//                             use carried over); 400 same_plan/no_subscription/invalid_plan, 409
//                             stale_subscription, 402 payment_failed (decline), 404 (an older edge: no_plan_route)
//   POST /v1/mock/account     {credit_cents?, plan?, weekly?, fiveHour?, history?, repos?}: sets up a
//                             state (a fresh 25¢ account: {credit_cents: 25, history: []}; a plan:
//                             {plan: "pro", weekly: 0.12}) (mock only, for the phone screenshots)
// Mock data only: the prices and amounts here are not Frog Cloud's.
import { randomBytes } from "node:crypto";

const MODELS = [
  { id: "glm-5.3-flash", context_length: 131072, pricing: { prompt: "0.00000004", completion: "0.0000004", input_cache_read: "0.00000001" } },
  { id: "deepseek-v4.1-flash", context_length: 131072, pricing: { prompt: "0.00000008", completion: "0.0000006" } },
  // The recorded turn's model (demo.jsonl), priced so a played turn costs 6¢ (MOCK_TURN_CENTS).
  { id: "qwen3-coder-next", context_length: 262144, pricing: { prompt: "0.0002", completion: "0.002" } },
];

const G = 2 ** 30;
const MACHINES = [{ id: "n1", name: "mew", hardware: "RTX 3090 · 24 GB VRAM", online: true, model: "Qwen3-4B", decode: 58.4, totalBytes: 24 * G, freeBytes: 13 * G,
  models: [{ id: "Qwen/Qwen3-4B", name: "Qwen3-4B", hash: "bbbbbbbbbbbb22", loaded: true, quant: "bf16" }, { id: "Qwen/Qwen2.5-7B", name: "Qwen2.5-7B", hash: "cccccccccccc33", loaded: false, quant: "bf16" }] }];

export function accountRoutes() {
  const accounts = new Map(); // key → { account, keys, history }
  let models = MODELS;
  const of = (key) => {
    if (!accounts.has(key)) {
      const now = new Date().toISOString();
      accounts.set(key, {
        account: { plan: "free", name: "Ada Lovelace", handle: null, image: null, google: null, email: "ada@example.com", credit_cents: 1278, resets_at: null, subscription: null },
        keys: [{ id: "k_this", name: "frog.toys web · ab12", kind: "device", created: now, last_used: now, revoked: false, current: true }],
        history: [{ kind: "topup", at: "2026-11-02T18:00:00Z", amount_micro_usd: 10_000_000, status: "succeeded" }],
        redeemed: new Set(),
      });
    }
    return accounts.get(key);
  };
  const body = async (req) => { let b = ""; for await (const c of req) b += c; try { return JSON.parse(b || "{}"); } catch { return null; } };

  /** Answers an account route and returns true, or returns false for the session routes. */
  return {
    accounts: of,
    async handle(req, res, path, key, json) {
      if (path === "/v1/models" && req.method === "GET") return json(res, 200, { data: models }), true;
      if (path === "/v1/mock/models" && req.method === "POST") { const b = (await body(req)) ?? {}; models = Array.isArray(b.data) ? b.data : MODELS; return json(res, 200, { data: models }), true; }
      if (!key) return false;
      const a = of(key);
      // hidden_plan: /v1/me a moment behind a plan started elsewhere (no subscription shown yet).
      if (path === "/v1/me" && req.method === "GET") return json(res, 200, { account: a.hiddenPlan ? { ...a.account, subscription: null } : a.account }), true;
      if (path === "/v1/mock/state" && req.method === "GET") return json(res, 200, { planChanges: a.planChanges ?? 0, account: a.account }), true;
      if (path === "/v1/machines" && req.method === "GET") return json(res, 200, { data: MACHINES }), true;
      if (path === "/v1/keys" && req.method === "GET") return json(res, 200, { keys: a.keys }), true;
      if (path === "/v1/keys" && req.method === "POST") {
        const b = (await body(req)) ?? {};
        const id = "k_" + randomBytes(4).toString("hex");
        a.keys.push({ id, name: b.name || null, kind: "key", created: new Date().toISOString(), last_used: null, revoked: false, current: false });
        return json(res, 200, { key: "frog_" + randomBytes(16).toString("hex"), id }), true;
      }
      const revoke = path.match(/^\/v1\/keys\/([^/]+)\/revoke$/);
      if (revoke && req.method === "POST") {
        for (const k of a.keys) if (k.id === revoke[1]) k.revoked = true;
        return json(res, 200, { ok: true }), true;
      }
      if (path === "/v1/billing/portal" && req.method === "POST") {
        const b = (await body(req)) ?? {};
        if (typeof b.return !== "string") return json(res, 400, { error: { code: "invalid_return", message: "return must be an allowed web app origin" } }), true;
        if (!a.account.subscription) return json(res, 400, { error: { code: "no_subscription", message: "no subscription to manage" } }), true;
        if (a.stale) return json(res, 409, { error: { code: "stale_subscription", message: "this subscription isn't linked to Stripe" } }), true;
        // What the person picks in the portal: the new plan, with the week's use carried over.
        if (a.portalPlan) { const used = a.account.subscription.windows.find((w) => w.kind === "weekly")?.used ?? 0; a.account.subscription = subscription(a.portalPlan, 0, 0); for (const w of a.account.subscription.windows) if (w.kind === "weekly") w.used = used; a.account.subscription.over = false; a.account.plan = a.portalPlan; a.portalPlan = null; }
        return json(res, 200, { url: `${b.return.replace(/\/+$/, "")}/` }), true;
      }
      if (path === "/v1/repos" && req.method === "GET") return json(res, 200, { repos: (a.repos ?? []).map((name) => ({ name, pushed_at: null })) }), true;
      if (path === "/v1/billing/history" && req.method === "GET") return json(res, 200, { topups: a.history }), true;
      if (path === "/v1/billing/topup" && req.method === "POST") {
        const b = (await body(req)) ?? {};
        const micro = Number(b.amount);
        if (![5, 10, 25, 50, 100].map((d) => d * 1e6).includes(micro)) return json(res, 400, { error: { code: "invalid_amount", message: "amount must be a top-up" } }), true;
        if (typeof b.return !== "string") return json(res, 400, { error: { code: "invalid_return", message: "return must be an allowed web app origin" } }), true;
        setTimeout(() => {
          a.account.credit_cents += micro / 1e4;
          a.history.unshift({ kind: "topup", at: new Date().toISOString(), amount_micro_usd: micro, status: "succeeded" });
        }, 1500);
        return json(res, 200, { url: `${b.return.replace(/\/+$/, "")}/?session_id=cs_mock_${randomBytes(6).toString("hex")}` }), true;
      }
      if (path === "/v1/mock/credit" && req.method === "POST") {
        a.account.credit_cents = Number(((await body(req)) ?? {}).cents) || 0;
        return json(res, 200, { account: a.account }), true;
      }
      if (path === "/v1/billing/plan" && req.method === "POST") {
        if (a.noPlanRoute) return json(res, 404, { error: { code: "not_found", message: "not found" } }), true;
        const b = (await body(req)) ?? {};
        if (!PLANS[b.plan]) return json(res, 400, { error: { code: "invalid_plan", message: "plan must be pro, max5 or max" } }), true;
        const sub = a.account.subscription;
        if (!sub) return json(res, 400, { error: { code: "no_subscription", message: "no plan to change; subscribe first" } }), true;
        if (a.stale) return json(res, 409, { error: { code: "stale_subscription", message: "this subscription isn't linked to Stripe" } }), true;
        if (sub.plan === b.plan) return json(res, 400, { error: { code: "same_plan", message: `already on ${sub.name}` } }), true;
        if (a.decline) return json(res, 402, { error: { code: "payment_failed", message: "Your card was declined." } }), true;
        const used = sub.windows.find((w) => w.kind === "weekly")?.used ?? 0;
        a.account.subscription = subscription(b.plan, 0, 0);
        for (const w of a.account.subscription.windows) if (w.kind === "weekly") w.used = used;
        a.account.subscription.over = a.account.subscription.windows.some((w) => w.used >= w.limit);
        a.account.plan = b.plan;
        a.planChanges = (a.planChanges ?? 0) + 1;
        return json(res, 200, { plan: b.plan, status: "active" }), true;
      }
      if (path === "/v1/billing/subscribe" && req.method === "POST") {
        const b = (await body(req)) ?? {};
        // As zest#213: no second subscription while Stripe still has the first (a stale one doesn't count).
        if ((a.account.subscription || a.hiddenPlan) && !a.stale) return json(res, 409, { error: { code: "already_subscribed", message: "this account already has a plan; change it with POST /v1/billing/plan" } }), true;
        if (!PLANS[b.plan]) return json(res, 400, { error: { code: "invalid_plan", message: "plan must be pro, max5 or max" } }), true;
        if (typeof b.return !== "string") return json(res, 400, { error: { code: "invalid_return", message: "return must be an allowed web app origin" } }), true;
        setTimeout(() => { a.account.subscription = subscription(b.plan, 0, 0); a.account.plan = b.plan; }, 1500);
        return json(res, 200, { url: `${b.return.replace(/\/+$/, "")}/?session_id=cs_mock_${randomBytes(6).toString("hex")}` }), true;
      }
      if (path === "/v1/mock/account" && req.method === "POST") {
        const b = (await body(req)) ?? {};
        if (b.credit_cents != null) a.account.credit_cents = Number(b.credit_cents) || 0;
        if (Array.isArray(b.history)) a.history = b.history;
        if (b.plan === null) { a.account.subscription = null; a.account.plan = "free"; }
        else if (b.plan) { a.account.subscription = subscription(b.plan, Number(b.weekly) || 0, Number(b.fiveHour) || 0); a.account.plan = b.plan; }
        if (b.handle !== undefined) a.account.handle = b.handle;
        if (Array.isArray(b.repos)) a.repos = b.repos;
        if (b.stale !== undefined) a.stale = !!b.stale;
        if (b.portal_plan !== undefined) a.portalPlan = b.portal_plan;
        if (b.over !== undefined && a.account.subscription) a.account.subscription.over = !!b.over;
        if (b.no_plan_route !== undefined) a.noPlanRoute = !!b.no_plan_route;
        if (b.decline !== undefined) a.decline = !!b.decline;
        if (b.hidden_plan !== undefined) a.hiddenPlan = !!b.hidden_plan;
        return json(res, 200, { account: a.account }), true;
      }
      if (path === "/v1/coupons/redeem" && req.method === "POST") {
        const r = redeem(a, ((await body(req)) ?? {}).code);
        return json(res, r.status, r.body), true;
      }
      return false;
    },
  };
}

/** The plans' weekly allowance in micro-USD and their names (mock: the real amounts, Pro $5 a week). */
const PLANS = { pro: { name: "Pro", weekly: 5e6 }, max5: { name: "Max", weekly: 25e6 }, max: { name: "Ultra", weekly: 50e6 } };

/** A plan's account shape, `weekly` and `fiveHour` the shares used (0…1). The week resets
 *  Monday; a 5-hour window holds a share of it. */
function subscription(plan, weekly, fiveHour) {
  const p = PLANS[plan];
  const now = new Date();
  const monday = new Date(now); monday.setUTCHours(0, 0, 0, 0); monday.setUTCDate(monday.getUTCDate() + ((8 - monday.getUTCDay()) % 7 || 7));
  const five = p.weekly / 4;
  return {
    plan, name: p.name, over: weekly >= 1,
    windows: [
      { kind: "5h", used: Math.round(fiveHour * five), limit: five, resets_at: new Date(now.getTime() + 3 * 3600_000).toISOString() },
      { kind: "weekly", used: Math.round(weekly * p.weekly), limit: p.weekly, resets_at: monday.toISOString() },
    ],
  };
}

/** POST /v1/coupons/redeem {code}: the contract the gateway session is building, against made-up
 *  codes. LAUNCH5 adds $5 once per account; USED is already redeemed; OLD has expired; GONE is
 *  used up; TEAM isn't for this account; SLOW is rate limited; anything else is unknown. */
export function redeem(a, code) {
  const c = String(code ?? "").trim().toUpperCase();
  const err = (status, code, message) => ({ status, body: { error: { code, message } } });
  if (c === "SLOW") return err(429, "slow_down", "Too many tries. Wait a minute and try again.");
  if (c === "USED" || (c === "LAUNCH5" && a.redeemed.has(c))) return err(409, "already_redeemed", "You've already redeemed this code.");
  if (c === "OLD") return err(410, "expired", "This code has expired.");
  if (c === "GONE") return err(410, "used_up", "This code has been used up.");
  if (c === "TEAM") return err(403, "not_eligible", "This code isn't for this account.");
  if (c !== "LAUNCH5") return err(404, "unknown_code", "That code doesn't exist. Check it and try again.");
  a.redeemed.add(c);
  a.account.credit_cents += 500;
  a.history.unshift({ kind: "coupon", code: c, at: new Date().toISOString(), amount_micro_usd: 5_000_000, status: "succeeded" });
  return { status: 200, body: { code: c, added_cents: 500, credit_cents: a.account.credit_cents } };
}

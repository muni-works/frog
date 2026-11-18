// Local to this repo (not from zest): the edge's account routes, enough for the web app's
// sidebar and Settings to render against the mock. Each key is its own account, in memory.
//   GET  /v1/models           public; two models with mock prices (USD per token)
//   GET  /v1/me               the account
//   GET  /v1/machines         none
//   GET  /v1/keys, POST /v1/keys, POST /v1/keys/:id/revoke
//   GET  /v1/billing/history  a top-up
// Mock data only: the prices and amounts here are not Frog Cloud's.
import { randomBytes } from "node:crypto";

const MODELS = [
  { id: "glm-5.3-flash", context_length: 131072, pricing: { prompt: "0.00000004", completion: "0.0000004", input_cache_read: "0.00000001" } },
  { id: "deepseek-v4.1-flash", context_length: 131072, pricing: { prompt: "0.00000008", completion: "0.0000006" } },
];

export function accountRoutes() {
  const accounts = new Map(); // key → { account, keys, history }
  const of = (key) => {
    if (!accounts.has(key)) {
      const now = new Date().toISOString();
      accounts.set(key, {
        account: { plan: "free", name: "Ada Lovelace", handle: null, image: null, google: null, email: "ada@example.com", credit_cents: 1278, resets_at: null, subscription: null },
        keys: [{ id: "k_this", name: "frog.toys web · ab12", kind: "device", created: now, last_used: now, revoked: false, current: true }],
        history: [{ kind: "topup", at: "2026-11-02T18:00:00Z", amount_micro_usd: 10_000_000, status: "succeeded" }],
      });
    }
    return accounts.get(key);
  };
  const body = async (req) => { let b = ""; for await (const c of req) b += c; try { return JSON.parse(b || "{}"); } catch { return null; } };

  /** Answers an account route and returns true, or returns false for the session routes. */
  return {
    accounts: of,
    async handle(req, res, path, key, json) {
      if (path === "/v1/models" && req.method === "GET") return json(res, 200, { data: MODELS }), true;
      if (!key) return false;
      const a = of(key);
      if (path === "/v1/me" && req.method === "GET") return json(res, 200, { account: a.account }), true;
      if (path === "/v1/machines" && req.method === "GET") return json(res, 200, { data: [] }), true;
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
      if (path === "/v1/billing/history" && req.method === "GET") return json(res, 200, { topups: a.history }), true;
      return false;
    },
  };
}

# Vendored zest mock gateway

Copied from the private zest repo at `ae1c73f` (`sandbox/mock/mock-gateway.mjs`, `sandbox/container/{ws,session}.mjs`, `sandbox/container/fixtures/demo.jsonl`) so CI here can run it. Only the import paths changed, plus `Op::Submit` reading `text` (ecto/zest#79). Re-copy when zest changes the mock. Live previews (`preview.mjs`, the `/preview` route) are from zest's `claude/sandbox-preview` branch; here `npm run mock` serves `public/preview.js` as the capture script, and `GET /v1/sessions` carries `preview: true` (muni-works/zest#199; `startMock({ previews: false })` is an older gateway without it).

**Local additions (not in zest):** `account.mjs` answers the edge's account routes (`/v1/models`, `/v1/me`, `/v1/machines`, `/v1/keys`, `/v1/billing/history`, `/v1/coupons/redeem` with made-up codes) so the sidebar and Settings render against the mock; `mock-gateway.mjs` calls it before its own routes (two lines). Keep them when re-copying.

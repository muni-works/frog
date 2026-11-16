# Vendored zest mock gateway

Copied from the private zest repo at `ae1c73f` (`sandbox/mock/mock-gateway.mjs`, `sandbox/container/{ws,session}.mjs`, `sandbox/container/fixtures/demo.jsonl`) so CI here can run it. Only the import paths changed, plus `Op::Submit` reading `text` (ecto/zest#79). Re-copy when zest changes the mock. Live previews (`preview.mjs`, the `/preview` route) are from zest's `claude/sandbox-preview` branch; here `npm run mock` serves `public/preview.js` as the capture script.

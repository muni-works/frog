# Frog web

The frog.toys web app: cloud sessions only. Static TypeScript, bundled with esbuild into `dist/` for Cloudflare Pages. Not deployed yet.

- `src/client.ts`: the Frog Cloud gateway client (wire contract §2 handshake with reconnect and `resume_after`, §4 routes).
- `src/protocol.ts`: the parts of `crates/frog-engine/src/protocol.rs` the web reads and sends.
- `src/transcript.ts`: folds envelopes into the session view.
- `test/mock/`: the zest mock gateway, vendored so CI can run it.

```bash
npm install && npm run mock   # mock gateway on :8788
npm run dev                   # http://localhost:5173, proxies /v1 to $GATEWAY (default the mock)
npm test
```

Any key works against the mock; each key is its own account.

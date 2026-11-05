# frog launch readiness — 2026-11-05

survey of main at 2ae2f02a (mac app, web + Frog Cloud sandbox, CLI, engine crates, docs) plus the tang integration branch. read-only. nothing pushed or deployed.

## tl;dr

the code is in good shape: every suite passes. what blocks launch is mostly **legal copy, one billing field, release plumbing, and the unpushed tang branch**. none of it is engine perf.

## build / test status

| area | command | result |
|---|---|---|
| rust workspace | `cargo test --workspace` | **644 pass / 0 fail / 8 ignored** |
| mac app + FrogKit | `cd apps/macos && xcodegen generate && xcodebuild -scheme Frog CODE_SIGNING_ALLOWED=NO test` | **446 tests, 5 skipped, 0 fail** (the scroll-up flake didn't fire) |
| web app | `apps/web`: `npm run check`, `npm test`, `npm run build` | tsc clean, 30/30, build ok (83 kB gzip) |
| site | `node --test site/test/` | 6/6 |
| Frog Cloud edge (zest) | `~/Developer/zest/edge`: `npm test` | 242/242 |

note: `apps/macos/Frog.xcodeproj` is generated and untracked. a stale local copy won't compile (it's missing FeatureFlags/OutcomeCard), so always run `xcodegen generate` first. `release.sh` already does this.

## blocking (fix before public launch)

1. **tang branch unpushed and carrying a WIP commit.** `frog/integrate-2026-11-03` @ 99f8c6f9 is 116 ahead of origin/main and not on any remote. it contains 35066e91, "wip(deepseek): shared expert spread across EP ranks (unfinished, EP tests under bisect)".
   - next: fix or revert 35066e91, then push the branch and merge it. the engine numbers below only exist on this branch.
2. **wide-check gates don't match the commit claim.** 99f8c6f9 says the KL bars moved to 2.0e-4 (3000) and 3.2e-5 (8000). the code found still enforces KL < 1e-3 (`tests/gpu_logits.rs:55`, `flash/cli.rs:1516`).
   - next: make the tool enforce the new bars and re-run the gates.
3. **privacy policy is marked DRAFT.** zest `edge/src/pages.ts:254-256`.
   - next: finalize it, list the upstreams per the gateway plan (:183-190), and remove the banner.
4. **/terms contradicts the product.** `pages.ts:63-66` says "we never store prompt or completion text", but the sandbox stores sessions (`/s/<id>`, session delete in `apps/web/src/App.tsx:287`). the terms also describe the old key-based API beta.
   - next: rewrite for the sandbox. cover GitHub App repo access, transcript retention and deletion, and per-token billing.
5. **account API still returns a per-task price.** zest `edge/src/accounts-ux.ts:57` (`TASK_COST_CENTS` = $0.25) and `:207/:226` (`tasks_left`). this breaks the "pay per token, never tasks" rule on a public API.
   - next: drop both fields and return balance in dollars only.
6. **launch post and bench page have unfilled placeholders.** `docs/launch/beat1.md` has 7 `{{…}}` (lines 112, 122-123). `bench.md` has 13 (lines 55-61). runbook gate G6 fails.
   - next: fill them from the current engine table (below) or cut them.
7. **release plumbing points at the wrong place.**
   - `apps/macos/scripts/release.sh:24` defaults `REPO=ecto/frog`, but origin is `muni-works/frog`. Sparkle appcast and `/download` (`site/vercel.json`) depend on that repo.
   - `packaging/homebrew/frog.rb:8-9` uses `revision: "HEAD"` with an rc tag, which is invalid.
   - the latest tags are still `v0.1.1-rc4…rc6`.
   - next: fix REPO, cut a non-rc `v0.1.x`, and point the formula at a real sha (add a cask for Frog.dmg if brew should install the app).

## risky (fix soon after, or accept knowingly)

1. **refunds / chargebacks aren't handled.** the schema has a `refunded` status (`pg/0001_accounts.sql:109`), but there's no `charge.refunded` / `charge.dispute.created` handler. a chargeback keeps the credit.
2. **the $5 sign-up credit can be farmed.** it's granted once per user (`accounts-ux.ts:35,60`), not per verified GitHub identity. rate limits are 10/h/IP. next: tie it to a verified GitHub account.
3. **email magic-link sending isn't confirmed.** zest `edge/src/auth.ts:1-2` says "no email infrastructure needed yet". next: confirm delivery in prod, or ship GitHub + Google only.
4. **mid-turn overdraw.** the balance is checked at request admission (`admit.ts:97-100` → 402). a long sandbox turn can go negative. next: decide whether that's allowed (and settle it) or cap mid-turn.
5. **installer is checksummed, not signed.** the `.sha256` comes from the same host as the tarball (`site/install.sh:59-91`). on macOS it ad-hoc signs unsigned binaries (:103-107). next: notarize the darwin CLI in release.yml and add minisign/cosign verification.
6. **CLI error copy is thin.** out-of-credit is handled (`render.rs:415`, `acp.rs:494`). auth-expired, network-down and model-not-loaded probably surface as raw reqwest/anyhow errors. next: force each case and fix what prints.
7. **first-run CLI → Frog Cloud login is unverified.** no device-code/login path was found by grep. next: walk a fresh install with no config.
8. **`--mtp` costs the serve prompt mix ~20%.** next: measure `TANG_SERVE_WIDE_MTP=0` before picking the serve default. this is undocumented in tang.
9. **mac failure paths are unexercised.** sign-in (`SettingsView.swift:510-569`) and Run in Frog Cloud (`Workspace.swift:333`, `CloudSessions.swift:67`) exist, but nobody has run them with the network or engine down.
10. **no status / legal links from frog.toys.** `/status`, `/terms` and `/privacy` live only on the edge. `site/index.html` has no footer for them, no pricing, and no Frog Cloud section. `site/worker.js:21` serves a bare "no gateway" 503.
11. **schema drift.** one mac build rewrote all of `crates/frog-engine/schema/frog-engine-1.json`. a second build didn't. next: add a CI check that the schema is regenerated and unchanged.
12. **force unwraps on env input.** `RemotePush.swift:26` (`FROG_PUSH_RELAY` URL). otherwise low risk.
13. **unfinished broker rescue op.** `SessionBroker.swift:1563` has the only real TODO in the mac app.

## docs / copy

- **engine numbers are stale everywhere.** no doc has the current coder-next figures. add a dated table to `docs/launch/bench.md` and point the post at it:

  | metric | tok/s |
  |---|---|
  | single stream, plain | 234 |
  | single stream, MTP | up to 402 |
  | B=64 batch | 1,817 |
  | serve C=64 decode-heavy | 1,078 |
  | prefill | 6.6k–7.6k |

  stale sources: `bench.md:65,81` (Oct 21/25 baselines); gateway plan :307 (193 tok/s bull).
- **words/s in spec.** `docs/models.md:45,63,141-145` and open question #4 (:196). there's no words/s in the shipped UI (`ModelStats.swift` stores words/s internally but displays tok/s). next: rewrite to tok/s and close Q4.
- **"frog cloud" lowercase** in README (8×), `docs/reference.md` (5×), `docs/quickstart.md` (1×). next: normalize to "Frog Cloud". no "kyte" in user copy.
- **relay claim.** `docs/ROADMAP.md:225` says Pro reaches "your GPU from anywhere through a relay". next: cut it (web is cloud-only).
- **launch docs are frozen at the Oct 30 Beat 1 plan** (`docs/launch/runbook.md`, `audit.md`). they don't record what shipped. next: write a dated post-Oct-30 status note.
- **open plan questions:**
  - margin on third-party tokens (gateway plan :313-315)
  - logged-out picker (account design Q2)
  - `models.md` Q1-Q3 (Auto default, Pro vs BYOK, cloud permission scope)
  - three image-gen questions (`2026-10-05-tang-image-generation.md:222`)

## shippable

- **rust CLI/engine.** no real TODO/FIXME/todo!/unimplemented! in src. all panic!s are in tests. no WIP commits on main. copy is clean.
- **web sandbox.** GitHub/Google PKCE → `frog_` device key, and a 401 signs you out cleanly. out-of-credit card + composer pause. Stripe top-up/subscribe/portal with signature checks and idempotency, fails closed. per-token metering in cents. sandbox caps (3 free / 10 paid, 6h leases). secrets stay server side.
- **mac app.** Developer ID + notarization + Sparkle 2.10.1 (EdDSA key) pipeline in `release.sh`. per-million-token cost display. tok/s speeds. no placeholder copy.

## suggested order

1. tang: fix/revert 35066e91 → wide-check bars → push + merge (blocking 1-2)
2. zest: drop `tasks_left`/`TASK_COST_CENTS`; rewrite terms + finalize privacy (blocking 3-5)
3. release: REPO fix, non-rc tag, brew formula, installer signature (blocking 7, risky 5)
4. docs: current engine table, fill placeholders, copy fixes, post-Oct-30 status note (blocking 6)
5. billing hardening: refund/dispute webhooks, credit tied to GitHub, overdraw policy (risky 1-4)
6. smoke pass: CLI error cases + first-run login, mac sign-in/cloud with network killed (risky 6-9)

## not verified

- GitHub App permissions and install config under muni-works
- sandbox container isolation below the edge
- coder-next as the default in `apps/web/src/models.ts`
- whether frog.toys / the Stripe live keys / repo-public steps (launch checklist C3, C5, C5b, C6) happened. there's no record in the repo.

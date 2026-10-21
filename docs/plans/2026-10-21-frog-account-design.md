# frog account: Frog Pro and Frog API, built in

Status: v2, revised after code review + zest review · 2026-10-21 · owner: frog manager

## Goal

frog stays free and open source, and works fully logged out and offline. On top of that, frog's
own hosted models are part of the product, not one preset among many:

- In every provider list (CLI `--providers`, the Mac app's Settings and model picker), **local is
  first and frog is second**. The frog entry is hardcoded: it can't be removed, hidden or reordered.
- One provider, `frog`, with two ways in:
  - **Frog Pro**: sign in, subscription. The default way to connect from the app.
  - **Frog API**: paste a `frog_` key, pay per token. For the CLI, CI and power users.
  Both reach the same endpoint and models. The account behind the credential decides billing.
- Logged out or offline, nothing changes from today: local models work, with no nags beyond one
  line where frog api would help.

Non-goals: billing UI inside frog (zest owns pricing and checkout; frog links out), team
accounts, usage dashboards beyond what `/v1/me` returns.

## Naming

| thing | value |
|---|---|
| provider id | `frog` (today's `frog-api` becomes an alias, as do `tang-cloud`, `zest`) |
| model spec | `frog/qwen3-coder-next` |
| display name | one "frog" entry; the plan is a badge: "frog · Pro", "frog · API", "frog · beta" (Cam, 2026-10-21) |
| key env | `FROG_API_KEY` (aliases kept) |
| base env | `FROG_BASE_URL`, default `https://api.frog.toys/v1` |

This reverses the `frog-api/` flag, which launch copy now uses. Option: keep `frog-api/` as the
documented spec and only rename the display. **Decision for Cam** (see Open questions).

## One credential

Signing in and pasting a key produce the same thing: a bearer token (`frog_…`) stored in the
Keychain (account `frog`), or `FROG_API_KEY` in the environment. Sign-in is a device flow that
mints a subscription-scoped key:

1. `frog login` (or "Sign in" in the app) calls `POST {base}/auth/device` → `{user_code, verification_url, verification_url_complete, device_code, interval, expires_in}` (RFC 8628 shape; codes live 10 min).
2. frog shows the user code, opens `verification_url_complete` (`https://api.frog.toys/activate?code=…`, served by the edge) and polls `POST {base}/auth/token`, honoring `authorization_pending`, `slow_down` (back off +5 s), `expired_token` and `access_denied`.
3. On success it gets `{key, plan}` and stores the key.

Identity behind /activate (zest, 2026-10-21): for the beta, the browser user redeems an invite code
and the device gets a beta key (~Oct 24). Pro sign-in needs real identity (email link or GitHub)
plus Stripe: Cam's choice, target ~Nov 9.

`frog logout` deletes it. The engine never cares which way the key came: every request is the same
OpenAI-compatible call. This keeps the engine, fallback and caching code unchanged.

`GET {base}/me` → `{plan: "beta"|"api"|"pro", tier, email (null until sign-in), credit_usd, limits: {streams, rpm}}`, 401 on a bad key (ecto/zest#20, live with the next edge deploy). It feeds the plan badge and account row.
Cached for 10 minutes; failure means "unknown", never "logged out".

## Surfaces

**Engine (frog-engine).** `providers::PRESETS` gains a `pinned` rank: local servers, then `frog`,
then the rest. `list()` sorts by it. `remove`/disable refuse `frog`. New `account.rs`: device
flow, `/me`, logout. `ProviderInfo` gains `account: Option<Account>`.

**CLI.** `frog login`, `frog logout`, `frog account` (plan, credit, key source).
`--providers` prints frog second with "signed in as … (Pro)" or "not connected: frog login".

**Mac app.**
- Settings → Models: a fixed "frog" card under Local, above "Add a Provider…". Logged out it shows
  "Sign in for Frog Pro" and "Use an API key". Signed in: plan, email, credit, Manage (opens the
  web), Sign out. No remove button.
- Model picker: a "frog" section right after local models, always present. Logged out, its
  models show with a "Sign in" action instead of being hidden (the same pattern as today's
  missing-key flow, `addKey`).
- Onboarding: unchanged default (local). One line offers frog when a turn is slow or the local
  model is too small (extends `BiggerModelLine`).

**Offline / logged out.** Nothing calls `api.frog.toys` unless the frog provider is connected
and selected, except `/me` on Settings open. The existing fallback (offline / 402 / 503 → local)
stays.

## Error handling

- 401 → "your frog sign-in expired" + Sign in. Key isn't deleted automatically.
- 402 → "out of credit" + Manage (web). Fallback to local, as today.
- Device flow: timeout after 10 min, cancel any time; clear message if the browser never opens.
- `/me` failure → account row says "can't reach frog right now", models still usable.

## Testing

- Engine: pinned order and non-removability (unit); device flow against a scripted HTTP server
  (pending, approved, expired, denied); `/me` parsing; alias resolution `frog-api/` → `frog/`.
- CLI: `login`/`logout`/`account` against the scripted server.
- App: snapshot tests for the frog card (logged out, Pro, API, error) and the picker section.
- Live: the end-to-end test against `api.frog.toys` with a beta key, plus a device-flow run once
  zest ships the endpoints.

## Dependencies (zest)

`POST /auth/device`, `POST /auth/token`, `GET /me` (exists, #20), `https://api.frog.toys/activate`. Until they exist,
frog ships the key path and the pinned provider, with "Sign in" hidden behind a feature check on
`/me` (404 → key only).

## Plan

1. Engine: pinned `frog` provider + alias + non-removable (no zest dependency).
2. CLI: `account`/`login`/`logout`; login gated on the endpoints.
3. App: frog card, picker section, slow-turn line.
4. Device flow, end to end with zest.

1–3 can ship for Oct 30 with the key path; 4 when zest's auth lands.

## Open questions

Resolved: one "frog" entry with a plan badge (Cam). Same models and limits for Pro and API at
launch (zest agrees). zest is fine with `frog/` + `frog-api/` alias.

1. Spec rename: `frog/qwen3-coder-next` (cleaner, but launch copy says `frog-api/`) or keep
   `frog-api/`? Recommend `frog/` with `frog-api/` as a permanent alias, and update the copy.
2. Should logged-out app users see frog models in the picker (with Sign in), or only in Settings?
   Recommend the picker: that's the "deeply integrated" part.
3. Pro vs API: same models and limits, different billing only? Recommend yes for launch.

## v2: changes from code review (2026-10-21)

**Identity.** Keep `frog-api` as the internal id, Keychain account and canonical spec. Show
"frog" as the display name; `frog/` stays an input alias. Flipping the id would need a Keychain
migration and rewriting stored specs (models.json, config.toml, sessions) for no user gain.
(Supersedes "Naming" above unless Cam overrules.)

**Order, everywhere.** One shared rank in the engine: this Mac's models, then frog, then your
servers, then other clouds. Applied in:
- `providers::list` (today PRESETS order: frog-api is first, even before ollama)
- `catalog::by_provider` (BTreeMap → alphabetical; becomes an ordered Vec)
- `models::pick_default`: after local checks, a connected frog beats `enabled` entries and
  `ANTHROPIC_API_KEY`
- FrogKit `ModelSections` (Mac and iOS)
- Settings: frog becomes a fixed card; it's removed from "Add a Provider…" and "Remove Key"
- Picker "Add Key…" menu: frog first

**Which key wins.** One resolver returns `(source, key)` for both the UI and requests (today
`key_source` says env-first while `key()` uses the Keychain first). Precedence: `FROG_API_KEY`
wins, and the card and `frog account` say "using FROG_API_KEY; your sign-in is ignored here".

**Host pinning.** The Keychain frog key goes only to `https://api.frog.toys`. With
`FROG_BASE_URL` overridden, only an env key is sent (mirrors OpenAI's rule).

**Non-removable, enforced in the engine.** `--remove-provider frog-api` refuses. `add_custom`
reserves `frog`, `frog-api`, `tang-cloud`, `zest`.

**Logged out = zero network.** A static frog model list (`qwen3-coder-next`, context from config)
backs the picker when there's no key; frog's `/models` is never fetched logged out. `/me` is only
called when a key exists, lazily from the card, at most every 10 min, 3 s timeout; never at
launch, never from `--providers`. Sign-in is hidden behind a build flag until zest's `/activate`
ships (no unauthenticated feature probe). A test runs `--providers`/`--catalog` logged out
against a fail-on-hit server. Known existing exception, kept: the OpenRouter/Vercel public
catalogs are fetched keyless on catalog refresh.

**Device flow (post-launch).** Open only `https://api.frog.toys/activate` (host checked, https).
Show the user code in the app/CLI, and the page asks the user to confirm it matches. Never log
`device_code` or the key. Signing in replaces a pasted key after confirmation (one Keychain slot).
`frog logout` revokes Pro-minted keys server-side, best effort.

**Card copy by source.** "Pro · signed in" / "API key · Keychain" / "API key · FROG_API_KEY".
Sign out only for a Keychain key. 401 copy depends on the source.

**Kept as is.** The per-project "code goes to the cloud" consent still applies to frog. The spend
estimate and monthly cap apply to API and beta; Pro shows "included" (when Pro exists).

**Oct 30 scope.**
- Ship: engine rank everywhere, key resolver, static model list, non-removable, host pinning,
  `frog account` (local info only), app card with paste-key, FrogKit order, menus.
- After: device flow and Sign in (beta invite ~Oct 24 if zest's /activate lands, Pro ~Nov 9),
  `/me` plan badge (needs zest#20 deployed), slow-turn line, Pro cap exemption.

## Implementation plan

| # | piece | files | tests |
|---|---|---|---|
| 1 | shared rank + `list`/`by_provider`/`pick_default` | providers.rs, catalog.rs, models.rs | order with a fake custom server; default prefers frog over enabled anthropic |
| 2 | key resolver + host pinning | providers.rs, config.rs | env+keychain precedence; keychain key withheld under FROG_BASE_URL |
| 3 | non-removable + reserved aliases | providers.rs, main.rs | refuse remove; add_custom rejects aliases |
| 4 | static logged-out model list + zero-network test | catalog.rs | fail-on-hit mock for --providers/--catalog |
| 5 | `frog account` (local) | main.rs | golden output |
| 6 | app: FrogKit sections rank, frog card, menus | ModelList.swift, SettingsView.swift, ModelPicker.swift | XCTest `ModelSections.make`; card snapshot |
| 7 | (post-launch) `/me` badge, device flow, Sign in | account.rs, app | scripted server: pending/slow_down/expired/denied |

1–5 are engine/CLI (one worktree, sequential). 6 can run in parallel once 1's rank is exposed via
`--providers --json`.

# frog account: Frog Pro and Frog API, built in

Status: draft for review · 2026-10-21 · owner: frog manager

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
| display name | "frog" in lists; the plan shows as "Pro" or "API" next to it |
| key env | `FROG_API_KEY` (aliases kept) |
| base env | `FROG_BASE_URL`, default `https://api.frog.toys/v1` |

This reverses the `frog-api/` flag, which launch copy now uses. Option: keep `frog-api/` as the
documented spec and only rename the display. **Decision for Cam** (see Open questions).

## One credential

Signing in and pasting a key produce the same thing: a bearer token (`frog_…`) stored in the
Keychain (account `frog`), or `FROG_API_KEY` in the environment. Sign-in is a device flow that
mints a subscription-scoped key:

1. `frog login` (or "Sign in" in the app) calls `POST {base}/auth/device` → `{user_code, verification_url, device_code, interval}`.
2. frog opens `https://frog.toys/activate?code=…` in the browser and polls `POST {base}/auth/token`.
3. On success it gets `{key, plan: "pro"}` and stores the key.

`frog logout` deletes it. The engine never cares which way the key came: every request is the same
OpenAI-compatible call. This keeps the engine, fallback and caching code unchanged.

`GET {base}/me` → `{plan: "pro"|"api"|"beta", email, credit, limits}` feeds the account row.
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

`POST /auth/device`, `POST /auth/token`, `GET /me`, `https://frog.toys/activate`. Until they exist,
frog ships the key path and the pinned provider, with "Sign in" hidden behind a feature check on
`/me` (404 → key only).

## Plan

1. Engine: pinned `frog` provider + alias + non-removable (no zest dependency).
2. CLI: `account`/`login`/`logout`; login gated on the endpoints.
3. App: frog card, picker section, slow-turn line.
4. Device flow, end to end with zest.

1–3 can ship for Oct 30 with the key path; 4 when zest's auth lands.

## Open questions

1. Spec rename: `frog/qwen3-coder-next` (cleaner, but launch copy says `frog-api/`) or keep
   `frog-api/`? Recommend `frog/` with `frog-api/` as a permanent alias, and update the copy.
2. Should logged-out app users see frog models in the picker (with Sign in), or only in Settings?
   Recommend the picker: that's the "deeply integrated" part.
3. Pro vs API: same models and limits, different billing only? Recommend yes for launch.

# frog cloud accounts: the sign-in experience

Spec, written 2026-10-25. Status: proposed. Owner: frog manager. Builds on
docs/plans/2026-10-21-frog-account-design.md (one credential, `cloud/` ids, `FROG_API_KEY`
wins, host pinning, `/me`) and docs/onboarding.md (the principles below come from there).

**The goal.** Cam opens Settings → Models, clicks "sign in with GitHub", a system sheet slides
down, he's already signed in to GitHub in Safari so it's one click, the sheet closes, the frog
hops, and his next turn runs on `cloud/dart`. He never sees, copies or pastes a key.

## 1. Frame

### What changes

Today the frog cloud card (`FrogCloudCard`, apps/macos/Frog/Views/SettingsView.swift:493) is a
key-paste surface: "Get a Key" (opens api.frog.toys/beta), "Add a Key" (the `KeySheet`), and a
"Sign In" button compiled out behind `FROG_SIGN_IN`. This spec turns that card into the sign-in
surface. Key paste stays, demoted to a menu item for API-plan and CI users. It never disappears.

### Principles

1. **Sign-in adds, never unlocks.** Local models, other clouds and pasted keys work exactly as
   today, signed out. Nothing in frog is gated on an account. Running out of credit falls back to
   this Mac, as today.
2. **No key, ever, on screen.** The key is minted server-side, written to the Keychain (account
   `cloud`), and sent only to `https://api.frog.toys`. No "copy key", no reveal, no key in logs,
   transcripts or `frog account`. People who want a key for CI get one on the web.
3. **Ask at the moment of need.** Signing in is offered in two places only: the frog cloud card,
   and the existing one-line nudges (`BiggerModelLine`'s cloud option, the picker's frog cloud
   section). Never at launch, never as a modal.
4. **One line, not a card.** Every message outside Settings (low credit, expired sign-in) is a
   single line above the composer, in the `PingLine` / `BiggerModelLine` slot, with × to dismiss.
5. **Everything reversible, where it was turned on.** Sign out lives on the same card, one click,
   no confirmation dialog (signing back in is one click too). Sign out revokes the minted key
   server-side, best effort, and clears the Keychain slot.
6. **Zero network signed out.** Nothing calls frog.toys until the user clicks sign in (kept
   from the account plan).

### Voice and design language

- **Copy is lowercase** in frog's voice (card lines, inline lines, CLI), matching `FrogCopy`
  ("ready when you are"). Proper nouns keep their case: GitHub, Keychain, Pro. System chrome
  (window titles, menu bar) stays system case. Note: today's Settings strings are sentence case.
  This card leads the change, and the rest of Settings can follow later (open question 1).
- **Tokens.** Canvas `FrogCanvas` (white 0.118 dark / 0.955 light). Frog cloud accent: today's
  `.green.opacity(0.85)` cloud glyph and green plan capsule (`.green.opacity(0.18)` fill).
  Mark colours from `FrogMark`: skin #51da60, spot #36b347, ink #15171a, paper #fbfbf9. Low credit
  uses `.orange`; errors `.red`, as the rest of Settings does. Type: system (SF Pro), `.body` for
  the name, `.caption` secondary for detail, `.caption2.weight(.semibold)` for the plan badge.
- **FrogFace moods carry state.** A 28 pt `FrogFace` replaces the `cloud.fill` glyph on the card
  in the signed-in states and while signing in: `.idle` signed in · `.waiting` while the browser
  sheet is up (head tilt, wide eyes) · `.thinking` while minting · `.done` + one `hop` on success
  · `.sad` on an error · `.waiting` on low credit. Reduce Motion holds the first frame (already
  built into `FrogFace`).
- **Motion.** The card's content changes use `Motion.panel(reduced:)` (it's a card morphing);
  rows and meters use `Motion.quick(reduced:)`. `Haptics.settle()` once when the signed-in card
  settles.
- **Sound.** `FrogSounds.Cue.ribbit` once on a completed sign-in (it is a finished thing), only
  where frog sounds are on. No sound for errors, low credit or sign out.

### Browser handoff: recommendation

**Use `ASWebAuthenticationSession` with a session-scoped callback scheme (`frog-auth`) and
PKCE, in the app. Use the RFC 8628 device flow for the CLI and for the magic-link email path.**

| option | how it feels | verdict |
|---|---|---|
| `ASWebAuthenticationSession` | a system sheet over the Settings window; shares Safari's cookies, so a signed-in GitHub is one click; closes itself on the callback; focus never leaves frog | **recommended** |
| app-wide custom scheme (`frog://auth`) opened from Safari | full Safari tab, then a "open in frog?" prompt, tab left behind; any app can claim `frog://` (the Mac app doesn't register it today; iOS does, for pairing) | no |
| loopback listener on 127.0.0.1 (as `mcp_oauth.rs` does for MCP) | full Safari tab ending on "you can close this tab", focus stays in Safari; fine for MCP, not Apple-level | no for the app; keep it for MCP |
| device flow (code + poll) | type or confirm a code in a browser | yes for the CLI and email; too much ceremony for the app's GitHub path |

Why this one: it's the mechanism Apple built for exactly this. The callback is delivered only
to the session that asked for it (no scheme hijacking, no app-wide URL registration), it works
without a running server, and with `prefersEphemeralWebBrowserSession = false` the user's
existing GitHub cookie makes it a one-click sign-in. The deployment target is macOS 26, so the
newer `ASWebAuthenticationSession.Callback.customScheme` API is available; an https callback on
frog.toys (associated domains) is a later upgrade that doesn't change the UX.

How it runs (GitHub, in the app):

1. The app makes a PKCE verifier and challenge, and a random `state`.
2. It starts the session on `https://frog.toys/auth/app?provider=github&challenge=…&state=…`,
   callback scheme `frog-auth`, anchored to the Settings window.
3. The edge runs GitHub OAuth (Better Auth) and redirects to
   `frog-auth://done?code=…&state=…`. The session hands that URL back and closes.
4. The app checks `state`, then sends `code` + verifier to the engine, which exchanges them at
   the edge for a key (`POST /auth/exchange`) and writes it to the Keychain itself. The key
   crosses from engine to Keychain only. The app gets back `{plan, handle, email}`, never the key.
5. The engine fetches `/me` and the usage endpoint, and the card settles into the signed-in
   state. `cloud/dart` becomes the starting model if no other model was chosen explicitly.

How it runs (magic link, in the app): the user types an email address. The engine starts a
device grant tied to that address (`POST /auth/device` with `email`), the edge emails a link,
and the engine polls `/auth/token` as in the CLI. The link opens in whatever browser the mail
client uses, on any device (opening it on your phone works). Nothing has to route back into the app.

### Edge contract assumed (the frog cloud manager owns the real one)

These are assumptions to design against, not a design for the endpoints. Names and shapes will
change. The UX depends only on what each call makes possible.

| need | assumed call | used by |
|---|---|---|
| start web sign-in | `GET https://frog.toys/auth/app?provider=github&challenge&state` → redirect `frog-auth://done?code&state` | app, GitHub |
| code → key | `POST /auth/exchange {code, verifier, device_name}` → `{key, plan, handle, email}` | engine |
| device grant (CLI, email) | `POST /auth/device {email?}` → RFC 8628 `{device_code, user_code, verification_uri (frog.toys/link), interval, expires_in}`; `POST /auth/token` → `{key, plan, handle, email}` | engine, CLI |
| account | `GET /me` → `{plan, handle, email, credit_usd, credit_limit_usd, resets_at}` (extends ecto/zest#20) | card, CLI `--status` |
| usage this week | `GET /me/usage?range=7d` → `{days: [{date, usd, tasks}], total_usd, total_tasks}` | card |
| legacy claim | `POST /auth/claim` with the old invite key as bearer, inside a signed-in session → links its credit to the account | migration |
| sign out | `POST /auth/revoke` (key as bearer), best effort | engine |
| upgrade / manage | `https://frog.toys/account` and `https://frog.toys/upgrade` web pages (Stripe lives there, never in the app) | card, low-credit line |

Plans assumed: `beta`, `pro`, `max`, `api`. The badge shows the plan name lowercase.
Credit is shown in dollars, as `/me` returns `credit_usd`.

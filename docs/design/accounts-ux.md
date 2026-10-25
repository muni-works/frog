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

## 2. The card

The card is one row in the existing "Cloud" `Section` of the grouped `Form` (Settings → Models),
where `FrogCloudCard` sits today: first in the section, never removable. Anatomy, the same in
every state so it morphs instead of swapping:

```
┌──────────────────────────────────────────────────────────────────┐
│ [face]  frog cloud  [badge]                     [primary] [ ⋯ ]  │
│  28pt   detail line (caption, secondary, wraps)                  │
│         [meter + week row: signed-in states only]                │
└──────────────────────────────────────────────────────────────────┘
```

- **face**: `FrogFace(mood:size: 28)`, top-aligned with the title's first baseline, 10 pt gap.
  It replaces today's `cloud.fill` glyph.
- **title**: "frog cloud" (`.body`). **badge**: plan capsule, `.caption2.weight(.semibold)`,
  green on `.green.opacity(0.18)`, padding 5×1, as today. Hidden when signed out.
- **primary**: at most one button, `.controlSize(.regular)`; **⋯**: `ellipsis.circle` borderless
  menu, as today. Everything else hides in it.
- The row grows downward (the meter, the email field). `Motion.panel` animates the height.

### State 1: signed out (no key anywhere)

face `.idle` · no badge · primary **sign in with GitHub** (`.borderedProminent`, GitHub mark
`Image("github")` 14 pt leading) · ⋯ menu: "sign in with email", "use an API key…",
"get an API key on the web".

> **frog cloud**
> fast hosted models, one click away. your code goes there only in projects you allow.

Under the detail line, one tertiary link-style button: **use email instead** (same as the menu
item; it's there because not everyone has GitHub).

**Email sub-state.** "use email instead" grows the row by one line (`Motion.panel`): a
`TextField` ("you@example.com", `.roundedBorder`, 220 pt, focused, content type
`.emailAddress`) and **send link** (`.borderedProminent`, disabled until the text looks like an
address; ⏎ sends). Esc or "cancel" collapses it. After sending:

> **frog cloud**
> check your email: we sent a link to cam@muni.works. open it on any device.
> change · resend

face `.waiting`. "resend" is disabled for 30 s, then re-sends (new grant, old one dropped).
"change" returns to the field with the address selected. The engine polls the device grant
every `interval` (default 5 s, `slow_down` adds 5 s). When the link is opened, the card goes
straight to the success beat below. The grant expires after 10 min (see errors).

**Where else sign-in is offered (signed out).**
- Model picker, frog cloud section: models listed from the static list (account plan), each row
  with a trailing **sign in** button that opens Settings → Models with the card highlighted
  (a 1 s green ring, `Motion.quick`) and starts the GitHub sheet at once. One click from the
  picker to the sheet.
- `BiggerModelLine`: its cloud option reads **use frog cloud** and does the same. (Today it
  says "add a cloud key".)
- Nowhere else. No launch prompt, no badge on the Settings icon.

### State 2: signing in (browser handoff and return)

Three beats, all inside the same row. The Settings window stays where it is; the system sheet
attaches to it.

**2a. sheet up.** Clicking sign in with GitHub starts `ASWebAuthenticationSession`. The
system's own consent alert ("frog wants to use frog.toys to sign in") appears first: that's
macOS, we don't fight it. Behind it the card shows:

> **frog cloud**
> finish signing in on the sheet · cancel

face `.waiting`, primary hidden (no double starts). "cancel" calls `session.cancel()`.

**2b. setting up.** The callback arrives and the sheet closes on its own. The card shows:

> **frog cloud**
> setting up this Mac…

face `.thinking`. This covers the exchange, Keychain write and first `/me` + usage fetch.
Target under 1 s. Don't add a spinner: the thinking frog is the spinner.

**2c. success.** One beat, then the signed-in card:
- face `.done` plus one `hop`, `FrogSounds.Cue.ribbit` (when sounds are on), `Haptics.settle()`
  as the meter rows land (`Motion.panel`).
- for 4 s the detail line reads **signed in · cloud/dart is ready**, then settles into the
  state 3 line.
- If the starting model (`Workspace.startingModel`) was the default rather than one the user
  picked, it becomes `cloud/dart`. If the user had picked something, it stays, and the line
  reads **signed in · pick cloud/dart in the model menu any time** instead. Sign-in adds, it
  doesn't take over.
- If sign-in was started from the picker or `BiggerModelLine`, Settings closes itself after the
  beat and the conversation that asked switches to `cloud/dart` (it asked, so that's the intent).
  The per-project "code goes to the cloud" consent still applies, as today.

The email path joins at 2b when the poll succeeds (with the app in the background, a
notification "signed in to frog cloud" if notifications are on; nothing otherwise).

### State 3: signed in (the account card)

face `.idle` · badge = plan (`beta`, `pro`, `max`, `api`) · no primary button (a signed-in
card has nothing to ask) · ⋯ menu: "manage on frog.toys" (opens frog.toys/account), "sign out".

```
[face] frog cloud [pro]                                          [⋯]
       @campedersen · cam@muni.works
       ████████████████████░░░░░░░   $14.20 left · resets nov 1
       ▁▃▂▅▇▂▁   this week · 212 tasks · $5.80
```

- **identity line**: `@handle · email` (GitHub sign-in), or just the email (email sign-in).
  Caption, secondary.
- **credit meter**: a 6 pt capsule, 180 pt wide, track `.quaternary`, fill green
  (`FrogMark.skin` at 0.85, so it reads as frog's, not the system's). Its fraction is
  `credit_usd / credit_limit_usd`. To its right, monospaced-digit caption:
  - pro / max: `$14.20 left · resets nov 1`
  - beta: `$4.10 beta credit left` (no reset)
  - api: `$31.00 left` (pay as you go; no limit, so no meter. Just the text.)
- **this week**: seven bars (Swift Charts `BarMark`, 56×16 pt, one per day, today last, fill
  `.secondary`; today's bar in green), then caption `this week · 212 tasks · $5.80`. "tasks" =
  finished turns on frog cloud, matching the pricing unit. Hover on a bar: `.help` with
  `tue · 41 tasks · $1.10`.
- **Fresh, not chatty.** `/me` and usage load when Settings opens (at most every 10 min, 3 s
  timeout, from the account plan) and after each frog cloud turn ends (debounced 30 s). A
  failed fetch keeps the last values dimmed (`.tertiary`) with `updated 2 h ago`. Never "signed
  out" because of a network error.
- The existing "Spent this week / this month" rows under the section count frog cloud only for
  `api` and `beta`. For `pro`/`max` they show `included`.

**Variants.**
- **`FROG_API_KEY` set in the environment** (it wins, per the account plan): identity line
  becomes `using FROG_API_KEY from your shell · your sign-in is ignored here`. The meter shows
  that key's account, if `/me` answers for it. ⋯ keeps "sign out" (it clears the saved sign-in,
  not the shell's key).
- **Pasted API key, no sign-in** (the `api` plan, CI users): badge `api`, identity line `API
  key · Keychain`. ⋯: "change key…", "remove key", "sign in with GitHub instead". This is
  today's card, restyled; it stays.

**Sign out.** ⋯ → "sign out": no dialog. The card animates back to state 1 (`Motion.panel`),
face goes `.idle`. The engine revokes the key (best effort), deletes the Keychain item, and
conversations on `cloud/…` show the existing "pick a model" path on their next turn. A
conversation mid-turn finishes that turn first.

### State 4: credit running low (the upgrade moment)

The one place frog asks for money, so it has to be earned: shown where the credit is being
spent, at a moment the user isn't waiting on anything, once.

**When.** `low` = credit left would last under 2 days at this week's pace
(`credit_usd < 2 × total_usd / 7`), or under 10% of `credit_limit_usd`, whichever comes first,
and never above $5 left (heavy users shouldn't be nagged at $30). Checked when a frog cloud turn
ends. `api` plans use the same rule.

**Where: one line above the composer** (the `PingLine` / `BiggerModelLine` slot, same height,
same × at the right), in the conversation whose frog cloud turn just finished. Not in a
notification, not a sheet, not every conversation.

**The line** (exact):

> frog cloud credit is low: about 2 days left at your pace. **upgrade to pro** ×

- The number: `about N days` rounded down, `less than a day` under 1, `about N hours` is never
  used (no countdown pressure).
- The action, by plan: beta → **upgrade to pro** · pro → **upgrade to max** · max and api →
  **add credit**. It opens frog.toys/upgrade (or /account for add credit) in the default
  browser. Checkout lives on the web. When the user comes back (app becomes active), the engine
  refreshes `/me` once, and the line disappears on its own if credit went up.
- A tiny `FrogFace(.waiting, size: 16)` leads the line, like the activity pill.
- **Once per credit period.** × (or the action) hides it until `resets_at`, or until credit next
  crosses the zero line. It doesn't come back the next turn.

**On the card**, while low: the meter fill turns `.orange`, the caption reads
`$1.30 left · about 2 days at your pace`, face `.waiting`, and a primary button appears: the
same action as the line (**upgrade to pro** / **upgrade to max** / **add credit**,
`.borderedProminent`). It goes when credit is no longer low.

**At zero.** Nothing breaks. The existing 402 fallback moves the turn to this Mac's model, and
the line becomes (exact, once per period):

> out of frog cloud credit, so this ran on this Mac. **upgrade to pro** ×

The card's meter is empty and orange; caption `out of credit · resets nov 1` (pro/max) or
`out of credit` (beta/api). If this Mac has no usable model, the turn stops with the same line
and the existing "pick a model" path, so no loop of failed requests.

### State 5: signed out, but a key exists (beta invite users)

Who: people who redeemed an invite and pasted a `frog_` key into the Keychain before sign-in
existed. `/me` answers for the key with `email: null`. Their key keeps working, forever, whether
or not they sign in. Signing in only attaches it to an account, so it shows on the web, survives
a new Mac, and can be upgraded.

face `.idle` · badge `beta` · primary **sign in with GitHub** (`.bordered`, not prominent: it's
an offer, not a fix) · ⋯ menu: "sign in with email", "change key…", "remove key".

> **frog cloud** `beta`
> invite key · Keychain. sign in to keep its credit with your account.
> ████████░░░░░░  $4.10 beta credit left

The meter and week row show as in state 3 (the key can read `/me` and usage); there's no
identity line.

**Migration, when they sign in.** The same flow as state 2, plus a claim. The user sees no
extra step:
1. GitHub sheet or email link, as usual. During 2b the line reads `setting up this Mac and
   moving your beta credit…`.
2. The engine exchanges the code for a new key, then calls the claim with the old key inside
   the new session. The edge moves the credit and usage history to the account and retires the
   old key.
3. Only when the claim succeeds and `/me` answers with the new key does the engine swap the
   Keychain item. Until then, every request still uses the old key. No turn ever runs without a
   working key.
4. Success line (4 s): **signed in · your beta credit came with you**. Then state 3.

If the claim fails, nothing changes: the old key stays in the Keychain and active, the new key
is revoked (best effort) and never stored, and the card stays in state 5 with
`couldn't move your beta credit just now · try again` (face `.sad` for that beat, then `.idle`).

**No nagging.** Legacy users get no line above the composer, no badge and no prompt. The offer
lives on the card, and in `frog --status` in the CLI. They lose nothing by ignoring it.
An env-only `FROG_API_KEY` user is never offered migration from the app (it's the shell's key).

## 3. Errors

Rule: errors say what happened and the next step, in one line on the card, with face `.sad` for
that moment (it relaxes to the state's own mood after 3 s, the text stays until the next
action). Nothing ever deletes a working key on an error. Copy is exact.

| what happened | card line | action shown | notes |
|---|---|---|---|
| user closed the sheet / pressed cancel | (back to state 1, no message) | sign in with GitHub | cancelling isn't an error |
| GitHub denied or the user declined | `GitHub didn't sign you in · try again, or use email` | sign in with GitHub · use email instead | |
| can't reach frog.toys (offline, DNS, timeout) | `can't reach frog.toys right now · try again` | try again | detected before opening the sheet where possible, so the sheet never opens on an error page |
| `state` mismatch / malformed callback | `that sign-in didn't come from this Mac · try again` | try again | log a warning, never the URL's query |
| exchange failed after GitHub succeeded | `signed in, but couldn't set up this Mac · try again` | try again | retry re-runs the whole sheet, which is one click because the GitHub cookie is warm |
| Keychain write failed | `couldn't save to your Keychain · try again` | try again | the minted key is revoked, best effort |
| email: address rejected | `that address didn't work · check it and send again` | (field stays open) | |
| email: link expired (10 min) | `that link expired · send another` | send another | face `.sad`, field keeps the address |
| email: link opened but denied | `that link was turned down · send another` | send another | |
| `/me` fails while signed in | meter dimmed, `updated 2 h ago` | none | never shown as signed out |
| 401 on a frog cloud request (key revoked/expired) | line above composer: `your frog cloud sign-in expired. **sign in again** ×` | sign in again (starts the sheet from the line) | the key isn't deleted automatically; the card shows state 1 with `your sign-in expired` as the detail |
| 401 for an env key | line: `FROG_API_KEY was turned down by frog cloud. check your shell's key ×` | none | the sign-in can't help here, so don't offer it |
| account suspended (403) | `this account can't use frog cloud right now · frog.toys/account` | manage on frog.toys | |
| rate-limited mint (429) | `too many sign-ins just now · try again in a minute` | try again (disabled 60 s) | |

All network calls in the flow use a 10 s timeout, except polls (honour `interval`).

## 4. CLI parity

The CLI is the device flow (RFC 8628), one line rewritten in place, in the same voice. It never
prints a key, with or without `--json`.

```
$ frog login
enter WDJB-MJHT at frog.toys/link (opened in your browser) · waiting
```

On success the same line is rewritten (`\r` + clear) to:

```
signed in as cam (@campedersen) · pro · cloud/dart is ready
```

- **Opening the browser.** On a desktop session frog opens
  `frog.toys/link?code=WDJB-MJHT` itself. Over SSH (`SSH_CONNECTION` set), or with no browser,
  it doesn't, and the line reads `open frog.toys/link and enter WDJB-MJHT · waiting`. The page
  shows the code and asks "is this the code in your terminal?" before approving.
- **Code format**: 8 letters as `XXXX-XXXX`, no vowels or look-alikes (RFC 8628 §6.1), so it
  can't spell words and reads aloud cleanly.
- **Waiting.** `waiting` gets a trailing `·` pulse once a second on a TTY (no spinner glyphs).
  Not a TTY: the code line prints once, then the result prints on its own line.
- **Email instead**: `frog login --email cam@muni.works` →
  `check cam@muni.works for a link · waiting`.
- **Legacy invite key present**: same flow, success line ends
  `· your beta credit came with you`.
- **Already signed in**: `already signed in as cam (@campedersen) · frog logout to switch`.
- **`FROG_API_KEY` set**: login still works and saves the sign-in, then adds a second line,
  `note: FROG_API_KEY from your shell wins over this sign-in`.

Outcomes (exit codes: 0 ok, 1 failed, 130 cancelled):

| case | line |
|---|---|
| ctrl-c | `cancelled` |
| code expired (10 min) | `that code expired · run frog login again` |
| denied on the page | `turned down at frog.toys/link · run frog login again` |
| offline | `can't reach frog.toys · check your connection and run frog login again` |
| keychain write failed | `couldn't save to your Keychain · nothing was changed` |

**`frog logout`** → `signed out · this Mac's key is revoked` (or `signed out · couldn't reach
frog.toys, the key will be revoked next time you're online` when offline). With only an env key:
`nothing to sign out · FROG_API_KEY comes from your shell`.

**`frog login --status`** (alias `frog account`): one line, same order as the card.

| state | line |
|---|---|
| signed in | `cam (@campedersen) · pro · $14.20 left · 212 tasks this week · cloud/dart` |
| low credit | `cam (@campedersen) · beta · $1.30 left, about 2 days at your pace · frog.toys/upgrade` |
| signed out | `not signed in · frog login` |
| legacy key | `invite key · beta · $4.10 left · frog login to keep it with an account` |
| env key | `FROG_API_KEY from your shell · api · $31.00 left` |
| offline | `cam (@campedersen) · pro · can't reach frog.toys, last seen $14.20 left` |

`--json` prints `{signed_in, handle, email, plan, credit_usd, week_tasks, week_usd, source}`
(`source`: `signin`, `keychain`, `env`, or null).

**Low credit in a run.** After a frog cloud turn ends and the state 4 rule fires, one dim line
once per credit period: `frog cloud credit is low: about 2 days left at your pace ·
frog.toys/upgrade`. At zero, the fallback already prints its own line. It gains `· frog.toys/upgrade`.

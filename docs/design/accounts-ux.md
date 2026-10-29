# frog cloud accounts: the sign-in experience

Spec, written 2026-10-25. Status: proposed.

> **Superseded on pricing (Cam, 2026-10-29): Frog Cloud is pay per token, like everyone
> else, and the apps never show "tasks".** The edge always metered per token; "tasks" was
> only a display (credit ÷ $0.25). Every screen below that says "N tasks left" shows the
> credit in dollars instead (`$22.04 credit`, from `credit_cents`), and per-turn cost stays
> in dollars at the model's per-token prices. The account shape keeps `tasks_left` /
> `tasks_limit` / `task_cost_cents` for old clients only; nothing new reads them. Owner: frog manager. Mockups:
[accounts-ux.html](accounts-ux.html) (every state, dark and light; `t` flips the theme,
`?only=<id>` shows one state). Captures: [accounts-ux-shots/](accounts-ux-shots/).

Builds on:
- docs/plans/2026-10-21-frog-account-design.md: one credential, `cloud/` ids, `FROG_API_KEY`
  wins, host pinning, `/me`.
- docs/onboarding.md and the onboarding spec v2 (chief `design/onboarding/spec.md`, with Cam's
  decisions of 2026-10-23): local-first, sign-in adds and never unlocks, $5 of credit at
  sign-in, a $0.50 device trial with no account, every prompt once per trigger.
- the frog design system v0.1.0 (chief `design/system/`): `tokens.json`, `voice.md`,
  `components.md`. Every colour, size, radius and motion below is a token name from there.

**The goal.** Cam opens Settings → Models and clicks "Sign in with GitHub". A system sheet
slides down. He's already signed in to GitHub in Safari, so it takes one click. The sheet
closes, the frog hops, and his next turn runs on `cloud/dart`. He never sees, copies or
pastes a key.

## 1. Frame

### What changes

Today the frog cloud card (`FrogCloudCard`, apps/macos/Frog/Views/SettingsView.swift:493) is
for pasting a key. It has "Get a Key" (opens api.frog.toys/beta), "Add a Key" (the
`KeySheet`), and a "Sign In" button compiled out behind `FROG_SIGN_IN`. This spec makes the
card the place you sign in. Key paste stays for API-plan and CI users, moved into the ⋯
menu. It never goes away.

### Principles

1. **Sign-in adds, never unlocks.** Local models, other clouds and pasted keys work exactly as
   today when signed out. Nothing in frog needs an account. Running out of credit falls back
   to this mac, as it does today.
2. **No key, ever, on screen.** The edge mints the key, the engine writes it to the Keychain
   (account `cloud`), and it is sent only to `https://api.frog.toys`. There's no copy key, no
   reveal, and no key in logs, transcripts or `frog account`. People who want a key for CI get
   one on the web.
3. **Ask at the moment of need.** Sign-in is offered on the frog cloud card and at the
   onboarding moments, each once per trigger (× means 14 days of quiet):
   - the first-run "save pip" step
   - the hard task the local model keeps missing. The picker's frog cloud section and
     `BiggerModelLine` both lead to this moment.
   - turning on a routine
   - a second device
   - pairing a head
   - the weekly receipt

   All of them start the same flow (§2, state 2). Sign-in is never offered at launch, during a
   running task, or as a modal.
4. **One line, not a card.** Every message outside Settings (low credit, expired sign-in) is a
   single line above the composer, in the `PingLine` / `BiggerModelLine` slot, with × to
   dismiss. The one exception is onboarding's "credits out" card, the first time only
   (state 4).
5. **Undo it where you did it.** Sign out is on the same card: one click, no confirmation
   dialog, because signing back in is one click too. It revokes the key on the edge (best
   effort) and clears the Keychain item.
6. **No network calls while signed out.** Nothing calls frog.toys until the user clicks sign
   in or starts the trial (from the account plan).
7. **Credits are tasks.** frog cloud charges for a finished task, so every screen counts tasks
   left. Dollars appear only where someone is choosing what to pay (the web, and onboarding's
   plan card).

### Voice and design language

- **Voice** (`voice.md`)
  - frog's own lines are lowercase: card detail lines, the lines above the composer, the CLI.
    That includes "this mac", "github" and "keychain" inside frog's sentences, as in the
    onboarding copy ("github didn't let me in"). Product and plan names are always lowercase:
    frog cloud, dart, tree, pro, max.
  - **Native controls use sentence case** as macOS expects, keeping proper nouns:
    `Sign in with GitHub`, `Send link`, `Upgrade to pro`, `Sign out`, `Manage on frog.toys`.
    Window titles and Settings section labels ("This Mac", "Cloud") stay as they are.
  - Notices are 10 words or fewer, with numbers over adjectives. Times use the `2h` / `3d`
    form, never "just now".
- **Tokens** (`tokens.json`)
  - Canvas is `color.bg` (#1e1e1e dark, #f4f4f4 light). The Settings group is `color.surface`
    with a `color.line` hairline and `radius.l`.
  - Brand green is `color.accent` (#58cc6f / #2e9e4f, the app's `Color.frog`). It's used for
    the plan badge (on accent at 18%), the prominent button (text in `color.onAccent`), the
    credit meter fill, and today's bar in the week chart. `color.success` is for checks only,
    never the brand.
  - Low credit uses `color.warning` for the meter fill only. Warning text is about 2:1 in
    light mode, so the caption stays `color.muted`. Errors don't turn text red: the `.sad`
    face carries the mood, and the text stays `color.text` / `color.muted`.
  - Model colours come from `color.model.*` (dart #429cff/#3a89e0, tree #51da60/#47c054).
  - Type sizes:
    - `font.size.body` (13) for the name
    - `caption` (10) in muted for detail lines
    - `caption` semibold for the badge
    - `mono` (12) for the CLI
- **FrogFace moods show the state.** A 28 pt `FrogFace` replaces the `cloud.fill` glyph on the
  card:
  - `.idle` when signed in
  - `.waiting` while the sheet is up, and on low credit
  - `.thinking` while setting up
  - `.done` and one `hop` on success
  - `.sad` for an error beat

  Loop timings are `motion.face.*`. Reduce Motion holds the first frame, which `FrogFace`
  already does.
- **Motion.** The card morphs between states with `motion.panel`. Rows and meters use
  `motion.quick`. The success line stays for `motion.toastDwell` (4 s). `Haptics.settle()`
  fires once when the signed-in card settles.
- **Sound.** `FrogSounds.Cue.ribbit` plays once when a sign-in completes (it's a finished
  thing), only where frog sounds are on. No sound for errors, low credit or sign out.

### Browser handoff: recommendation

**In the app, use `ASWebAuthenticationSession` with PKCE and a callback scheme (`frog-auth`)
that only that session receives. For the CLI and the magic-link email path, use the RFC 8628
device flow.**

| option | how it feels | verdict |
|---|---|---|
| `ASWebAuthenticationSession` | a system sheet over the window that asked. It shares Safari's cookies, so a signed-in GitHub is one click. It closes itself on the callback, and focus never leaves frog | **recommended** |
| app-wide custom scheme (`frog://auth`) opened from Safari | a full Safari tab, then an "open in frog?" prompt, and the tab stays behind. Any app can claim `frog://`. The Mac app doesn't register it today; iOS does, for pairing | no |
| loopback listener on 127.0.0.1 (what `mcp_oauth.rs` does for MCP) | a full Safari tab that ends on "you can close this tab", and focus stays in Safari. Fine for MCP, not Apple-level | no for the app; keep it for MCP |
| device flow (code + poll) | type or confirm a code in a browser | yes for the CLI and email; too much ceremony for the app's GitHub path |

Apple built `ASWebAuthenticationSession` for exactly this job:
- The callback goes only to the session that asked for it. Nothing can hijack the scheme, and
  frog registers no app-wide URL.
- It works without a running server.
- With `prefersEphemeralWebBrowserSession = false`, the user's existing GitHub cookie makes
  sign-in one click.

The deployment target is macOS 26, so the newer `ASWebAuthenticationSession.Callback.customScheme`
API is available. An https callback on frog.toys (associated domains) can come later without
changing the UX.

**The GitHub flow in the app** (the deep-link return is step 3):

1. The app makes a PKCE verifier and S256 challenge, plus a random 128-bit `state`.
2. It starts the session on
   `https://frog.toys/auth/app?provider=github&challenge=…&state=…&device=<device_name>`,
   with callback scheme `frog-auth`. The session anchors to the window that asked: Settings,
   or the conversation for an inline moment.
3. The edge runs GitHub OAuth (Better Auth) and redirects to `frog-auth://done?code=…&state=…`.
   The session hands that URL to its completion handler, and the sheet closes. Nothing else on
   the Mac sees the URL.
4. The app checks `state` in constant time and drops the session if it doesn't match.
5. The app sends `code` and the verifier to the engine over the existing protocol. The engine
   calls `POST /v1/auth/exchange` and writes the key to the Keychain itself, so the key only
   ever goes from the engine to the Keychain. The app gets back the `account` shape (§5), never
   the key.
6. The engine fetches `/v1/me/usage`, and the card settles into the signed-in state.
   `cloud/dart` becomes the starting model, unless the user picked one themselves.

**The magic link in the app:**
1. The user types an email address.
2. The engine starts a device grant tied to that address (`POST /v1/auth/device` with `email`),
   and the edge emails a link.
3. The engine polls `/v1/auth/token`, as the CLI does.

The link opens in whatever browser the mail client uses, on any device, so opening it on a
phone works. Nothing has to come back into the app.

## 2. The card

The card is one row in the existing "Cloud" `Section` of the grouped `Form` (Settings →
Models), where `FrogCloudCard` sits today. It's first in the section and can't be removed. Its
layout is the same in every state, so it morphs instead of swapping:

```
┌──────────────────────────────────────────────────────────────────┐
│ [face]  frog cloud  [badge]                     [primary] [ ⋯ ]  │
│  28pt   detail line (caption, muted, wraps)                      │
│         [meter + week row: only when there's a key]              │
└──────────────────────────────────────────────────────────────────┘
```

- **face**: `FrogFace(mood:size: 28)`, top-aligned with the first baseline of the title, with
  a 10 pt gap.
- **title**: "frog cloud" (body).
- **badge**: the plan capsule (caption semibold, accent on accent 18%, padding 5×1,
  `radius.pill`). It shows the edge's `plan` string as is, and is hidden when there's no key.
- **primary**: at most one button, `.controlSize(.regular)`.
- **⋯**: an `ellipsis.circle` borderless menu, as today. Everything else goes in it.
- The row grows downward (the meter, the email field), and `motion.panel` animates the height.

### State 1: signed out (no key anywhere)

| part | value |
|---|---|
| face | `.idle` |
| badge | none |
| primary | **Sign in with GitHub** (`.borderedProminent`, GitHub mark `Image("github")` 14 pt leading) |
| ⋯ menu | "Sign in with email", "Try 2 tasks free on this mac", "Use an API key…", "Get an API key on the web" |

> **frog cloud**
> fast hosted models, one click away. your code only goes there in projects you allow.
> use email instead

Under the detail line is one tertiary, link-style button: **use email instead**. It does the
same as the menu item. It's there because not everyone has GitHub.

**Email sub-state.** "use email instead" grows the row by one line (`motion.panel`) with:
- a `TextField`: "you@example.com", `.roundedBorder`, 220 pt, focused, content type
  `.emailAddress`
- **Send link** (`.borderedProminent`): disabled until the text looks like an address, and ⏎
  sends.

Esc or **Cancel** collapses the line. After sending:

> **frog cloud**
> check cam@muni.works · the link works for 15 minutes, on any device.
> change · resend

- The face is `.waiting`.
- "resend" is disabled for 30 s, then sends again: a new grant, and the old one is dropped.
- "change" goes back to the field with the address selected.
- The engine polls the device grant every `interval` (5 s by default; `slow_down` adds 5 s).
  When the link is opened, the card goes straight to 2b. The grant expires after 15 min (see
  errors).

**Trial** ("Try 2 tasks free on this mac", onboarding decision 2): one click, no account. The
engine calls `POST /v1/auth/trial`, which mints a key for this device with 50¢ of credit (2
tasks). The card moves to state 5, trial variant. The same action is offered on onboarding's
open screen and at the hard-task moment.

### State 2: signing in (browser handoff and deep-link return)

Signing in has three beats, all in the same row. The window that asked stays where it is, and
the system sheet attaches to it.

**2a. sheet up.** Clicking Sign in with GitHub starts `ASWebAuthenticationSession`.
- macOS shows its own consent alert first: "“frog” wants to use “frog.toys” to sign in", with
  Cancel and Continue. That's the system, and we don't fight it.
- After Continue, the sheet shows frog.toys handing off to GitHub. If GitHub knows the user,
  that's a single Authorize button the first time, and nothing at all after that.
- Behind the sheet, the card shows:

  > **frog cloud**
  > finish signing in on the sheet

  The face is `.waiting`. **Cancel** (`.bordered`) replaces the primary button, so a second
  sign-in can't start. It calls `session.cancel()`.

**2b. setting up (the return).** The `frog-auth://done` callback arrives (§1, step 3) and the
sheet closes by itself. The card shows:

> **frog cloud**
> setting up this mac…

The face is `.thinking`. This beat covers the exchange, the Keychain write and the first usage
fetch, and the target is under 1 s. There's no spinner: the thinking frog is the spinner.

**2c. success.** One beat, then the signed-in card.
- The face goes `.done` with one `hop`. `FrogSounds.Cue.ribbit` plays (when sounds are on),
  and `Haptics.settle()` fires as the meter rows land (`motion.panel`).
- For 4 s (`motion.toastDwell`) the detail line reads **signed in · dart is ready**, then it
  settles into the state 3 line.
- If the starting model (`Workspace.startingModel`) was the default rather than one the user
  picked, it becomes `cloud/dart`. If the user had picked a model, it stays, and the line reads
  **signed in · dart is in the model menu** instead. Sign-in adds; it doesn't take over.
- If sign-in started from an inline moment (the picker, `BiggerModelLine`, the hard task), the
  sheet anchored to that conversation and Settings never opened. After the beat, the
  conversation that asked switches to `cloud/dart`. The per-project "code goes to the cloud"
  consent still applies, as today.

The email path joins at 2b when the poll succeeds. If the app is in the background then, it
posts a notification, "signed in to frog cloud", when notifications are on. Otherwise nothing.

### State 3: signed in (the account card)

| part | value |
|---|---|
| face | `.idle` |
| badge | the plan: `free`, `pro`, `max` or `api` |
| primary | none: a signed-in card has nothing to ask |
| ⋯ menu | "Manage on frog.toys" (opens frog.toys/account), "Sign out" |

```
[face] frog cloud [pro]                                          [⋯]
       @campedersen · cam@muni.works
       ████████████████████░░░░░░░   56 tasks left · resets nov 1
       ▁▃▂▅▇▂▁   this week · 212 tasks
```

- **identity line**: `@handle · email` after a GitHub sign-in, just the email after an email
  sign-in. Caption, muted.
- **credit meter**: a 6 pt capsule, 180 pt wide. The track is text at 10%, the fill
  `color.accent`, and the fraction is `tasks_left / tasks_limit`. To its right is a caption
  with monospaced digits:
  - pro / max: `56 tasks left · resets nov 1`
  - free: `20 tasks left` (the sign-in credit, no reset)
  - api: `124 tasks left` (pay as you go). There's no limit, so no meter, just the text. Here
    "tasks" is the balance divided by the edge's average task cost.
- **this week**: seven bars (Swift Charts `BarMark`, 56×16 pt, one per day, today last) in
  `color.faint`, today's bar in accent, then the caption `this week · 212 tasks`.
  - A "task" is a finished turn on frog cloud. That's the unit we charge for, so usage and
    credit count the same thing.
  - Hovering a bar shows `.help` with `tue · 41 tasks`.
- **Fresh, not chatty.**
  - `/me` and usage load when Settings opens (at most every 10 min, with a 3 s timeout, as in
    the account plan), and after each frog cloud turn ends (debounced 30 s).
  - If a fetch fails, the last values stay, dimmed to faint, with `updated 2h ago`. A network
    error never shows as "signed out".
- **Money rows.** The existing "Spent this week / this month" rows under the section show
  dollars for `api` only, and `included` for `free`, `pro` and `max`.

**Variants.**
- **`FROG_API_KEY` set in the environment** (it wins, per the account plan):
  - The identity line reads `using FROG_API_KEY from your shell`.
  - The meter shows that key's account, if `/me` answers for it.
  - ⋯ keeps "Sign out". It clears the saved sign-in, not the shell's key.
- **Pasted API key, no sign-in** (the `api` plan, CI users):
  - The badge is `api` and the identity line is `api key · keychain`.
  - ⋯: "Change key…", "Remove key", "Sign in with GitHub instead".
  - This is today's card, restyled, and it stays.

**Sign out.** ⋯ → "Sign out", with no dialog.
- The card animates back to state 1 (`motion.panel`) and the face goes `.idle`.
- The engine revokes the key (best effort) and deletes the Keychain item.
- Conversations on `cloud/…` show the existing "pick a model" path on their next turn. A
  conversation in the middle of a turn finishes that turn first.

### State 4: credit running low (the upgrade moment)

This is the one place frog asks for money, so it has to earn it. It shows where the credit is
being spent, at a moment the user isn't waiting on anything, once.

**When.** Credit is low when either of these is true:
- what's left would last under 2 days at this week's pace
  (`tasks_left < 2 × week_tasks / 7`)
- under 10% of `tasks_limit` is left

But it's never low with more than 20 tasks left, so heavy users aren't nagged with a week of
work still in hand. The engine checks when a frog cloud turn ends. `api` plans use the same
rule.

**Where: one line above the composer**, in the `PingLine` / `BiggerModelLine` slot, with the
same height and the same × at the right. It appears only in the conversation whose frog cloud
turn just finished: no notification, no sheet, not every conversation.

**The line** (exact):

> 3 frog cloud tasks left · about 2 days at your pace **Upgrade to pro** ×

- **The number**: `about N days`, rounded down. Under a day it reads `less than a day`. Hours
  are never used, so there's no countdown pressure.
- **The action**, by plan:
  - free → **Upgrade to pro**
  - pro → **Upgrade to max**
  - max and api → **Add credit**

  It opens frog.toys/upgrade (or frog.toys/account for Add credit) in the default browser,
  because checkout lives on the web. When the user comes back (the app becomes active), the
  engine refreshes `/me` once. If credit went up, the line goes away by itself.
- **The face**: a small `FrogFace(.waiting, size: 16)` leads the line, as in the activity pill.
- **Once per credit period.** × (or the action) hides the line until `resets_at`, or until
  credit next reaches zero. It doesn't come back on the next turn.

**On the card**, while credit is low:
- the meter fill turns `color.warning`
- the caption reads `3 tasks left · about 2 days at your pace`
- the face is `.waiting`
- a primary button appears with the line's action (**Upgrade to pro** / **Upgrade to max** /
  **Add credit**, `.borderedProminent`). It goes away once credit isn't low.

**At zero.** Nothing breaks, and nothing stops halfway. A turn that started with credit
finishes on frog cloud: the edge allows up to 2 tasks of overdraft, as onboarding decided. The
next request gets the existing 402, which moves the turn to this mac's model.
- **The first time ever** (onboarding screen 15): one card in the transcript, after the turn,
  never during it.

  > that one finished on the last of your cloud credits · from here i'm back on this mac,
  > free, unless you pick otherwise.

  Its choices are pro $20 · stay on this mac (✓ on) · pay as you go.
- **Every time after that** (exact, once per period):

  > frog cloud is out of tasks · back on this mac **Upgrade to pro** ×

The card's meter is empty and orange, with the caption `out of tasks · resets nov 1` (pro/max)
or `out of tasks` (free/api). If this mac has no usable model, the turn stops with the same
line and the existing "pick a model" path, so failed requests can't loop.

### State 5: a key without an account (invite and trial keys)

Two cases share one card:
- **invite**: beta users who redeemed an invite and pasted a `frog_` key before sign-in
  existed. `/me` answers `plan: beta`, `email: null`.
- **trial**: someone who clicked "Try 2 tasks free". `plan: trial`, `email: null`, and the key
  only works on this device.

The key keeps working whether or not they sign in. Signing in attaches it to an account, so it
shows on the web, survives a new mac, and can be upgraded. Signing in also adds the $5
sign-up credit (20 tasks).

| part | value |
|---|---|
| face | `.idle` |
| badge | `beta` or `trial` |
| primary | **Sign in with GitHub** (`.bordered`, not prominent: it's an offer, not a fix) |
| ⋯ menu | "Sign in with email", "Change key…" (invite only), "Remove key" |

> **frog cloud** `beta`
> invite key · keychain. sign in to keep its credit with your account.
> ████████░░░░░░  16 beta tasks left

> **frog cloud** `trial`
> trial · this mac only. sign in to keep it, plus 20 tasks.
> ███░░░░░░░░░░░  1 trial task left

The meter and week row show as in state 3, since the key can read `/me` and usage. There's no
identity line.

**Migration, when they sign in.** It's the state 2 flow plus a claim, and the user sees no
extra step:
1. The GitHub sheet or the email link, as usual. During 2b the line reads
   `setting up this mac and moving your credit…`.
2. The engine exchanges the code for a new key. Then it calls `POST /v1/auth/claim`, with the
   new key as bearer and the old key in the body. The edge moves the credit and usage history
   to the account and retires the old key.
3. The engine swaps the Keychain item only once the claim succeeds and `/me` answers for the
   new key. Until then every request uses the old key, so no turn ever runs without a working
   key.
4. The success line shows for 4 s, then state 3:
   - invite: **signed in · your beta credit came with you**
   - trial: **signed in · 21 tasks ready** (what was left, plus 20)

If the claim fails, nothing changes:
- The old key stays in the Keychain and keeps working.
- The new key is revoked (best effort) and never stored.
- The card stays in state 5 with `couldn't move your credit just now · try again`. The face is
  `.sad` for that beat, then `.idle`.

**No nagging.**
- Invite-key users get no line above the composer, no badge and no prompt. The offer lives on
  the card, and in `frog login --status` in the CLI. They lose nothing by ignoring it.
- Trial users see only the onboarding moments, each once per trigger.
- A user with only an env `FROG_API_KEY` is never offered migration from the app, because
  it's the shell's key.

## 3. Errors

Every error is one line on the card that says what happened and what to do next. The face goes
`.sad` for that moment, then relaxes to the state's own mood after 3 s. The text stays until
the next action. Nothing ever deletes a working key because of an error. The copy is exact.

| what happened | card line | action shown | notes |
|---|---|---|---|
| user closed the sheet or pressed Cancel (the system alert too) | (back to state 1, no message) | Sign in with GitHub | cancelling isn't an error |
| GitHub, or the user, declined | `github didn't sign you in · try again, or use email` | Try again · use email instead | edge `access_denied` |
| can't reach frog.toys (offline, DNS, timeout) | `can't reach frog.toys right now` | Try again | checked with `NWPathMonitor` before the sheet opens, so it never opens on an error page |
| `state` mismatch or malformed callback | `that sign-in didn't come from this mac` | Try again | log a warning, never the URL's query |
| exchange failed after GitHub succeeded | `signed in, but couldn't set up this mac` | Try again | retry runs the whole sheet again, which is one click because the GitHub cookie is warm |
| Keychain write failed | `couldn't save to your keychain` | Try again | the new key is revoked, best effort |
| email: address rejected | `that address didn't work · check it and send again` | (field stays open) | edge `invalid_email` |
| email: link expired (15 min) | `that link expired · send another` | Send another | the field keeps the address |
| email: link opened, then turned down | `that link was turned down · send another` | Send another | |
| claim failed (state 5) | `couldn't move your credit just now · try again` | Try again | old key kept, new key revoked |
| `/me` fails while signed in | meter dimmed, `updated 2h ago` | none | never shown as signed out |
| 401 on a frog cloud request (key revoked or expired) | line above the composer: `your frog cloud sign-in expired` **Sign in again** × | Sign in again (starts the sheet from the line) | the key isn't deleted on its own; the card shows state 1 with the detail `your sign-in expired` |
| 401 for an env key | line: `frog cloud turned down FROG_API_KEY · check your shell` × | none | signing in can't fix this, so it isn't offered |
| account suspended (403) | `this account can't use frog cloud right now` | Manage on frog.toys | |
| too many sign-ins (429) | `too many sign-ins just now · try again in a minute` | Try again (disabled for `retry_after`) | |

Every network call in the flow times out after 10 s, except polls, which follow `interval`.

## 4. CLI parity

The CLI uses the device flow (RFC 8628) and rewrites one line in place, in the same voice. It
never prints a key, with or without `--json`. The key goes into the same Keychain item the app
uses, so signing in on one side signs in both.

```
$ frog login
enter WDJB-MJHT at frog.toys/device (opened in your browser) · waiting
```

On success, the same line is rewritten (`\r` and clear) to:

```
signed in as cam (@campedersen) · pro · 56 tasks left · cloud/dart is ready
```

- **Opening the browser.** On a desktop session, frog opens `frog.toys/device?code=WDJB-MJHT`
  itself. Over SSH (`SSH_CONNECTION` is set), or with no browser, it doesn't, and the line
  reads `open frog.toys/device and enter WDJB-MJHT · waiting`. The page shows the code and asks
  "is this the code in your terminal?" before approving.
- **Code format.** 8 letters as `XXXX-XXXX`, from the RFC 8628 §6.1 alphabet with no vowels.
  A code can't spell a word, and it reads aloud cleanly. (Onboarding's mock `KXRT-4QPM` has a digit; letters only is the change.)
- **Waiting.** On a TTY, a trailing `·` after `waiting` pulses once a second; there are no
  spinner glyphs. Without a TTY, the code line prints once and the result prints on its own
  line.
- **Email instead.** `frog login --email cam@muni.works` →
  `check cam@muni.works for a link · works for 15 minutes · waiting`.
- **Invite or trial key present.** Same flow; the success line ends
  `· your beta credit came with you` (or `· 21 tasks ready`).
- **Already signed in.** `already signed in as cam (@campedersen) · frog logout to switch`.
- **`FROG_API_KEY` set.** Login still works and saves the sign-in, then prints a second line:
  `note: FROG_API_KEY from your shell wins over this sign-in`.
- **No keychain** (Linux without a secret service). The key goes to
  `~/.config/frog/credentials` (mode 0600), and the success line adds
  `· saved to ~/.config/frog/credentials`. The key itself is still never printed.

Outcomes (exit codes: 0 ok, 1 failed, 130 cancelled):

| case | line |
|---|---|
| ctrl-c | `cancelled` |
| code expired (15 min) | `that code expired · run frog login again` |
| turned down on the page | `turned down at frog.toys/device · run frog login again` |
| offline | `can't reach frog.toys · check your connection and run frog login again` |
| keychain write failed | `couldn't save to your keychain · nothing changed` |

**`frog logout`** prints one of:
- `signed out · this mac's key is revoked`
- offline: `signed out · can't reach frog.toys, so the key gets revoked next time you're online`
- only an env key: `nothing to sign out · FROG_API_KEY comes from your shell`

**`frog login --status`** (alias `frog account`) prints one line, in the same order as the
card:

| state | line |
|---|---|
| signed in | `cam (@campedersen) · pro · 56 tasks left · 212 tasks this week · cloud/dart` |
| low credit | `cam (@campedersen) · free · 3 tasks left, about 2 days at your pace · frog.toys/upgrade` |
| signed out | `not signed in · frog login` |
| invite key | `invite key · beta · 16 tasks left · frog login to keep it with an account` |
| trial key | `trial · 1 task left · frog login for 20 more` |
| env key | `FROG_API_KEY from your shell · api · 124 tasks left` |
| offline | `cam (@campedersen) · pro · can't reach frog.toys, last seen 56 tasks left` |

`--json` prints `{signed_in, handle, email, plan, tasks_left, tasks_limit, week_tasks,
resets_at, source}`, where `source` is `signin`, `keychain`, `trial`, `env` or null. No key.

**Low credit during a run.** When a frog cloud turn ends and the state 4 rule fires, one dim
line prints, once per credit period: `3 frog cloud tasks left · about 2 days at your pace ·
frog.toys/upgrade`. At zero, the fallback prints `frog cloud is out of tasks · back on this
mac · frog.toys/upgrade`.

## 5. Edge contract

The frog cloud manager owns the implementation: Better Auth on Cloudflare Workers, Postgres
as the source of truth, Durable Objects for live credit and rate limits, and KV as a cache
only. This section is the **interface the app and CLI need**, nothing more. Names can change;
the guarantees can't.

### Hosts, auth, errors

- **Web pages** live on `https://frog.toys`: `/auth/app`, `/device`, `/account`, `/upgrade`.
  They use Better Auth cookie sessions and never return a key to a browser.
- **JSON** lives on `https://api.frog.toys/v1/…`. Keyed calls take
  `Authorization: Bearer frog_…`. The engine pins this host and never sends the key anywhere
  else (account plan).
- **Errors** have one shape: `{"error": {"code": "…", "message": "…"}}` plus the HTTP status.
  The app maps `code` to the §3 copy. `message` is for logs and never shown. The codes:
  - `authorization_pending`, `slow_down`, `expired_token`, `access_denied` (RFC 8628)
  - `invalid_grant` (400)
  - `invalid_email` (400)
  - `invalid_key` (401)
  - `insufficient_credit` (402)
  - `suspended` (403)
  - `rate_limited` (429, with `retry_after` in seconds)

### Endpoints

| # | call | request | success | errors |
|---|---|---|---|---|
| E1 | `GET frog.toys/auth/app` | query `provider=github`, `challenge` (S256), `state`, `device` | 302 → `frog-auth://done?code&state`. The code is single-use with a 60 s TTL | 302 → `frog-auth://done?error=access_denied&state` |
| E2 | `POST /v1/auth/exchange` | `{code, verifier, device_name}` | `{key, account}` | `invalid_grant`, `rate_limited` |
| E3 | `GET /v1/me` | bearer | `account` | `invalid_key`, `suspended` |
| E4 | `GET /v1/me/usage?range=7d&tz=…` | bearer | `{days: [{date, tasks}], week_tasks}`: 7 days, oldest first, today last, in `tz` | `invalid_key` |
| E5 | `POST /v1/auth/device` | `{device_name, email?}` | `{device_code, user_code, verification_uri: "https://frog.toys/device", verification_uri_complete, interval: 5, expires_in: 900}`. With `email`, the edge also sends the magic link | `invalid_email`, `rate_limited` |
| E6 | `POST /v1/auth/token` | `{device_code}` | `{key, account}` once approved | `authorization_pending`, `slow_down`, `expired_token`, `access_denied` |
| E7 | `POST /v1/auth/trial` | `{device_id}` | `{key, account}` with `plan: trial` and 2 tasks. One per device, ever | `rate_limited`, also when this device already had one |
| E8 | `POST /v1/auth/claim` | bearer = the new key; body `{legacy_key}` | `account`, with credit and usage merged. Idempotent: the same account claiming again gets 200 | `invalid_key` (unknown legacy key, or claimed by another account) |
| E9 | `POST /v1/auth/revoke` | bearer | 204 | `invalid_key` counts as success |

`account` has one shape everywhere:

```json
{ "plan": "free|trial|beta|pro|max|api",
  "handle": "campedersen", "email": "cam@muni.works",
  "tasks_left": 56, "tasks_limit": 80, "resets_at": "2026-11-01T00:00:00Z",
  "credit_cents": 1400, "task_cost_cents": 25 }
```

- **Tasks are the edge's number** *(superseded: apps show `credit_cents` as dollars; see the
  note at the top).* The edge computes
  `tasks_left = floor(credit_cents / task_cost_cents)` from live credit (the Durable Object).
  If the price per task changes, every screen is right the next time `/me` answers. The app
  never does money math; it renders `tasks_left` and nothing else.
  - `tasks_limit` is the period's grant. It's null for `api`, which has no meter.
  - `resets_at` is null for `free`, `trial`, `beta` and `api`.
  - `credit_cents` and `task_cost_cents` are there for the CLI's `--json` and for
    debugging, not for display.
- `handle` is null after an email sign-in. `email` is null for `trial` and unclaimed `beta`
  keys.

### Guarantees the UX depends on

1. **Mint on every sign-in.** E2 and E6 mint a fresh `frog_` key (32 random bytes, base62),
   one per `device_name`, tied to the user.
   - The response is the only time the plaintext exists. The edge stores a SHA-256 hash and
     the last 4 characters (for the device list on frog.toys/account).
   - Signing in again from the same device revokes that device's previous key.
2. **Sign-up credit.** A user's first sign-in grants $5 (20 tasks) at plan `free`, once per
   user, with no card (onboarding decision 3). A claimed trial adds what's left of it on top.
3. **No orphaned keys.** If E2 or E6 fails after minting, the edge revokes the key. The
   engine never receives a key it can't use.
4. **The claim is atomic.** E8 moves the credit and usage and retires the legacy key in one
   transaction. Until it commits, the legacy key keeps working.
5. **The last task finishes.** A turn that starts with `tasks_left ≥ 1` may finish with up to
   2 tasks of overdraft ($0.50, as onboarding decided). The next request returns 402
   `insufficient_credit`.
6. **Fast and quiet.**
   - `/v1/me` answers within 3 s at p99, because it's on the path that opens Settings.
   - Keys never appear in edge logs, redirects or URLs, and `code` only appears in the
     `frog-auth://` redirect.
7. **Rate limits.** Minting is limited to 10 an hour, per IP and per device. Polls (E6) don't
   count against it.

### Open for the frog cloud manager

- Whether claimed `beta` invite keys become `free`. The UX shows whatever `plan` says.
- Where `device_id` for E7 comes from. Proposal: a random UUID the engine keeps in the
  Keychain. It survives reinstalls and says nothing about the person.
- Where the onboarding schema lives (onboarding spec §5: persona, memory, routines). It's out
  of scope here, but it keys on the `user_id` that E2 creates.

## 6. Build plan (smallest first)

Every step ships on its own, and the app looks finished after each one. App and edge are
separate queues, and each app step names the edge step it waits on.

**Edge (the frog cloud manager's queue):**

1. **E1 + E2 with auto-mint and the sign-up credit**, GitHub only. This is the only edge work
   the goal sentence needs.
2. **E3 `/v1/me`** returning the `account` shape. The signed-in card renders from this alone.
3. **E9 revoke.** A small step, and it makes sign-out honest.
4. **E4 usage.** Feeds the week row and the pace part of the low-credit rule.
5. **E5 + E6 device flow**, with the frog.toys/device page and the magic-link email. Unlocks
   the CLI and email sign-in.
6. **E8 claim.** Invite and trial migration.
7. **E7 trial.** Last on the edge, because it's the only call with no account behind it, so
   it needs the abuse limits settled first.

**App and CLI:**

| step | what ships | needs |
|---|---|---|
| A1 | **Key path.** `KeySheet` saves through the engine into the Keychain item the engine reads (`account: cloud`), and `FROG_API_KEY` handling lands. The card keeps its paste flow; only the storage moves | nothing |
| A2 | **Signed-out card.** The state 1 layout with FrogFace and the ⋯ menu (key items). Sign in with GitHub stays behind `FROG_SIGN_IN` | nothing |
| A3 | **Sign-in flow.** `ASWebAuthenticationSession` + PKCE, beats 2a–2c, the §3 error table, sign-out (revoke when E9 is live). Turns `FROG_SIGN_IN` on | E1, E2 |
| A4 | **Signed-in card.** Identity, the meter in tasks left, polling `/me` at the cadence above | E3 |
| A5 | **Low credit.** The line above the composer, the card's orange state, and at-zero. The 10% rule works on `/me` alone; the pace rule waits for E4 | E3 (E4) |
| A6 | **Week row.** Seven bars and `this week · N tasks` | E4 |
| A7 | **CLI.** `frog login` / `logout` / `--status` / `--json`, then the low-credit line during runs | E5, E6 |
| A8 | **Email in the app.** The email sub-state, polling E6 | E5, E6 |
| A9 | **State 5 + migration.** The invite card and claim wiring, then the trial variant | E8 (E7) |

**Cut line for the first release:** A1–A4 and E1–E3. That covers the goal sentence: sign in,
the key minted and stored, the next turn on `cloud/dart`, and the card showing tasks left.
Paste stays for API users. Everything after it adds detail.

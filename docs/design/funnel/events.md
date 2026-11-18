# Funnel events

What Frog records so the onboarding funnel (two lanes: web + Frog Cloud, Mac + local models;
design canvas "Frog onboarding funnel") can be measured, and what it never records.

All events go to one PostHog project, and **all of them are sent by the gateway**
(`api.frog.toys`, zest `edge/src/posthog.ts`). The gateway sends the facts it already knows
(sign-up, credit, payments, coupons, sessions) on its own. The web and Mac apps send the few
facts only they can see to the gateway's `POST /v1/events`. The gateway forwards them only if
the event name and every property are on its allow-list (`CLIENT_EVENTS` in `posthog.ts`).
Clients never talk to PostHog, so:

- PostHog never sees a person's IP address or browser. Every event is sent from Cloudflare with
  `$geoip_disable: true`. The PostHog project should also have IP data capture turned off
  (Settings › Project › Privacy).
- The allow-list lives in one place, the gateway, and has no free-text properties: only enums,
  numbers and booleans.
- Nobody can send an event as somebody else. For a signed-in client, the gateway takes the
  distinct id from the bearer key, never from the request body.

## Who an event is about

- **Signed in, anywhere:** `distinct_id` is the account's opaque user id (the UUID in
  `user:<uuid>`), the same on every surface. Gateway accounts that aren't user accounts (invite
  keys, operator keys) send nothing.
- **Signed-out Mac, opted in:** `distinct_id` is a random install id. The Mac creates it when the
  person turns on **Share usage with Frog** and deletes it when they turn the setting off. On the
  first sign-in from that Mac, the Mac sends that id once with its key, and the gateway sends
  PostHog an `$identify` with `$anon_distinct_id`, so the local-model steps join the account.
- **Signed-out web:** nothing is sent. The web has no cookie or stored id. The site's
  cookieless install counts (`/download`, `/install.sh`) already cover the top of the funnel as
  totals.

## Never sent

These are never sent, not as an event name, a property or an id:

- prompts, answers, or anything typed
- code, file names, paths, diffs, or repository, branch or PR names and numbers
- email addresses, names, GitHub logins, device names, or IP addresses
- coupon codes or labels
- model names (only the kind of model: `apple` or `local`)

## How it's turned on

Every switch is off until PostHog is configured, and turning PostHog on is what turns on every
surface:

| Surface | Off when | On when |
|---|---|---|
| Gateway | `POSTHOG_KEY` or `POSTHOG_HOST` is unset (both are needed; the host decides US or EU, e.g. `https://us.i.posthog.com`) | both are set (`wrangler secret put POSTHOG_KEY`, `POSTHOG_HOST` as a var) |
| Web | the account from `/v1/me` or the sign-in exchange has no `events: true` (the gateway sets it only when PostHog is configured) | signed in, and the gateway says `events: true` |
| Mac | **Share usage with Frog** (Settings › General) is off, which is the default | the person turned it on. Even then the gateway drops the events unless PostHog is configured |

## Events

Surface: **G** = gateway on its own, **W** = web via `/v1/events`, **M** = Mac via `/v1/events`.
"Today" says whether the event can be sent truthfully with what exists now. ✅ means it is wired
in these PRs. ⏳ means it needs something that doesn't exist yet, which is named in the row.

| Event | Fires when | Surface | Properties | Funnel step | Today |
|---|---|---|---|---|---|
| `account_created` | an account is created: email link verified, first GitHub or Google sign-in, or first Mac/browser app exchange | G | `method`: `email` \| `github` \| `google` \| `app` | both lanes: entry | ✅ |
| `first_credit_granted` | the 25¢ first-session credit lands (`grantFirstCredit` returned true) | G | `amount_usd` (0.25) | web: entry | ✅ |
| `github_connected` | a GitHub identity is linked to the account for the first time (sign-in with GitHub or connect). Once per account (a DO claim) | G | — | web: their own code | ✅ (accounts that linked GitHub before deploy fire once, on their next GitHub sign-in) |
| `signup_credit_granted` | the GitHub top-up to $1 lands (`grantSignupCredit` returned true) | G | `amount_usd` (0.75, or 1.00 for an account older than the first-session credit) | web: their own code | ✅ |
| `app_signed_in` | an app exchanges a sign-in code for a key | G | `client`: `browser` (request from an allowed web origin) \| `app` (no browser origin: the Mac or the CLI); `new_account` | Mac: more machines (`client=app`) | ✅ |
| `session_started` | the gateway answers 2xx to `POST /v1/sessions` (a Frog Cloud sandbox is created) | G | `client`: `browser` \| `app` | web: watch it work; Mac: first cloud run (`client=app`) | ✅ |
| `turn_finished` | a cloud session's last turn ends, as seen by the open web app (its `last_turn` moves forward between two session-list polls) | W | `client`: `web` | web: watch it work (visible result) | ✅ for "a turn finished". ⏳ for "with something running in Preview": it needs a preview-loaded signal, and the preview code is being changed in another PR |
| `pr_opened` | a cloud session gets a pull request bound to it (its `pr` goes from empty to set while the web app is open) | W | `client`: `web` | web: their own code (first PR) | ✅ when the web app is open at the time. ⏳ a PR opened with no tab open is only seen if a tab is open later, and then it doesn't fire. The sandbox gateway should send this instead (it binds the PR) |
| `credit_low` | an account without a plan has used 80% of the credit it was given | G | — | web: a habit | ⏳ the Account DO keeps no running total of credit granted, so "80% of what" has no answer yet. Needs a `granted` total in the DO's state |
| `out_of_credit` | a debit takes an account without a plan from above zero to zero or below. Once per crossing, never on a redelivered debit | G | — | web: a habit (the wall) | ✅ |
| `credit_purchased` | a Stripe top-up payment succeeds (every top-up) | G | `amount_usd`, `first` | web: a habit (first payment) | ✅ |
| `coupon_redeemed` | a coupon's credit lands | G | `amount_usd` | web: a habit | ✅ |
| `plan_started` | a subscription checkout completes | G | `plan`, `interval`, `amount_usd` | web: a plan | ✅ |
| `plan_cancelled` | a subscription is cancelled | G | `plan` | web: a plan | ✅ |
| `payment_failed` | a subscription invoice fails | G | `plan` | (diagnostic) | ✅ |
| `local_answer` | a turn on a local or Apple model ends complete, on the Mac | M | `model`: `apple` \| `local` | Mac: an answer, no account | ✅ (opt-in) |
| `model_download_started` | a model download starts on the Mac | M | — | Mac: a real model | ✅ (opt-in) |
| `model_download_finished` | a model download finishes on the Mac | M | `ok` (false when it failed) | Mac: a real model | ✅ (opt-in) |
| `edit_accepted` | the person approves an Edit or Write permission prompt on the Mac | M | — | Mac: their project | ✅ (opt-in). It misses edits made in auto mode, which never ask. Counting every completed edit would need a hook on tool results |
| `handoff_clicked` | a hand-off between the lanes is clicked | W, M | `from`: `web` \| `mac`; `to`: `mac` \| `cloud`; `where`: see below | the loop between lanes | partly, see below |

### Hand-offs (`handoff_clicked`)

| `from` → `to` | `where` | The moment (canvas) | Today |
|---|---|---|---|
| web → mac | `credit_wall` | "Finish on your Mac" on the out-of-credit card | ✅ |
| web → mac | `chip` | the sidebar chip "Get the Mac app" | ✅ |
| web → mac | `composer` | "Get the Mac app" in the composer's machine menu | ✅ |
| web → mac | `settings` | "Get the Mac app" in Settings › Pair a machine | ✅ |
| web → mac | `footer` | the footer link | ✅ |
| web → mac | `price` | "$0 on your Mac" on every price | ⏳ the line doesn't exist yet |
| mac → cloud | `composer` | "Run in Frog Cloud" from the composer | ✅ (opt-in) |
| mac → cloud | `lid`, `bigger_model`, `third_task` | the three limits a Mac user feels | ⏳ none of the three prompts exist yet |

The web sends hand-off clicks from one click listener (`apps/web/src/track.ts`), which matches
links to `/mac` and `/download`. `where` comes from the nearest labelled container, so the cards
that are being redesigned don't need code changes to keep being counted.

## The funnels

To build them in PostHog: a funnel insight with the steps below in order, aggregated by unique
persons, with a conversion window of 14 days unless a different one is given. A step is entered
by the **first** time its event fires for that person. Repeats are expected, because some events
fire once per poll, per tab or per debit, so the funnel uses first occurrence.

### Web and Frog Cloud lane

| # | Step (canvas) | Entered by |
|---|---|---|
| 1 | Signed up | `account_created` |
| 2 | Watch it work | `session_started`, then `turn_finished` (two funnel steps) |
| 3 | Their own code | `github_connected`, then `pr_opened` |
| 4 | A habit (first payment) | `credit_purchased` (its first occurrence; `first = true` marks it too) or `plan_started`. Use one PostHog step with the two events as alternatives. `coupon_redeemed` is free credit, so keep it out of the payment step and add it as its own step if wanted |
| 5 | A plan | `plan_started` |

### Does the sign-up credit convert?

The question that started this work:

| # | Step | Entered by |
|---|---|---|
| 1 | Got the 25¢ | `first_credit_granted` |
| 2 | Used it | `session_started` |
| 3 | Got to $1 | `signup_credit_granted` |
| 4 | Hit the wall | `out_of_credit` |
| 5 | Paid | `credit_purchased` |

Time from wall to resume: step 4 to step 5 of this funnel, shown as time to convert.

### Mac and local models lane

All four steps need **Share usage with Frog** turned on, except steps 4b and 4c, which the
gateway records for any signed-in Mac.

| # | Step (canvas) | Entered by |
|---|---|---|
| 1 | An answer, no account | `local_answer` |
| 2 | A real model | `model_download_started`, then `model_download_finished` with `ok = true` |
| 3 | Their project | `edit_accepted` |
| 4 | More machines | `app_signed_in` with `client = app`, then `session_started` with `client = app` (the first cloud run). Machine pairing isn't counted yet |

Steps 1–3 join step 4 through the `$identify` the gateway sends on the first signed-in event
from an opted-in Mac. Without opt-in, the lane starts at step 4.

### The loop

- Web → Mac: `handoff_clicked` with `from = web`, then `app_signed_in` with `client = app`.
- Mac → cloud: `handoff_clicked` with `from = mac`, then `session_started` with `client = app`,
  then `credit_purchased`.

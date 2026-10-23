# frog first run: onboarding spec

Mockups: `index.html` (19 screens, dark and light, ← → to step, `t` flips the theme, `?s=<id>&t=light` deep-links). Captures: `shots/`.
Thesis (approved): value first, then name, then save, then upgrades that follow value, then the head. No tour, no streaks, no badges.
Copy rules: lowercase, short, warm, no exclamation marks, no emoji. frog speaks in the first person.

## 1. Flow

1 open → 2 read (read-only scan, 0:05–0:20) → 3 propose (exactly 3 tasks; the one the repo's own tests can check comes first, 0:21) → 4 run (one click) → 5 diff (accept writes to the working tree only, no commit; **accepted by 1:14**) → 6 name (skippable) → 7 routines (drawn from repo evidence) → 8 save (sign-in sheet) → 9 saved. CLI: 10 `frog` (same first win) → 11 `frog login` (device code). Later: 12 nudges (days in) → 13 weekly receipt → 14 credits out mid-task → 15 plan (checkout, cancel). Then: 16 head card (30+ days) → 17 unbox → 18 greet. 19 edge states.

Budget: install → first accepted diff under 90 s. The scan is capped at 20 s; if it's still running, propose what's known so far. Task 1 must be finishable in under 60 s by dart; otherwise it ranks lower.

## 2. Copy by screen

**open** · h1 "what shall we fix?" · sub "pick a repo. i'll read it and suggest three things i can finish right now." · list header "recent on this mac · 4 found" · "open another folder…" / "or drop one on me" · footer "no account needed. your first tasks run on frog cloud, free. use a model on this mac instead"
**read** · row "frog · reading ledger" · tool rows (`read` / `ran`) · "just reading and running your tests. nothing changes until you say so." · composer "ask me anything about ledger…" · chip "auto · dart", "frog cloud trial"
**propose** · "here's what i can finish right now. pick one." · task: title, evidence sentence, file chips, "~40 s · your tests will check it" · buttons "fix it" / "update it" / "bump it" · composer "or tell me what to do…"
**run** · user bubble = task title · row "on it" · cause in one sentence ("`verify()` throws on an expired token, so `requireSession` never sends its 401…") · composer "steer me, or press esc to stop…"
**diff** · row "done · both tests pass · nothing else in auth/ moved" · "fixed. here's the change. nothing is applied until you accept." · footer "✓ 14 of 14 pass in src/auth/ · 214 of 214 overall" · "discard" / "change something…" / "accept ⌘↩"
**name** · "✓ accepted · applied to your working tree, not committed · first fix · 1:14" · h2 "nice one. want to name me?" · "the name sticks: in the app, in the terminal, and on your desk if i ever move in." · chips pip (done), moss (thinking), tad (working), fern (reading), keep 'frog' · echoes "pip. i like it." / "moss. slow and thorough." / "tad. short, and quick." / "fern. quiet, always reading." / "frog it is. a classic." · "call me pip" / "skip"
**routines** · h2 "want me to do this every morning?" · "from what i saw in ledger. you can change these any time." · "overnight ci triage · ci failed on 4 of the last 20 runs. at 8:00 i read what broke and have a fix waiting." · "first pass on new prs · 11 prs opened last month. i read each one and draft notes. you decide what to send." · "dependency bumps, tests first · 6 packages are a patch behind. i bump, run the tests, and keep only what passes." · "turn on 2" / "not now" · "runs while your mac is awake · or in frog cloud, with pro"
**save** · h2 "save pip" · "sign in and pip keeps its name, its notes on ledger and its routines, here and on any other mac." · chips "name · pip", "memory · 9 notes", "2 routines" · "continue with github" · "or" · email field + "email me a link" · "no card. $5 in beta credits when you sign in." · "not now · pip stays on this mac"
**saved** · row "saved · signed in as samr via github" · "i'm saved. $5 in beta credits are on your account, and there's no card on file. open frog on another mac, or run `frog` in a terminal, and it's still me." · "two more i can do in ledger" + two buttons
**cli** · banner "frog 0.9 · free and open source · trial on frog cloud, no account needed" · "here's what i can finish right now:" · "pick 1–3, or say anything ›" · "apply? [y/n/e to edit] ›" · "✓ applied, not committed. first fix in 1:02." · "i'm frog. name me with frog name · save me with frog login"
**login** · "save pip so it keeps its name, memory and routines." · "open https://frog.toys/device and enter KXRT-4QPM" · "press enter to open the browser · waiting for you…" · "✓ signed in as samr (github)" · "✓ pip is saved" · "✓ beta credits $5.00 · no card on file" · "this terminal and the app are the same pip now." · `frog usage`
**nudges** · "missed · ci went red at 2:14 and your mac was asleep, so triage waited" → "triage it now" / "run routines while i sleep · pro" · "heads up · renaming Money → Amount touches 31 files. dart will need a few passes" + "tree, the bigger model, would likely do it in one. about 4 min instead of 12." → "stay on dart" / "leap to tree · pro" · "3 tasks queued. you run 1 at a time; pro runs 2, max runs 8" → "keep the queue" / "run 2 at once · pro"
**receipt** · h2 "last week with pip" · 41 tasks · 12 prs merged · ~6 h saved · $3.20 spent · per-routine lines · "how 'saved' is counted" · "$3.20 of $5.00 beta credits" · "turn off receipts"
**credits** · the finished task's done row and accept button come first · h2 "that one finished on the last of your beta credits" · "i didn't stop halfway. here's how to keep going." · "pro · $20 a month" / "keep going on this mac · free. qwen3-4b runs locally…" / "pay as you go · $0.60 per million tokens in, $1.50 out" · "no rush. pip, its memory and routines stay whatever you pick."
**plan** · cards beta / api / pro / max · "cancel pro · you keep pro until nov 23. pip, its memory and routines stay; cloud routines move back to your mac." · billing lives on frog.toys/billing
**desk** · h2 "pip could live on your desk" · "a small head that carries pip: same name, memory and routines. it says good morning, tells you when ci goes red, and keeps routines going when your laptop is shut." · mini $999 / full $1,499 · "meet the heads" / "not interested" · ladder free → pro → head
**unbox** · "plug it in" · "pip comes along. one usb-c cable to your mac. no setup app, no pairing code. it was yours the moment you ordered it." · 3 steps · "it's plugged in"
**greet** · head says "morning, sam. it's pip. ci went red at 2, and i have a fix waiting." · "pip moved in" · checklist: name, memory, routines, repos, voice

## 3. States

| state | frog says | actions |
|---|---|---|
| empty repo | "notes is empty · no files yet. tell me what it should be and i'll set it up, tests included." | start something (chips: a cli in rust, a next.js app, just a readme) · pick another repo |
| no git | "~/scratch isn't a git repo · i like git so every change i make can be undone. i can set it up here, one commit of what's there now." | set up git · work without it (frog keeps its own undo copies) |
| offline / local only | "offline, so i'm on this mac · running qwen3-4b locally. slower, and nothing leaves your mac." no model yet: "connect once to get one (2.4 gb), then i work offline." | keep going local; estimates are shown ×3 |
| sign-in failure | "github didn't let me in · access was denied in the browser. pip is still here, on this mac. nothing's lost." | try again · email me a link |
| magic link | "check sam@hey.com · the link opens frog and signs you in. it works for 15 minutes." expired: "that link expired. i'll send a new one." | resend (30 s cooldown) · use github |
| nothing to fix | "garden looks healthy · tests pass, docs match, deps are current." 3 generative tasks instead | tests for an untested file · explain the codebase · a ci workflow |
| credits out mid-task | screen 14: finish, then ask. we absorb the overage, capped at one task (proposed cap $0.50) | pro · local · pay as you go |

Ask rules: at most one upgrade ask per trigger kind per week; dismissing one quiets that kind for 14 days; never during a running task; never a modal.

## 4. Metrics

| metric | definition | target (proposed) |
|---|---|---|
| time to first accepted diff (TTFAD) | first app open (or first `frog` run) → first accept, p50 and p90 | p50 < 90 s, p90 < 3 min |
| first-win rate | % of installs with ≥1 accepted diff in session 1 | ≥ 60% |
| proposal hit rate | % of first runs where the user picks one of the 3 (vs typing) | ≥ 70% |
| sign-in rate after first win | % of first-win users signed in within 7 days | ≥ 45% |
| routine at D7 | % of D0 users with ≥1 enabled routine that ran on D7 | ≥ 25% |
| retention | D1 / D7 / D30 = ran ≥1 task that day (or a routine they read) | 40 / 25 / 15% |
| upgrade by trigger | conversions per trigger (missed routine, bigger model, parallel, credits out) | track, no target yet |
| cancel → return | % of cancelled pro users back within 60 days | track |

Events (opt-in telemetry in the OSS build, anonymous until sign-in): app_open, repo_picked, scan_done, proposal_shown, task_started{proposal|typed}, diff_accepted{ms_since_open}, named, routine_enabled, signin_*{method, reason}, trigger_shown{kind}, checkout_opened{plan, trigger}, subscribed, cancelled, head_paired.

## 5. Account fields (flag for the accounts schema: Better Auth + PlanetScale Postgres; Durable Objects for live credits)

- **device trial** (pre-account): `device_id`, `trial_credits_cents`, `first_open_at`, `first_accept_at`. Merges into the user at sign-in; one trial per device.
- **persona** (the frog): `persona_id`, `user_id`, `name` (default "frog", 1–24 chars), `default_mood`, `voice_id` (null until a head or voice is set), `created_at`. One per user for v1; the schema allows several.
- **memory**: `memory_item {id, persona_id, repo_key (remote url hash), kind: fact|preference|convention, text, source_session_id, created_at, last_used_at, pinned}`. Plain text and user-editable (settings › memory). Synced, end-to-end encryption to decide (Q4).
- **routines**: `routine {id, persona_id, repo_key, kind: ci_triage|pr_first_pass|dep_bump|custom, trigger: cron|github_event, schedule, prompt, runs_on: mac|cloud|head, enabled, last_run_at, last_result}`.
- **devices**: `device {id, user_id, kind: mac|cli|head, name, last_seen_at}`; heads add `serial`, `model: mini|full`, `bound_at` (bound at checkout).
- **plan + usage**: `plan: beta|api|pro|max5|max20`, `stripe_customer_id`, `period_end`, `cancel_at`, weekly rollup `{tasks, prs_merged, minutes_saved_est, spent_cents}` for the receipt.
- **onboarding**: `first_accept_ms`, `named_at`, `signin_method`, `receipts_enabled`, `head_card_dismissed`.

## 6. Open questions

1. **first-run model.** anonymous device trial on frog cloud (as mocked, fastest), or local-first with cloud opt-in (private, but download + slower, misses 90 s).
2. **beta credit amount.** mocked at $5 on sign-in; the trial before sign-in proposed at $0.50 per device.
3. **max tiers.** brief says max $200; the 2026-10-22 decision is max 5x $100 + max 20x $200. Mocked as one max card with "or max 5x at $100".
4. **memory sync.** plain server-side (simple, searchable) or end-to-end encrypted (private, no server search).
5. **'saved' estimate.** frog's estimate of hands-on minutes minus review time, shown with "~" and a how-it's-counted link; or drop the number and show tasks and prs only.

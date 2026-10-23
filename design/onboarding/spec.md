# frog first run: onboarding spec (v2, local-first)

Mockups: `index.html` (20 screens, dark and light, ← → to step, `t` flips the theme, `?s=<id>&t=light` deep-links). Captures: `shots/`. Colors and type live in CSS variables at the top of `index.html`, ready to swap for `design/system/tokens.json`.
Thesis (approved): value first, then name, then routines, then sign-in that adds, then upgrades that follow value, then the head. No tour, no streaks, no badges.
Copy rules: lowercase, short, warm, no exclamation marks, no emoji. frog speaks in the first person.

## 0. Principles (Cam, 2026-10-23)

- **frog is free and fully usable logged out, forever.** Logged out: the full agent, all tools, local models, local memory, a local frog name, local routines (while the Mac is awake), MCP.
- **Signing in adds, it never unlocks.** Signed in adds: free frog cloud credits (dart/tree at cloud speed), sync of name, memory and routines across machines, cloud routines while the laptop sleeps, head pairing, the shared fix cache, session share links, weekly receipt history.
- **The first run is local-first.** frog cloud is opt-in: a $0.50 device trial with no account, or credits after sign-in.
- **Prompts are contextual, dismissible, once per trigger.** Never degrade, nag, badge or count down the logged-out experience. Never a modal during a task.
- References: Obsidian (the app is free and local with no account; Sync and Publish are paid add-ons, offered in settings and never in the editor) and VS Code Settings Sync (off by default, one "turn on sync" entry point, sign-in only when you ask for sync, and a machine that never signs in loses nothing). We take three rules from them: the local product is complete, the account sits on a feature you just reached for, and saying no costs nothing.

## 1. Flow and the local clock

1 open → 2 scan and model in parallel → 3 three proposals → 4 run locally → 5 accept → 6 name → 7 routines → 8 sign-in sheet (optional) → 9 saved. CLI: 10 `frog` (same local first win). Cloud moment: 11 a task the Mac finds hard → 12 `frog login` (device code). Later: 13 nudges → 14 weekly receipt → 15 credits out mid-task (signed in) → 16 plan. Then 17 head card → 18 unbox → 19 greet. 20 edge states.

**How the local first win gets close to 90 s:**
1. **At app open** (before a repo is picked): look for an existing model (ollama, LM Studio, the tang cache). If none, start the download (qwen3-4b, 2.4 GB). It is resumable and cached, and closing the app doesn't lose it.
2. **Pre-scan the recent repos** in the background, read-only: manifest, `git log`, test run, README vs manifest, `npm outdated` or the language's equivalent. Most findings are heuristic (failing test names, version drift, stale commands), so they don't need the big model.
3. **A tiny proposal model.** A ~0.5B model ships inside the app (≈300 MB, no download) and writes the 3 task cards from the scan results within seconds. The big model only runs the task itself.
4. **Run the chosen task** once the big model is loaded. Estimates on the cards are local ones ("~90 s on this mac").
5. **Show progress honestly**: one download row (percent, MB/s, time left, "resumes if you close the app"), and both clocks in the copy.

| path | open → proposals | proposals → accept | **first accepted diff (p50)** |
|---|---|---|---|
| model already on the mac (ollama / LM Studio / tang cache, or a re-install) | ~0:20 | ~0:50 | **1:12** |
| fresh download, 2.4 GB at ~18 MB/s | ~0:38 (tiny model, during the download) | ~2:25 (wait for the model, then run) | **3:05** |
| opt-in frog cloud trial (dart) | ~0:20 | ~0:30 | 0:55 |

The 90 s target holds for the existing-model path. A fresh download takes about 3 minutes, and the app says so instead of hiding it. The scan is capped at 20 s. Task 1 has to be finishable locally in under 2 minutes, otherwise it ranks lower.

## 2. Copy by screen

**open** · h1 "what shall we fix?" · sub "pick a repo. i'll read it and suggest three things i can finish right now." · model line "borrowing your mac's brain for ideas · full model, 2.4 gb, in the background" (existing model: "using qwen3-4b from ollama") · footer "everything runs on this mac, free and private. no account, ever, unless you want one. already have a local model?" · second line "in a hurry? frog cloud does the first fix in seconds · $0.50 trial, still no account"
**scan + model** · "reading ledger" + tool rows · "just reading and running your tests. nothing changes until you say so." · "waking my brain up, first run only · 2.4 gb" · bar "71% · 18 mb/s · 40 s left · resumes if you close the app" · chip "auto · local", "on this mac"
**propose** · "here's what i can finish right now. pick one." · cards with evidence, files and "~90 s on this mac · your tests will check it" · "fix it" / "update it" / "bump it"
**run** · "on it" · the cause in one sentence · composer "steer me, or press esc to stop…"
**diff** · "done · both tests pass · nothing else in auth/ moved" · "fixed. here's the change. nothing is applied until you accept." · "discard" / "change something…" / "accept ⌘↩"
**name** · "✓ accepted · applied to your working tree, not committed · first fix · 3:05 fresh · 1:12 warm" · "nice one. want to name me?" · pip / moss / tad / fern / keep 'frog', each with a mood · "call me pip" / "skip" (the name is stored locally; sync adds it everywhere)
**routines** · "want me to do this every morning?" · ci triage / first pass on new prs / dependency bumps, each with its evidence · "turn on 2" / "not now" · "runs while your mac is awake · sign in and it runs in frog cloud while you sleep"
**sign in** · "save pip" · "sign in and pip comes with you: its name, its notes on ledger and its routines, on any mac. nothing here changes if you don't." · "signing in adds: fast cloud speed, routines while your mac sleeps, pip on every device, head pairing, the shared fix cache. it never takes anything away." · "continue with github" / email + "email me a link" · "no card. $5 in cloud credits when you sign in." · "not now · everything keeps working on this mac"
**saved** · "saved · signed in as samr via github" · "i'm saved. i still run on this mac by default; $5 in cloud credits are there for the hard ones, and there's no card on file…"
**cli** · "frog 0.9 · free and open source · runs on this mac, no account needed" · "warming up qwen3-4b… 82% · 36 s · resumes if you close the terminal" · numbered tasks with local estimates · "✓ applied, not committed. first fix in 2:51. (1:04 once i'm warm)" · "name me with frog name · save me with frog login"
**hard task (main cloud moment)** · "first pass done · 31 files touched, 3 tests still red" · "this one's big, and my small brain keeps missing corner cases" · "two more passes here, about 6 minutes. dart on frog cloud does most of this in one, about 40 seconds. sign in and your first $0.50 of cloud work is free. no card, no account unless you want one." · "try dart free · sign in" / "$0.50 trial, no account" / "keep going local"
**frog login** · device code `KXRT-4QPM` at frog.toys/device · "✓ pip is saved" · "✓ cloud credits $5.00 for hard tasks · local stays the default · no card"
**nudges** · missed routine (mac asleep), bigger model (tree), parallel queue. Each has a free action next to the paid one.
**receipt** · 41 tasks · 12 prs merged · ~6 h saved · $3.20 spent · "29 tasks ran locally, free". Logged out it's computed locally; signing in keeps the history.
**credits out (signed in)** · "that one finished on the last of your cloud credits" · "i didn't stop halfway. from here i'm back on this mac, free, unless you pick otherwise." · pro $20 / "stay on this mac · ✓ on" / pay as you go
**plan** · free ("the full agent, local models · local memory and routines · signed in: $5 cloud credits, sync · forever, no account needed") / api / pro $20 / max $200 (or 5x $100) · one-button cancel
**head** · "pip could live on your desk" (mini $999, full $1,499; pairing needs sign-in) · "plug it in" · "morning, sam. it's pip. ci went red at 2, and i have a fix waiting."

## 3. States

| state | frog says | actions |
|---|---|---|
| model: already on the mac | "using qwen3-4b from ollama." no download row | straight to proposals (~0:20) |
| model: downloading | "qwen3-4b, 2.4 gb, one time · the scan runs while it downloads, so the ideas don't wait. 71% · 18 mb/s · 40 s left. it resumes if you close the app." | read the repo while we wait |
| download failed or paused | "the download paused at 64%. i'll pick it up when you're back online." the tiny model still proposes | resume · $0.50 cloud trial |
| empty repo | "notes is empty · tell me what it should be and i'll set it up, tests included." | start something · pick another repo |
| no git | "~/scratch isn't a git repo · i can set it up here, one commit of what's there now." | set up git · work without it |
| sign-in failure | "github didn't let me in · pip is still here, on this mac. nothing's lost." | try again · email me a link |
| magic link | "check sam@hey.com · works for 15 minutes." expired: "that link expired. i'll send a new one." | resend (30 s) · use github |
| nothing to fix | "garden looks healthy." 3 generative tasks instead | tests for an untested file · explain · a ci workflow |
| credits out mid-task | screen 15: finish (we absorb up to $0.50), drop back to local, then ask | pro · stay local (on) · pay as you go |

**Sign-in moments** (the only places frog asks, each once per trigger, dismiss = 14 days quiet): (1) the local model struggling on a hard task, which is the main one; (2) turning on a routine ("runs while you sleep"); (3) opening frog on a second device ("pip is on your other mac, sign in to bring it here"); (4) pairing a head; (5) the weekly receipt ("keep this history"). Never during a running task, never as a modal, never at app open.

## 4. Metrics

| metric | definition | target (proposed) |
|---|---|---|
| TTFAD, existing model | first open → first accept when a model was already on the mac (p50/p90) | p50 ≤ 90 s, p90 ≤ 3 min |
| TTFAD, fresh download | same, model downloaded on first run; also split by download speed | p50 ≤ 3:15, p90 ≤ 6 min |
| TTFAD, cloud trial | same, user opted into the $0.50 trial | p50 ≤ 60 s |
| first-win rate | % of installs with ≥1 accepted diff in session 1, per path | ≥ 60% |
| download completion | % of started downloads that finish within the first session | ≥ 85% |
| proposal hit rate | % of first runs where the user picks one of the 3 | ≥ 70% |
| logged-out D7 / D30 | retention of users who never signed in, which shows the free product is whole | 25 / 12% |
| sign-in rate after first win | % signed in within 7 days, and broken down by moment (hard task, routine, 2nd device, head, receipt) | ≥ 35% |
| routine at D7 | % of D0 users with ≥1 routine that ran on D7 (local or cloud) | ≥ 25% |
| retention | D1 / D7 / D30, all users | 40 / 25 / 15% |
| upgrade by trigger | conversions per trigger | track |

Events (opt-in telemetry in the OSS build, anonymous until sign-in): app_open, model_detected{source}, download_started/progress/done{ms}, scan_done, proposal_shown, task_started{proposal|typed, local|cloud}, diff_accepted{ms_since_open, path}, named, routine_enabled, signin_prompt{moment}, signin_done{method, moment}, trial_started, trigger_shown{kind}, checkout_opened, cancelled, head_paired.

## 5. Account fields (flag for the accounts schema: Better Auth + PlanetScale Postgres; Durable Objects for live credits)

Local-first means each of these exists **on the Mac first** (local store) and syncs when signed in. The schema has to accept a local-origin record with its own id.
- **device trial** (opt-in, no account): `device_id`, `trial_credits_cents` (50), `started_at`. Merges into the user at sign-in; one per device.
- **persona**: `persona_id`, `user_id` (null locally), `name`, `default_mood`, `voice_id`, `created_at`, `origin_device_id`.
- **memory**: `memory_item {id, persona_id, repo_key, kind, text, source_session_id, created_at, last_used_at, pinned}`. Local and editable; synced when signed in.
- **routines**: `routine {id, persona_id, repo_key, kind, trigger, schedule, prompt, runs_on: mac|cloud|head, enabled, last_run_at, last_result}`. `cloud` requires sign-in.
- **devices**: `device {id, user_id, kind: mac|cli|head, name, last_seen_at}`; heads add `serial`, `model`, `bound_at`.
- **plan + usage**: `plan: free|api|pro|max5|max20`, `cloud_credits_cents`, `stripe_customer_id`, `period_end`, `cancel_at`, weekly rollup `{tasks, local_tasks, prs_merged, minutes_saved_est, spent_cents}`.
- **onboarding**: `first_accept_ms`, `first_accept_path: existing|download|cloud`, `model_source`, `named_at`, `signin_moment`, `receipts_enabled`, `head_card_dismissed`.

## 6. Decisions

Chosen by Cam (2026-10-23):
1. **first-run model: local-first.** frog cloud is opt-in, not the default. The first win runs on the Mac.
2. **anonymous cloud trial: yes, opt-in.** $0.50 per device, no sign-in, device-bound, offered at open ("in a hurry?") and at the hard-task moment. The alternative was cloud only after sign-in.
3. **cloud credits on sign-in: $5**, no card.
4. **max: one card** showing max $200 with "or max 5x at $100".
5. **memory sync: plain server-side for v1** (E2E later).
6. **receipt keeps "~6 h saved"** with a "how 'saved' is counted" link.

7. **the tiny proposal model ships in the app bundle** (Cam, 2026-10-23): about 300 MB more on install, and the 3 cards come out in seconds during the model download, instead of heuristic-only cards that stay vague until the big model lands.
8. **default local model: qwen3-4b** (Cam, 2026-10-23): 2.4 GB, first diff ~3:05 fresh. A larger coder model can be offered after the first win.

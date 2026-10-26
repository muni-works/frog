# Beat 1 runbook: Oct 30, 2026

What ships: frog (free, open agent) on muni-works/frog, tang on muni-works/tang with the
kernel-verify harness, frog cloud (accounts + Qwen3-Coder-Next 24/7, plans live), the post
([beat1.md](beat1.md)) and the bench page ([bench.md](bench.md)).

**Post time: Fri Oct 30, 09:00 EDT (13:00Z).** DST ends Nov 1, so it's still EDT. A Friday is a
weaker HN day than Tue-Thu. The date is fixed, so post early to get the US morning.

Roles: **Cam** (clicks, HN account, final go), **chief** (coordination, relays), **release** (this
doc, post, bench page, go/no-go), **frog mgr** (repo, release, install), **zest mgr** (frog cloud),
**tang mgr** (tang repo, CI, tree numbers).

## Cam's clicks (with the latest safe time)

| # | click | by | unblocks |
|---|---|---|---|
| C1 | **GitHub Billing & plans on the ecto account**: fix the failed payment or raise the spending limit | **DONE Oct 26 (Cam)** — CI re-running | all CI, DCO, the site deploy, releases (audit headline 1) |
| C2 | **Transfer ecto/tang → muni-works** | **DONE Oct 26 (Cam)** — public, 2110f3ba, old URL redirects | `frog setup`, the tang-llm release, post links |
| C3 | GitHub App "Where can this app be installed: **Any account**" (client `Iv23li…`) and register callback `https://api.frog.toys/auth/github/callback` | Oct 28 | GitHub sign-in for people outside muni. Test with a non-org account |
| C4 | ~~Copyright line~~ decided: "© 2026 Municipal Robotics" (already in Info.plist/project.yml). Remaining: commit email for the export | Oct 28 | scrub PR, post copy |
| C5 | **Stripe live keys** into the edge (zest does the deploy, Cam pastes the keys) | Oct 29 | paid plans at launch |
| C5b | **`npx wrangler login` from ~/Developer/zest/edge** — the edge deploy is blocked on an expired OAuth (frog cloud mgr, PR #73 merged but undeployed) | **by Oct 28** | the /pricing, /status, /beta copy going live |
| C6 | **Flip muni-works/frog to public** after go/no-go G1-G6 | Oct 29 PM | everything public |
| C7 | Submit Show HN + first comment from Cam's account. Post on X | Oct 30 09:00 | launch |
| C8 | Apple org enrollment (continuing; does not gate) | — | signed builds later |
| C9 | **Publish the draft tang-llm release** on muni-works/tang (asset built locally, staged as draft) | Oct 28 | `frog setup`'s prebuilt path |
| opt | Novita key for a same-day h2h | Oct 28 | the bench page's §3 (else "not yet run") |

## T-minus

### T-4: Mon Oct 26 (today)
- release: audit refresh, post, bench, migration and runbook drafts (this commit).
- chief: route C1-C4 to Cam as buttons. Route the fix lists: frog (scrub PR, release.yml, install.sh), zest (`/beta` `/pricing` `/status` copy, snippets on `/docs`), tang (CI fmt + clippy).

### T-3: Tue Oct 27
- Cam: C1, C2.
- frog: **scrub PR** (migration §1) + **release fix PR** (migration §6). Re-run the full suite on main once billing works. Two days of bypass merges need a real CI run.
- tang: CI green on main. Tag `v0.1.0` → mac-release.yml → unsigned `tang-llm-aarch64-apple-darwin.tar.gz`. Verify the `releases/latest/download` URL (migration §5).
- zest: copy fixes live (needs C5b wrangler login). Agent snippets on `/docs`. Signup throttles confirmed live: 3/hr magic-link per email, 10/hr per IP. Kill switch (verified, zest): KV `config:hours_override` = "closed" via `POST /internal/admin/hours` → all completions 503 within seconds; signups aren't separately killable, but closing hours stops new usage entirely.
- release: fill bench §1 placeholders from the latest zest run. Draft X thread + HN first-comment variants. Max output tokens confirmed by zest: 16384 (pro/max5/max/internal); the edge router clamps silently for lower tiers (value/api 8192, beta 4096) — the README's opencode limit block states the max-tier number.

### T-2: Wed Oct 28
- frog: tag `v0.1.0-rc1` on **ecto/frog** (or a dry-run export pushed to private muni-works/frog). All release jobs green, assets complete. **Depends on frog/release-build-fix** (main's Release build fails on PillChurn, a DEBUG-only symbol — the rc needs that merged).
- release: install matrix (migration §6 test sequence) via the public scratch repo. Clean-Mac first run: `frog` → default local model → `frog setup` pulls tang-llm.
- zest: 2nd H200 node up 24/7 (approved). Load test at 2× expected launch concurrency. Kill switch rehearsed (set `hours_override` closed, verify 503, reset).
- Cam: C3, C4, C5b, C9. Optional Novita key.
- frog: Homebrew tap decision executed (migration §8 B) or explicitly deferred.

### T-1: Thu Oct 29
- 09:00 code freeze on ecto/frog main. Scrub gates pass on the frozen sha. **The branch merge to main is itself a production site deploy** (site.yml fires on site/** changes): hold it until the copy fixes and site/install.sh are in, then merge deliberately.
- frog/release: export (migration §3) → push to private muni-works/frog → secrets + ruleset (§4) → CI green there.
- zest: re-run the Coder-Next bench on the deployed build → bench §1. Prod 24 h export.
- tang: latest tree row (ids n/n + tok/s) → bench §4. If nothing new is merged and verified, the naive row stands.
- release: read the AA page and date it. Fill every `{{…}}` in the post or cut the sentence. Run each agent snippet end-to-end against the live endpoint (opencode, Cline, Continue, Aider, Zed, frog itself).
- Cam: C5 (Stripe live). zest verifies one real $20 charge + refund.
- **17:00 go/no-go (below).** On GO: Cam C6 (public), then frog tags `v0.1.0` on muni-works/frog, then release runs the install matrix against the real repo, then site.yml deploys frog.toys (site, install.sh, bench page, post).
- Archive ecto/frog. Move worktree remotes (migration §4).

### T-0: Fri Oct 30
| time (EDT) | what | who |
|---|---|---|
| 07:00 | Final probes (the G-list commands below), status page green, both nodes up | release, zest |
| 07:30 | Fresh-Mac install from frog.toys one last time | release |
| 08:30 | Last go/no-go. Cam reads the post once | Cam, release |
| 09:00 | **Show HN** + first comment. X thread. | Cam |
| 09:00-13:00 | Watch: HN comments, GitHub issues, `/status`, Grafana (TTFT, 5xx, streams), signups/min. Agents draft replies, and Cam posts them. Every reported bug gets an issue with a link back | all |
| 10:00, 12:00, 15:00 | Roll-up to Cam: signups, installs (release download counts), 5xx %, top 3 issues | chief |
| 17:00 | Day-1 summary. Bench page changelog entry | release |

## Go/no-go: all green before the post goes up

| # | gate | check |
|---|---|---|
| G1 | export is clean | migration §3 grep gates + gitleaks = 0 findings. File count matches |
| G2 | CI green on muni-works/frog main and muni-works/tang main | `gh run list -R muni-works/frog -b main -L 1`, same for tang |
| G3 | install works from frog.toys | `curl -fsSL https://frog.toys/install.sh \| sh` on clean macOS arm64 + Ubuntu x86_64; `sha256` of the served script == `scripts/install.sh` at the tag |
| G4 | first run works | clean Mac: `frog` → local model answers (tang-llm prebuilt fetched from the **published** draft release, checksum ok). `-m cloud/qwen3-coder-next` answers with a fresh account's key |
| G5 | frog cloud is ready | `/status?format=json` → `serving:true`, 2 nodes. Sign-in with GitHub (non-org account) + email link works. `/pricing` has no "coming soon". `/beta` points at `/auth`. A Stripe live charge succeeded. Kill switch rehearsed (T-2) |
| G6 | every number in the post has a receipt | each `{{…}}` filled from bench.md with date + log link, or cut. No "#1"/"fastest" |
| G7 | links resolve | every URL in beat1.md returns 200 (repo, tang demo script, kernel-verify.md, /docs, /status, frog.toys/bench) |

Any red G1-G5 → **NO-GO for the post**. Slip the post (to Mon Nov 2, 09:00 EST) rather than ship a broken install.
A red G6/G7 gets fixed by editing the post, not by slipping.

## Rollback

| what broke | do this | who |
|---|---|---|
| install.sh / release asset bad | Repoint `frog.toys/install.sh` to the last good tag (`FROG_VERSION` default pinned in the served script), mark the bad release as a prerelease (drops it from `latest`), ship `v0.1.1`. Post a comment on HN saying what broke | frog, release |
| tang-llm asset bad | `gh release edit` on tang to mark it a prerelease (setup.rs falls back to `cargo install --git`), re-tag | tang |
| frog cloud overloaded | 503 → frog falls back to local (already the behavior). Pause new signups (kill switch: `POST /internal/admin/hours` sets KV `config:hours_override` = "closed" → all completions 503 within seconds; note signups aren't separately killable, but throttles of 3/hr magic-link per email and 10/hr per IP are live), keep existing keys. Add a node if a GPU host has stock. Status page says what's happening | zest |
| Stripe live misbehaves | flip plans back to "coming soon" on `/pricing`, refund, and keep the API on starting credits | zest, Cam |
| secret or private data found in the public repo | **Cam flips muni-works/frog private immediately**, rotate the credential, re-export from a scrubbed sha, re-flip. Say so publicly if it was a credential | Cam, frog |
| security report (SECURITY.md) | ack within 2 h, fix on a private branch, release, then disclose | frog, Cam |
| post has a wrong number | edit the post with a visible "corrected:" line + a bench changelog entry. Don't silently change it | release |

## After launch (Oct 31 →)
- Beat 2 (Nov 3: cram + the H200 result) reuses this runbook.
- Post-launch backlog from the audit: Aider/Zed snippets if not done, homebrew-core, models.dev + LiteLLM submissions (need the published bench), signing once Apple clears, the egress allow-list (the post promises it, so it needs a date-free "shipped" note when it lands), the loon/kosm/muni license fix.

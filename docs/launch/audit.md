# Beat 1 readiness audit, refreshed (2026-10-26, T-4 days)

Re-verification of the Oct-22 audit (`~/Developer/chief/memory/beat1-readiness.md`), item by item.
Evidence is from this worktree (main 9478753), `gh` against ecto/frog, ecto/tang and muni-works,
and live `curl`/`dig` probes taken 2026-10-26 ~18:30Z. Read-only. Nothing was pushed or changed.

Status key: **DONE** = verified fixed. **STILL-OPEN** = still a gap (with the current shape).
**NEW** = not in the Oct-22 audit. **N-A** = no longer applies, or not mine to verify (owner named).

## The headline changes since Oct 22

1. **CI is red for a billing reason, not a test reason.** Every ecto/frog run on main fails in 2 to 8 s
   with "The job was not started because recent account payments have failed or your spending
   limit needs to be increased" (run 40375001059 and every run back to at least 2026-10-25 21:20Z;
   the last green ci.yml run was 2026-10-24 13:36Z). This blocks CI, the DCO
   check, the site deploy (site.yml) and any release (release.yml). It's a Cam click
   (GitHub → Billing & plans). ecto/tang is public, so its runs do execute. They fail for real:
   rustfmt and clippy (run 40375040355).
2. **frog.toys resolves now**, but it serves a 112-byte placeholder for every path. That includes
   `/appcast.xml` and `/signup`. `/install.sh` is an *older* script (3,883 B, pre-#43, vs 5,016 B in
   the repo). The real `site/` has never deployed because site.yml can't run (see 1).
3. **`muni-works/tang` does not exist.** `setup.rs:15,22` now point at it, for both the prebuilt
   download and the `cargo install --git` fallback, so `frog setup` has no working path. tang lives at
   ecto/tang (public, zero releases).
4. **release.yml would fail on its first run** for three independent reasons (details under Install
   path). install.sh's new macOS app branch installs a broken wrapper.
5. **frog cloud accounts are live.** `/auth` (magic link + GitHub OAuth) works, and
   `/docs /pricing /privacy /terms` all return 200. The copy hasn't caught up: the README and `/beta`
   still say invite-only, `/pricing` says "Plans coming soon", and `/status` says "hours: by announcement".

## 1) frog repo

| Item | Status | Evidence now |
|---|---|---|
| LICENSE-MIT + LICENSE-APACHE | **DONE** | both at repo root on main; README "License" section; `vendor/reedline/LICENSE` kept |
| DCO | **DONE in code / STILL-OPEN in practice** | `.github/workflows/dco.yml` (on pull_request, checks every non-merge commit for `Signed-off-by:`), and the main ruleset requires `check-dco`. It can't run while Actions billing is failing. The fresh single commit must itself be `-s` (288 of 725 private commits have a sign-off, which stops mattering after the squash) |
| SECURITY.md | **DONE** | present |
| Secrets scan | **DONE, clean** | re-grepped `sk-…`, `ghp_…`, `AKIA…`, `frog_…`: only fixtures (memory.rs:1074-1077, irc.rs:571, the AWS docs example key). No tracked .env/.pem/.p12/.mobileprovision |
| Internal hostnames | **mostly DONE, STILL-OPEN (small)** | `pedersen.garden`: 1 left (apps/ios/Shared/House.swift:9, a comment). `mew`: 1 left (docs/research/tang-architecture.md:79). LAN IPs that remain are SSRF/private-range test cases (web.rs:691,743; auto.rs:906; policy.rs:165), which are fine. openai.rs:446 `192.168.2.12:8420` is a real home tang host: change it to TEST-NET `192.0.2.x` |
| NEW: home paths | **STILL-OPEN** | 24 files contain `/Users/cam` or `~/Developer` (Swift tests, engine tests in config.rs/shell.rs/bash.rs/approval.rs/auto.rs, docs/design/*, docs/interp/*). Cosmetic, but it tells readers "one person's machine". Scrub them in fixtures; docs can stay |
| `ecto/` references | **STILL-OPEN, smaller** | README, web.rs User-Agent and setup.rs are fixed. 13 files remain: functional = `apps/macos/scripts/release.sh:24` (`REPO=${FROG_RELEASE_REPO:-ecto/frog}`); fixtures = GitBadgeTests, SidebarSnapshotTests, pond.rs:446, puck/demo.rs:81, PondBrief.swift:186; docs = docs/site-deploy.md:21, docs/design/{auto-mode-skittish, chief-sandbox-profile, pr-lifecycle, sidebar-git/*}. Full list in migration.md |
| `frog.eco` vs `frog.toys` | **STILL-OPEN, functional** | frog.eco doesn't resolve. Functional uses: Sparkle `SUFeedURL` (Info.plist:44, project.yml:46), so **app auto-update is dead**; push relay default (RemotePush.swift:26); energy links (EnergySettings.swift:77, TurnCosts.swift:111); site/index.html:10 og:image and :763 mobile copy; site/energy footer |
| Personal refs | **decide (Cam)** | `© 2026 Cam Pedersen` in Info.plist:32 and project.yml:52 (vs "Municipal Robotics"?). site/index.html:666 "Made by Cam Pedersen" is fine. The `com.campedersen.*` ids in FrogApp.swift:310-314 are migration code: keep. The accounts-ux mockups use `@campedersen · cam@muni.works` as sample data: fine |
| `.claude/launch.json` tracked | **DONE** | `git ls-files` has no `.claude/` |
| Fresh single-commit plan | **STILL-OPEN (plan written)** | muni-works/frog is still private and empty (`isEmpty: true`). Plan: [migration.md](migration.md). `git archive` with `:(exclude)` pathspecs tested on git 2.54 |
| README accuracy | **partly DONE** | Cline context is now 131072 (README:70): **DONE**. "free, invite-only beta" + "get one at api.frog.toys/beta" (README:47,50,59-60) no longer matches the live `/auth` sign-in: **STILL-OPEN**. opencode snippet still has no `limit` block: **STILL-OPEN**. The install line works only once a release exists |
| Install path | **STILL-OPEN, now with known bugs** | No release on ecto/frog, muni-works/frog or ecto/tang (`gh release list` empty). release.yml has never run. See "release.yml / install.sh defects" below |
| Homebrew | **STILL-OPEN** | `muni-works/homebrew-tap` doesn't exist; no formula anywhere. Decision in migration.md |
| tang-llm prebuilt | **STILL-OPEN, worse** | ecto/tang has zero releases. setup.rs targets `muni-works/tang`, which doesn't exist (`gh repo view`: could not resolve), so both the download and the git fallback fail. tang main CI is red (rustfmt + clippy unused vars) |
| Linux | **N-A to verify** | CI can't run (billing), so there's no signal either way. GTK app is still a draft (#31) |
| macOS app signing | **STILL-OPEN** | Apple org enrollment pending. release.yml builds ad-hoc (`CODE_SIGN_IDENTITY=-`) |
| CI on main | **STILL-OPEN, new cause** | billing, above. The last green ci.yml runs were 2026-10-24 13:36Z (e.g. 40098903391). Every run in the last 60, back to at least 2026-10-25 21:20Z, is "job was not started… payments". The ruleset requires check/ubuntu, check/macos-14, macos-app and check-dco, so every merge since then has gone through the admin bypass. Two days of merges are untested: re-run the suite the moment billing clears |
| NEW: iOS/watch build | **STILL-OPEN (unverified)** | docs/ios recommendation (merged) says iOS and watch builds have been broken since 94fd341 (FrogFace.swift:34) and no CI builds them. A public repo with a non-building target is a bad first issue |
| Open PRs | info | #99-#102 (design/research, not drafts), drafts #31 Linux, #36 pond, #56 IRC bus. None blocks launch |

### release.yml / install.sh defects (found reading the code; nothing has run)

1. **macOS job fails at build.** release.yml:77 sets `FROG_REQUIRE_TANG=1`, but the job never
   checks out tang, so `apps/macos/scripts/build-engine.sh:44` exits 1 ("a release must ship tang-llm").
   release.yml also runs `xcodegen` without installing it (ci.yml:52 does `brew install xcodegen`).
2. **macOS packaging fails.** `Frog.zip` is copied to `dist/$name/`, but `sha256sum "Frog.zip"`
   runs in `dist/`, so the file isn't there. `sha256sum` without the `shasum` fallback may also be missing on macos-14.
3. **One failed target means no release.** The `release` job `needs: build`, so (1) or (2) means
   nothing is published, Linux included.
4. **install.sh's app branch is broken.** If `Frog.zip` is at the release root, it unzips into
   `$tmp`, which the EXIT trap deletes, then writes `~/.local/bin/frog` as `open -a "$(dirname "$0")/../Resources/frog"`.
   That path is `~/.local/Resources/frog`, which doesn't exist. Every Mac user would get a dead
   `frog`. It also skips `need unzip`, calls `curl` directly (ignoring the wget path), and `cd -` prints to stdout.
5. **Prereleases are never found.** `resolve_version` reads `releases/latest`, which excludes
   prereleases, despite the comment. An `-rc` test needs `FROG_VERSION=` set, and launch must be a non-rc tag.
6. **A private repo returns 404.** `releases/latest` is unauthenticated, so install.sh can't be
   tested against muni-works/frog until it's public (or use a public scratch repo, see migration.md).
7. **The served script is stale.** frog.toys/install.sh is the pre-#43 version.

## 2) frog cloud

| Item | Status | Evidence now |
|---|---|---|
| Edge, keys, tiers | **DONE** | carried; `/v1/models` → 401 without a key (correct) |
| Signup/auth | **DONE** | `/auth` 200 ("email me a link" / "sign in with GitHub"); `/auth/github` → 302 to github.com with client id `Iv23li…`; `/account` and `/billing` → 302 `/auth?next=…`. One-time signup credit per chief (zest accounts E2); I didn't sign up to verify the amount |
| Free capped beta (public) | **STILL-OPEN (copy)** | `/beta` still says "Enter your invite code… Join the waitlist". Two front doors with different stories. Point `/beta` at `/auth` or retire it |
| Abuse limits | **N-A to verify (zest)** | not re-probed. Ask zest: signup throttle per IP/email, credit per verified account |
| Plans + Stripe | **DONE (sandbox) / STILL-OPEN (live)** | Stripe sandbox verified per chief; live keys are a Cam click. `/pricing` still says "Plans coming soon." and lists Pro $20 / Max 5x $100 / Max 20x $200 |
| Pricing | **DONE** | `/pricing` = $0.60 fresh in / $0.06 cached / $1.50 out, matching zest docs/pricing.md. (The org memory's "$0.20/M in" is stale; the post uses $0.60) |
| Status page | **DONE (up) / STILL-OPEN (copy)** | `/status?format=json` = `{"serving":true,"open":true,"node":"up","next_window":null,"hours":"by announcement"}`. Launch is 24/7, so "by announcement" must go |
| Docs page | **DONE** | `/docs` 200 with the quickstart and Python/JS snippets. Missing: opencode/Cline/Continue/Aider/Zed snippets (only in the README) |
| Monitoring | **N-A to verify (zest)** | carried |
| Capacity | **STILL-OPEN** | Cam approved a 2nd node 24/7 for launch week, starting ~Oct 28 (chief open-items). One node until then |

## 3) tang claims

| Item | Status | Evidence now |
|---|---|---|
| Post draft | **DONE (draft)** | [beat1.md](beat1.md). The angle changed: kernel-verify is the hero, not "#1 speed" |
| NEW: kernel-verify harness | **DONE** | ecto/tang main 2110f3ba: `crates/tang-verify` (attribute/device/layout/spec/stat/verifier), `docs/kernel-verify.md` with a captured H200 transcript, `scripts/kernel-verify-demo.sh` (plant, build both, run, `--replay`). This is the receipt |
| NEW: tree (GLM-5.3-Flash) correctness | **DONE** | all-GPU B300: greedy ids `785 1196 6801 264 6386 38038 911 279` == CPU oracle, 8/8; 4 bugs fixed (cc578187, 74192590, 324e7f6b, teardown). Naive speed 0.52 tok/s decode. Source: tang NOTES + chief open-items |
| "#1 speed" claim | **STILL-OPEN, recommend dropping** | zest docs/bench/frog-api-vs-novita.md is still "DRAFT, not for publication" (ff9bf12). 245 tok/s still appears nowhere in it (tops out at 234.4 engine / 224.7 API). No same-day h2h vs Novita, no AA listing. bench.md says what we will and won't claim |
| FA2 prefill | **N-A to verify (zest)** | carried |
| tang CI | **NEW, STILL-OPEN** | public repo, main red: `cargo fmt --check` diffs + clippy `unused variable l/block`, `unneeded mut`. A visitor to the engine we're bragging about sees a red badge |

## 4) Launch assets

| Item | Status | Evidence now |
|---|---|---|
| Reel | **STILL-OPEN (not re-verified)** | still worktree-only; soundtrack rights unconfirmed. Optional for Beat 1: the demo transcript is the visual |
| frog.toys website | **STILL-OPEN, changed** | DNS **DONE** (A 172.67.153.95 / 104.21.88.209, Cloudflare NS). The content is a placeholder `<pre>curl … \| sh</pre>` on every path. The real site is blocked on Actions billing (site.yml → Pages project `frog-site`) |
| frog.eco | **N-A (retire)** | doesn't resolve. Move every functional reference to frog.toys rather than reviving it |
| Distribution (models.dev, LiteLLM) | **N-A to verify (Cam)** | carried; needs a published bench number. Post-launch is fine |

## 5) Agent snippets

| Item | Status | Evidence now |
|---|---|---|
| Cline context 32768 | **DONE** | README:70 says 131072 |
| opencode `limit` | **STILL-OPEN** | README:65 has no `"limit":{"context":131072,"output":…}` |
| Aider, Zed | **STILL-OPEN** | not in the README or on /docs |
| Snippets on /docs | **STILL-OPEN** | /docs has only Python and JS |
| End-to-end verified | **STILL-OPEN** | no record. Runbook T-1 runs each one against the live endpoint |

## 6) Apple signing

| Item | Status | Evidence now |
|---|---|---|
| Developer ID + notary | **STILL-OPEN (Cam)** | enrollment pending |
| Unsigned fallback docs | **STILL-OPEN** | install.sh clears quarantine and ad-hoc signs (install.sh:131-134). The README has no bypass text for a browser-downloaded app. migration.md has the copy |
| tang-llm Apple Silicon binary (was due Oct 26) | **STILL-OPEN, MISSED** | no tag, no run, no asset, and its target repo doesn't exist. Plan: unsigned asset from a tag on tang (migration.md §6) |

## Blockers, in order (each one gates the post)

1. Cam: fix GitHub Actions billing on the ecto account. It unblocks CI, DCO, the site deploy and releases.
2. frog: fix release.yml (tang checkout + xcodegen + Frog.zip path) and install.sh (drop or fix the app branch), then cut a test tag.
3. tang location: transfer ecto/tang → muni-works/tang (Cam; keeps stars and redirects), or point setup.rs back at ecto/tang. Then a tang-llm release asset.
4. frog: scrub PR (frog.eco → frog.toys incl. Sparkle, release.sh repo, ecto fixtures, TEST-NET IP, home paths, README beta copy).
5. zest: copy fixes on `/beta`, `/pricing`, `/status`; 2nd node up; agent snippets on `/docs`.
6. tang: CI green on main (fmt + clippy) before the post links to it.

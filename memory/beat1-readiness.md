---
name: beat1-readiness
description: Read-only audit of Beat 1 launch readiness (Oct 30, 2026), taken 2026-10-22 (T-8 days)
metadata:
  type: project
---

# Beat 1 readiness audit (2026-10-22, 8 days out)

Read-only. Nothing posted, pushed, or changed. Evidence is file paths, git, gh, and live curl probes.
Caveat: I could not see the release manager session's own workspace (local_45a4ae2f), so "no draft found" means none on disk in the repos below.

Important context: frog work lives at **ecto/frog** (private; origin/main = 97a0fd5, 408 commits). **muni-works/frog** exists but is empty (private, no default branch). The checkout at ~/Developer/frog is on a stale branch (`ui-models-onboarding`, Sep 29, no LICENSE files). I audited `origin/main`, not the working tree.

## Checklist

### 1) frog repo
| Item | Status | Evidence | Owner |
|---|---|---|---|
| LICENSE-MIT + LICENSE-APACHE | done (on main) | origin/main has both (Oct 21); the local checkout lacks them | frog |
| DCO | in progress | CONTRIBUTING.md explains `git commit -s`, but there is no DCO bot or check in .github/workflows (only ci.yml, release.yml). A fresh single commit also needs a Signed-off-by | frog |
| SECURITY.md | done | present on main | frog |
| Secrets scan | done, clean | no live keys; only fake fixtures in crates/frog-engine/src/memory.rs:1072-1080 (test strings) | frog |
| Internal URLs / hostnames | **missing (must scrub)** | docs/ios-siri.md has `frog.pedersen.garden` and `mcp.pedersen.garden` (lines 15, 83, 92, 102, 106) and the home-server setup. `mew` appears in docs/ROADMAP.md, docs/ios-siri.md, docs/plans/2026-10-04-frog-node-design.md, docs/plans/2026-10-05-tang-image-generation.md, docs/research/tang-architecture.md, and the Swift tests ModelStatsTests, SnapshotTests, ModelSectionsTests, ModelIdentity.swift. Test fixtures use a LAN IP (openai.rs:418 `192.168.2.12:8420`, policy.rs) and a `mew:8000` name | frog |
| Org/URL references | missing | 13 files point at `ecto/frog` or `ecto/tang`: README, setup.rs:15,23, web.rs:30 (User-Agent), pond.rs:432, release.sh, site/vercel.json. Must become muni-works. release.sh and vercel.json also use `frog.eco`, but the product domain is frog.toys | frog |
| Personal refs | decide | site/index.html:666 "Made by Cam Pedersen" (probably fine); FrogApp.swift:291 `com.campedersen.frog` legacy bundle id; .claude/launch.json is tracked (drop it) | frog / Cam |
| Fresh single-commit plan | missing | muni-works/frog is empty; no squash/export script found. `.claude/worktrees` is untracked/ignored but local; do the export from `git archive`, not a copy of the working dir | frog |
| README accuracy | at risk | Install is `curl -fsSL https://frog.toys/install.sh \| sh`, but frog.toys does not resolve (see 4). README says cloud is "free, invite-only beta" (key via api.frog.toys/beta needs an invite code); that matches the current gate, not a public free capped beta. The default model `local/qwen3-4b` and `-m cloud/qwen3-coder-next` are consistent with providers.rs. Cline snippet says context 32768 but the model is 128k | frog |
| Install path | at risk | scripts/install.sh targets `muni-works/frog` releases/latest and supports macOS + Linux. **No release exists** on either repo (`gh release list` is empty). release.yml builds mac arm64 + linux x86_64/aarch64 on a `v*` tag, so it has never run. **No brew formula/tap anywhere** (grep: only `brew install xcodegen`) | frog / release |
| tang-llm binary for quickstart | **missing** | setup.rs:17 `TODO(release): no prebuilt tang-llm exists yet`; `ecto/tang` has zero releases, so the URL 404s and setup falls back to `cargo install --git` (slow, needs a toolchain). tang has `.github/workflows/mac-release.yml` (unsigned fallback, commit 5cc60299) but no run has happened. TANG_RELEASE also points at ecto/tang, not muni-works | release / frog |
| Linux | partial | install.sh and release.yml cover Linux CLI; README documents bubblewrap sandbox. The Linux GTK app is a draft PR (#31, Oct 17). **Linux CI is red** on main (open-items: `sandbox_write_check_resolves_dotdot_and_new_paths` on ubuntu). The macOS CI job also fails | frog |
| macOS app | in progress | apps/macos/scripts/release.sh builds/signs/notarizes a dmg + Sparkle appcast, but needs a Developer ID cert, notary profile, and a Sparkle key on the release Mac (none confirmed). Depends on #6 | release / Cam |
| CI on main | **at risk** | the last 6 runs on main and branches all FAIL (both macos-14 and ubuntu). frog#38 (git identity for checkpoint tests) is open and unmerged. Going public with a red badge is bad | frog |
| Open PRs | info | #38 CI fix (open), #36 pond design (draft), #31 Linux (draft) | frog |

### 2) frog cloud
| Item | Status | Evidence | Owner |
|---|---|---|---|
| Edge, keys, tiers | done | zest/edge/src (keys, tiers, admit, usage, hours, fleet); migrations/0001_ledger.sql. Beta tier = 2 streams, 30 rpm, $2 credit per invite (tiers.ts:19) | zest |
| Signup/auth | **missing vs the plan** | Only invite-code redemption at api.frog.toys/beta ("Enter your invite code"). No Better Auth, no Neon, no email sign-in in zest (grep: no hits for better-auth/neon). Neon account is still a Cam todo (chief open-items). Device-flow login is "post-launch" in frog/docs/plans/2026-10-21-frog-account-design.md | zest / Cam |
| Free capped beta | in progress | caps exist per key (streams/rpm/credit). Not open signup: needs an invite per user, so "free capped beta" in public means someone must mint codes or add open signup | zest / Cam |
| Abuse limits | partial | per-key rpm/streams + $ credit only. No IP/Turnstile/signup throttle, no email verification, and nothing to stop code-sharing | zest |
| Plans (Pro/Max) + Stripe | missing (as stated) | pro/max5/max tiers defined (tiers.ts), but docs/pricing.md says 5-hour/weekly enforcement "ships with billing (not yet in the edge)". No Stripe code. Fine for Beat 1 if plans are shown as "coming", not sold | zest |
| Pricing | done | docs/pricing.md = $0.60 / $0.06 / $1.50; live in /v1/models (zest#30, deployed) | zest |
| Status page | done, but red | https://api.frog.toys/status (200). **Currently says "no capacity is up right now."** frog-cloud-3 pod 5972sc9ke6kh3d was stopped by Cam on 2026-10-22 ~02:30Z (open-items) | zest |
| Docs page | missing | api.frog.toys/docs, /pricing, /privacy, /activate all 404. /terms exists. distribution/README.md lists a public docs URL as a prerequisite and the models.dev draft uses a placeholder (`doc = ".../docs" # TODO`) | zest / frog |
| Monitoring | in progress | Prometheus metrics endpoint (zest#29) + Grafana frog-cloud dashboard; /health returns `ok`. No alerting/uptime pager found; a single node is the only capacity (single point of failure) | zest |
| Capacity risk | at risk | one H200 pod; KV for 8x128k shares VRAM with 2 small models (open-items watch item: possible OOM under full load). FA2 swap needs Cam's go | zest / Cam |

### 3) tang IR post and speed claims
| Item | Status | Evidence | Owner |
|---|---|---|---|
| IR post draft | **missing** | No post/blog/announce draft found in tang, zest, frog or chief. Source material exists: tang/docs/tensor-ir.md (design argument, "past a certain scale beats hand kernels", 18% faster transformer block, flash attention 7.6x at n=1024) and BENCHMARKS.md. Those need checking against the "tang IR" claim in the post | release |
| "#1 speed" claim | at risk | Benchmark writeup is a draft: "DRAFT, not for publication" (zest/docs/bench/frog-api-vs-novita.md). Numbers: engine 234.4 tok/s (Q4), 222.2 (Q8); via API 224.7 sampler-fix / ~215 via api.frog.toys; Novita 174 is Artificial Analysis as read 2026-10-20, to be re-read on publish day. **245 tok/s** (used in chief open-items and in this task) is **not in the writeup**; the writeup tops out at 234.4. Reconcile before posting; quote API-level numbers | zest |
| Head-to-head vs Novita | missing | "needs a Novita key (Cam) before publishing any comparison" (same doc, "Before publishing"); the same-day h2h and 20-task pass@1 have not run | zest / Cam |
| "#1" on AA | not verified | Artificial Analysis outreach is on hold (open-items). No listing yet, so "#1" is only a self-measured claim | zest |
| FA2 prefill | done in code, not deployed | tang#131 merged 2026-10-22 02:05Z (FA2 on by default). Measured on H200: 30k 36.9 -> 22.3 s (1.65x), **54k 87.5 -> 40.7 s (2.15x)**; KL <= 3.5e-5. So "2x at 54k" is supported. Stale: tang/docs/bench/fa2-prefill.md still has the pre-measurement estimate table (2.8x). The production swap needs Cam's go | zest |
| Open tang PRs | info | #130 JSON-schema decoding (draft, not GPU-verified), #128 tile (superseded?), #122 tree verify (draft) | zest |

### 4) Launch assets
| Item | Status | Evidence | Owner |
|---|---|---|---|
| Reel | in progress | tang/.claude/worktrees/tang-website-refresh-6ed524/tang-reel.mp4 (14 MB, Oct 18, 47 s). Source in tang/tools/reel. Lives only in a worktree (not committed or hosted). The soundtrack is not in the repo ("bring a track you have the rights to"): confirm audio rights | release |
| Post drafts (IR, frog) | missing | see 3; none found on disk | release |
| frog.toys website | **at risk / not live** | `dig frog.toys` returns NS records only (Cloudflare nameservers), no A/AAAA; every `https://frog.toys/*` request fails to connect, including /install.sh. frog.eco also fails. The site source exists (site/index.html, vercel.json) in frog main; the open-items list has "Vercel GitHub app uninstall" as a Cam todo, so hosting may be in flux. tang's own site is in tang/site | release / Cam |
| Distribution (models.dev, LiteLLM) | in progress | local PR drafts at ~/Developer/dist-prs/{models.dev,litellm} (not submitted). Plan zest/docs/distribution/README.md: aim for models.dev + LiteLLM + docs before Oct 30. Needs a real docs URL, release_date, max output tokens, and a published benchmark. Every submission needs Cam | Cam |

### 5) Agent snippets
| Item | Status | Evidence | Owner |
|---|---|---|---|
| opencode, Cline/Roo/Kilo, Continue | in README | frog README "Other agents" section has opencode.json, Cline-style OpenAI-compatible steps, and Continue config.yaml. Details to fix: Cline context 32768 vs real 128k; opencode snippet lacks `limit` | frog |
| Aider, Zed | missing from README | covered only in zest/docs/distribution/agent-presets.md (DRAFT, "verify" marks on several paths). Aider needs the `openai/` prefix + env vars | zest |
| Public docs page for snippets | missing | agent-presets step 1 says publish on frog.toys; frog.toys is down and api docs 404 | zest / release |
| Verified end-to-end | unknown | no record of running each agent against the live endpoint, and tool-call/JSON-schema output is not verified (tang#130 unmerged) | zest |

### 6) Apple signing / notarization
| Item | Status | Evidence | Owner |
|---|---|---|---|
| Developer ID cert + notary key | **missing** | Org enrollment pending (D-U-N-S; chief open-items Cam todo "Apple org + D-U-N-S"). `security find-identity` not run (not needed); tang's mac-release.yml falls back to unsigned because the 6 MACOS_*/ASC_* secrets do not exist | Cam |
| Unsigned fallback | in progress | tang/docs/release/macos-signing.md documents the ad-hoc path. curl/URLSession downloads do not get the quarantine flag; browser downloads do, so Frog.dmg (browser download) would need the `xattr -d com.apple.quarantine` / Open Anyway instructions. Not yet in frog README | release / frog |
| Oct 26 tang-llm binary | at risk | no tag, no workflow run, no release asset; the secrets can't exist by Oct 26 unless enrollment clears this week. Build unsigned from CI instead | release |

## Top 5 risks to Oct 30
1. **frog.toys is not reachable.** The README, install.sh, docs page, and every post link depend on it. Fix DNS/hosting first (A record or Vercel/Pages), and decide frog.toys vs frog.eco (code uses both). Owner: Cam + release. Time to fix: hours, but nobody owns it.
2. **No installable artifact exists.** Zero GitHub releases (frog or tang), release.yml and mac-release.yml never run, no brew, and tang-llm quickstart 404s (setup.rs TODO). Cut a dry-run tag now on a private repo and run `install.sh` from a clean Mac. Owner: release + frog.
3. **frog cloud capacity and signup.** Pod is stopped (status page is red), only one H200, invite-code-only signup with no Better Auth/Neon, no abuse controls beyond per-key rpm, no docs page. A launch-day spike will either 503 or need hand-minted codes. Decide: open beta behind codes (honest) or build signup. Owner: zest + Cam.
4. **The "#1 speed" claim is unpublishable as it stands.** The writeup is a draft, the h2h vs Novita hasn't run (needs a Novita key from Cam), 245 vs 234.4 vs ~215 tok/s are inconsistent, and AA hasn't listed us. Re-run same-day, quote API-level numbers, say "fastest we measured", date the AA read. Owner: zest + Cam.
5. **The public-repo hygiene gate.** Main CI is red (macOS + Ubuntu), DCO has no enforcement, and the scrub list is open: pedersen.garden/mew/LAN IPs in docs and tests, ecto/ URLs in 13 files, `frog.eco` vs `frog.toys`, tracked .claude/launch.json. The Oct 29 fresh-commit export freezes whatever is in it. Owner: frog.

Also watch: no IR post draft and no confirmed tang IR claims (release); Apple org enrollment (ship unsigned, add bypass docs); FA2 production swap still needs Cam's go and a re-bench so the published numbers match what is deployed.

## Suggested order for the next 3 days
- Today: Cam fixes frog.toys DNS and the Novita key; zest restarts the pod and checks status; frog merges #38 and gets CI green.
- Oct 23-24: frog scrub PR + dry-run fresh export into a private muni-works/frog; release builds the first tag in private and tests `install.sh`; zest ships the docs page and the same-day h2h.
- Oct 25-26: unsigned tang-llm release asset (signed only if Apple clears); release finalizes posts from measured numbers.
- Oct 27-28: end-to-end run of each agent snippet against the live endpoint; capacity load test.

# Migration: ecto/frog → muni-works/frog (public), plus release mechanics

Owner: release (plan) + frog manager (code PRs) + Cam (org/billing/visibility clicks).
Public flip: **Oct 29**, as a fresh single-commit repo. Evidence for every "today" claim is in
[audit.md](audit.md).

## 0. Shape of the move

| repo | today | at launch | how |
|---|---|---|---|
| frog | ecto/frog, private, 725 commits | **muni-works/frog**, public, 1 commit | `git archive` export of a frozen, scrubbed sha (§2-§3) |
| tang | ecto/tang, **public**, full history | **muni-works/tang** | GitHub **transfer** (§5). History is already public, so squashing gains nothing, and a transfer keeps stars, issues and redirects |
| tap | none | muni-works/homebrew-tap (optional, §8) | new repo |

After the flip, **muni-works/frog is canonical**. ecto/frog gets archived (read-only), and every
agent worktree's `origin` moves. Developing on ecto and re-squashing periodically would mean no
public PR history and no way for contributors to land PRs, so we don't do it.

## 1. Pre-export scrub PR (on ecto/frog, before the freeze)

Gate: each grep below returns only the lines listed as "keep". Run it on the export too (§3).

**`ecto/` (13 files).**
- functional: `apps/macos/scripts/release.sh:16,24` (`REPO=${FROG_RELEASE_REPO:-ecto/frog}` → `muni-works/frog`)
- fixtures (swap to `muni-works/frog`; they are test data, so update the assertions with them):
  `apps/macos/FrogTests/GitBadgeTests.swift:153-159`, `apps/macos/FrogTests/SidebarSnapshotTests.swift:132-168`,
  `crates/frog-engine/src/pond.rs:446`, `crates/puck/src/demo.rs:81`, `apps/macos/Frog/Views/PondBrief.swift:186` (doc comment),
  `crates/frog-engine/src/tools/bash.rs:1408` (comment)
- docs: `docs/site-deploy.md:21`, `docs/design/auto-mode-skittish.md:153`, `docs/design/chief-sandbox-profile.md:79`,
  `docs/design/pr-lifecycle.md:123,217,294`, `docs/design/sidebar-git/README.md:188-229`, `docs/design/sidebar-git/mockup.html:165-295`
- `git grep -nE 'ecto/(frog|tang)'` → 0 hits

**`frog.eco` → `frog.toys` (frog.eco doesn't resolve).**
- functional: `apps/macos/Frog/Info.plist:44` + `apps/macos/project.yml:44-46` (Sparkle `SUFeedURL`; auto-update is dead until this ships *and* frog.toys serves `/appcast.xml`),
  `apps/macos/Frog/Model/RemotePush.swift:26` (push relay), `apps/FrogKit/UI/Settings/EnergySettings.swift:77`,
  `apps/FrogKit/UI/Transcript/TurnCosts.swift:8,111`, `site/index.html:10,763`, `site/energy/index.html:236`
- cosmetic: `apps/macos/FrogTests/MessageTextTests.swift:63`, `apps/macos/scripts/hero_fixture.py:2`, `apps/macos/Frog/Views/SettingsView.swift:763`
- keep: `docs/ios/inventory.md:126` (it documents the bug)
- `git grep -n 'frog\.eco'` → only the keep line

**Hostnames, IPs, paths.**
- `apps/ios/Shared/House.swift:9` `frog.pedersen.garden` → `frog.example.com`
- `docs/research/tang-architecture.md:79` `mew:` → "a CUDA host"
- `crates/frog-engine/src/provider/openai.rs:446` `192.168.2.12:8420` → `192.0.2.10:8420` (TEST-NET-1)
- keep: the private-range SSRF tests (`tools/web.rs:691,743`, `auto.rs:906`, `policy.rs:165`) and `docs/freedom-analysis.md:189`
- 24 files with `/Users/cam` or `~/Developer`: change test fixtures to `/Users/me` / `~/src`; docs can keep them
- `git grep -nE 'pedersen\.garden|\bmew\b|192\.168\.2\.12'` → 0 hits

**Copy.**
- README:47,50,59-60: "free, invite-only beta … get one at api.frog.toys/beta" → "sign in at api.frog.toys (GitHub or email link); new accounts get a starting credit"
- README:65 opencode snippet: add `"limit":{"context":131072,"output":16384}` (zest to confirm max output)
- README: add the unsigned-app note (§7) and Aider/Zed snippets (from zest docs/distribution/agent-presets.md, verified ones only)
- Cam decides: `© 2026 Cam Pedersen` (Info.plist:32, project.yml:52) vs `© 2026 Municipal Robotics`

**Build health.** iOS + watch targets build (FrogFace.swift:34 break per docs/ios), or the README says Mac + CLI only and the targets are marked experimental.

## 2. What goes in the export

Everything tracked at the frozen sha, **except** `docs/launch/` (internal runbook, Cam's clicks, risk notes).
Open by default: docs/design, docs/plans and docs/research ship, scrubbed. `.frog/` and `.claude/` are untracked and can't leak through `git archive`. There are no submodules, no LFS and no `.gitattributes` export-ignore rules (checked), so the archive is exactly the tree minus the exclude.

## 3. Export procedure (Oct 29 morning, from a clean clone, not a worktree)

```sh
# freeze: the scrub PR is merged and CI is green on this sha
git clone git@github.com:ecto/frog.git /tmp/frog-src && cd /tmp/frog-src
SHA=$(git rev-parse origin/main); echo "$SHA" > /tmp/frog-export.sha

rm -rf /tmp/frog-export && mkdir -p /tmp/frog-export
git archive --format=tar "$SHA" -- . ':(exclude)docs/launch' | tar -x -C /tmp/frog-export

cd /tmp/frog-export
# gates on the export itself
! grep -rnE 'ecto/(frog|tang)|frog\.eco|pedersen\.garden|192\.168\.2\.12' --exclude-dir=.git . | grep -v 'docs/ios/inventory.md'
gitleaks detect --no-git -s . -v          # or trufflehog filesystem .
test -f LICENSE-MIT && test -f LICENSE-APACHE && test -f CONTRIBUTING.md && test -f SECURITY.md
cargo build --release -p frog && cargo test -p frog-engine   # builds from the export, not the source tree

git init -b main
git add -A
git -c user.name="Cam Pedersen" -c user.email="cam@muni.works" \
  commit -s -m "frog: a free, open coding agent" -m "Exported from the private history at $SHA."
git remote add origin git@github.com:muni-works/frog.git
git push -u origin main          # repo is still PRIVATE here
```

The file count must match: `git -C /tmp/frog-src ls-tree -r --name-only $SHA | grep -v '^docs/launch/' | wc -l` == `git ls-files | wc -l` in the export.
Author/committer email is a Cam call (`cam@muni.works` recommended, so the public commit doesn't expose a personal address). Signed-off-by uses the same identity.

## 4. Repo setup on muni-works/frog (before the flip)

- Actions secrets: `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID` (site.yml). Re-create rather than copy.
- Ruleset on main: required `check (ubuntu-latest)`, `check (macos-14)`, `macos-app`, `check-dco`, up to date, admin bypass (mirror ruleset 25683548).
- Description, topics, homepage `https://frog.toys`, Issues on, Discussions optional, Wiki off.
- Org Actions billing: private-repo minutes on muni-works are a separate account from ecto's (which is failing today). Once public, standard runners are free.
- Cam flips visibility on Oct 29 after §6 passes on the private repo. That's a public release, so it's Cam in-session.
- Then: archive ecto/frog; `git remote set-url origin git@github.com:muni-works/frog.git` in ~/Developer/frog and every `.frog/worktrees/*`. Branches in flight get rebased onto the export commit with `git rebase --onto`. Their old base doesn't exist in the new history, so a worker lands each one as a patch series.

## 5. tang: transfer, then a tang-llm release

1. Cam: Settings → Transfer ecto/tang → muni-works. GitHub redirects `ecto/tang` URLs (web, git, API). setup.rs:15,22 already point at muni-works/tang, so they start working the moment it moves.
2. tang manager: main CI green (today: `cargo fmt --check` diffs and clippy `unused variable l/block`, `unneeded mut`, run 40375040355).
3. Tag `v0.1.0` on tang main. `.github/workflows/mac-release.yml` builds `tang-llm-aarch64-apple-darwin.tar.gz` + `.sha256` on macos-15. These are exactly the names and the `<hex>  <name>` format that setup.rs:22,113 expects. With no `MACOS_CERT_P12` secret, `SIGN=false`, so the binary is unsigned (ad-hoc linker signature).
4. Verify: `curl -fsSLI https://github.com/muni-works/tang/releases/latest/download/tang-llm-aarch64-apple-darwin.tar.gz` → 302 → 200, then `frog setup` on a clean Mac.
5. It must be a full release, not a prerelease: setup.rs uses `releases/latest`, which skips prereleases.

## 6. frog release mechanics (release.yml has never run)

**Fix PR (frog manager), before any tag:**
1. macOS job: check out tang next to the repo (`actions/checkout` with `repository: muni-works/tang`, `path: tang`, `TANG_DIR=$GITHUB_WORKSPACE/tang`), or drop `FROG_REQUIRE_TANG=1` and fetch the tang release asset into the bundle. Today `build-engine.sh:44` exits 1.
2. `brew install xcodegen` before `xcodegen generate` (ci.yml:52 does it; release.yml doesn't).
3. Put `Frog.zip` and its sha256 in `dist/` (they're inside `dist/$name/` today), and use `shasum -a 256` on macOS.
4. install.sh: **remove the app branch** (lines 84-113). It leaves `~/.local/bin/frog` as a wrapper to `~/.local/Resources/frog`, which doesn't exist, after deleting the unzipped app. The CLI tarball is the install. The app ships as a separate download (§7). Also fix the `resolve_version` comment, since `releases/latest` skips prereleases.

**Test sequence (on private muni-works/frog after §3):**
1. Tag `v0.1.0-rc1`. All three matrix jobs and the release job are green. The prerelease has 3 tarballs, 3 `.sha256`, `SHA256SUMS`, `Frog.zip` and `Frog.zip.sha256`.
2. install.sh can't read a private repo's releases unauthenticated, so mirror the rc assets to a throwaway **public** repo (`muni-works/frog-release-test`) and run with `FROG_REPO=muni-works/frog-release-test FROG_VERSION=v0.1.0-rc1`. Or wait for the flip and test with the real tag minutes before the post.
3. Matrix: clean macOS arm64 (new user account, no Rust), Ubuntu 24.04 x86_64, Ubuntu arm64 (docker `--platform linux/arm64`), wget-only (no curl), `~/.local/bin` not on PATH, `FROG_VERSION` pinned and unpinned. Each one: `frog --version`, then `frog -p "say hi" -m cloud/qwen3-coder-next` with a test key, then the default local model first-run on the Mac (this depends on the §5 tang asset).
4. Then tag **`v0.1.0`** (non-rc, so `releases/latest` resolves) on the public repo on Oct 29 after the flip.
5. frog.toys/install.sh must serve the fixed script: site.yml deploys `site/` to Pages, so either copy `scripts/install.sh` into `site/` in the build step or add a Pages redirect to `raw.githubusercontent.com/muni-works/frog/v0.1.0/scripts/install.sh`. Today it serves a stale copy from somewhere else. Find where that file comes from (a Pages upload outside site.yml?) and remove it.

## 7. macOS signing: unsigned until Apple clears

- Cam is enrolling Municipal Robotics as an Apple org (D-U-N-S). Until it clears, everything is unsigned.
- CLI via install.sh: curl sets no quarantine flag, and install.sh still runs `xattr -d` and ad-hoc `codesign -s -` (install.sh:131-134). No user action.
- tang-llm via `frog setup`: reqwest sets no quarantine either. No user action.
- Frog.app (browser download from the release page): Gatekeeper blocks it. README/site copy:
  > The Mac app isn't notarized yet (our Apple developer enrollment is in progress). The first time,
  > right-click Frog.app → Open → Open. Or run `xattr -d com.apple.quarantine /Applications/Frog.app`.
  > The CLI installer doesn't need this.
- When enrollment clears: add the 6 secrets in mac-release.yml's header (`MACOS_CERT_P12`, `MACOS_CERT_PASSWORD`, `MACOS_SIGN_IDENTITY`, `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`) to muni-works/tang, mirror them in frog's release.yml (it signs ad-hoc today, so it needs a signing step like tang's), then re-tag. The app's Sparkle needs `SUPublicEDKey` and the appcast on frog.toys (apps/macos/scripts/release.sh).

## 8. Homebrew: decision

| option | cost | recommendation |
|---|---|---|
| A. none at launch | 0 | fallback if §6 slips past Oct 28 |
| **B. `muni-works/homebrew-tap`, formula for the CLI from release tarballs** | ~1 h + a bump job | **recommended**: `brew install muni-works/tap/frog`. Formula URLs = release tarballs, sha256 from `SHA256SUMS`. Bottles aren't needed, since it installs a prebuilt binary. Add a release.yml job that opens a bump PR on the tap |
| C. cask for Frog.app | ~1 h | not until signing. An unsigned cask gets quarantined, and Homebrew has deprecated `--no-quarantine` |
| D. homebrew-core | days, review | after launch, once there's adoption |

## 9. Risks

| # | risk | mitigation |
|---|---|---|
| R1 | Actions billing on ecto stays broken, so there's no CI signal and merges keep going through the bypass | Cam fixes billing first. Run the full suite on the frozen sha before export |
| R2 | release.yml fails its first run (3 known defects) | fix PR + rc tag on the private repo by Oct 28 |
| R3 | install.sh app branch bricks `frog` on Macs | remove the branch (§6.4) |
| R4 | `frog setup` / first local run fails: muni-works/tang doesn't exist, no tang-llm asset | transfer + tang tag (§5) before frog's tag. Test on a clean Mac |
| R5 | frog.toys serves a stale install.sh and a placeholder index | site.yml deploys after billing. Add install.sh to the Pages build. Verify by hash |
| R6 | the export leaks something the scrub missed | grep gates + gitleaks on the export, plus a human skim of `docs/` |
| R7 | **a fresh single commit destroys the "234 commits/day" receipt** | publish a per-day commit-count CSV generated from the private history, or drop the claim from the post |
| R8 | in-flight branches can't merge into the new root | land or park them before the freeze. Post-flip, land them as patch series |
| R9 | public tang CI is red when HN clicks through | tang fmt + clippy fix before the post |
| R10 | Sparkle auto-update points at a dead domain, so the first app users never get updates | frog.eco → frog.toys in Info.plist/project.yml, plus an `/appcast.xml` on frog.toys (today the placeholder answers 200 there, which Sparkle would choke on) |
| R11 | the iOS/watch targets don't build in a public repo | fix or mark experimental (§1) |
| R12 | two visible repos (ecto/frog archived, muni-works/frog) confuse people | ecto/frog stays private, then archived. Only muni-works is ever public |

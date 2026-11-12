# Releasing frog

Two publishers share each tag's release, and neither can do the other's half:

| Publisher | Assets | Why it can't do the other |
| --- | --- | --- |
| `.github/workflows/release.yml` (on tag push) | `frog-<tag>-<target>.tar.gz`, `.sha256`, `.minisig`, `SHA256SUMS`, `frog.rb` | the app needs a private tang checkout (`FROG_REQUIRE_TANG`), which CI doesn't have |
| `apps/macos/scripts/release.sh` (on the release Mac) | `Frog.dmg`, `appcast.xml` | the CLI is built for three targets, two of them Linux |

`scripts/release-local.sh build|publish` is the no-CI fallback for the CLI half.

## The one rule

**A release must never be published while it's missing assets.**

`site/install.sh` resolves `https://api.github.com/repos/muni-works/frog/releases/latest`, and
GitHub's "latest" is the most recently *published* non-prerelease release. Publish a release
before its tarballs are attached and `curl -fsSL https://frog.toys/install.sh | sh` 404s for
every user on every platform. That is what v0.2.1 did.

So both publishers upload into a **draft** (drafts are invisible to `releases/latest`, so the
last good release keeps serving), and both end by calling:

```sh
scripts/release-assets.sh publish v0.2.2
```

That publishes the draft if — and only if — the asset set is complete, and otherwise leaves it
as a draft for the other publisher. Whichever publisher runs second does the publishing, so
their order doesn't matter and they can't race.

## Steps for a stable release

1. Bump `version` in `Cargo.toml` (workspace) and `MARKETING_VERSION` in `apps/macos/project.yml`.
2. Write `docs/releases/v<version>.md`.
3. Commit, then `git tag -s v<version> && git push origin v<version>`. The tag push starts the
   `release` workflow, which uploads the CLI into a **draft**.
4. On the release Mac, with a clean tree and the notary credentials:
   `apps/macos/scripts/release.sh <version>`. It uploads `Frog.dmg` + `appcast.xml` into the
   same draft and publishes it once both halves are there.
5. Verify, from a machine with no frog on it:
   ```sh
   scripts/release-assets.sh check latest
   curl -fsSL https://frog.toys/install.sh | sh
   curl -fsSL https://frog.toys/download -o /tmp/Frog.dmg   # follows releases/latest
   ```
   The `release-assets` workflow also runs on `release: published` and daily, and fails loudly
   if `releases/latest` is ever missing something `install.sh` needs.

Steps 3 and 4 can run in either order or at the same time. If only one has run, the release sits
as a draft and nobody's install breaks.

## If a release goes out broken

Re-run the tag's `release` workflow (**Re-run all jobs** on that run — `workflow_dispatch` is a
dry run that publishes nothing). `softprops/action-gh-release` updates the existing release and
adds the missing assets rather than replacing the dmg/appcast, then
`scripts/release-assets.sh publish` publishes it once the set is complete.

Re-running uses the workflow file from the tag's commit, not from `main`, so a fix to
`release.yml` on `main` doesn't apply to an old tag — the re-run needs the tag's own file to be
sound. For a tag cut before such a fix, dispatch instead: it builds that tag using the default
branch's workflow file and attaches the CLI to its release.

```sh
gh workflow run release.yml --repo muni-works/frog -f tag=v0.2.1
```

To publish without CI at all, `scripts/release-local.sh <version> build` then `publish` on a
machine with the minisign key.

## Nobody has to notice

Drafts keep `install.sh` working, but on their own they'd make a dead publisher *quiet*: a
release that never shipped looks exactly like one not yet cut. That is why every release from
v0.1.1-rc3 through v0.2.1 was finished by hand — nothing said a run had died.

So `scripts/release-assets.sh drafts` is an error when a draft is **complete** (publishing was
skipped) or has been **incomplete for more than 6 hours** (a publisher died). The `release-assets`
workflow runs it on the daily timer, so both cases turn into a red run instead of waiting for
someone to notice.

```sh
scripts/release-assets.sh drafts          # default 6h limit
scripts/release-assets.sh drafts 24       # for a slow release day
```

## Runners

`release.yml`'s macOS leg runs on `macos-26`. It was `macos-14`, which GitHub retired on
2026-11-02: the job died in 0s with `The configuration 'macos-14-arm64-us-default' is not
supported`, the dependent `release` job was skipped, and the dmg-only release went out on its
own. If a macOS job ever fails in ~0s again, check the label first.

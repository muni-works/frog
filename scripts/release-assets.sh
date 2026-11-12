#!/bin/sh
# Assert that a GitHub release carries every asset frog's public download paths need, and gate
# publishing on it.
#
#   scripts/release-assets.sh check   <tag|latest>   # exit 1, listing what's missing
#   scripts/release-assets.sh publish <tag>          # publish a draft, but only once check passes
#
# Two publishers share one tag and neither can do the other's half:
#   - apps/macos/scripts/release.sh uploads Frog.dmg + appcast.xml (it needs a private tang
#     checkout, so CI can't build the app).
#   - .github/workflows/release.yml uploads the CLI tarballs + checksums + signatures.
# Both create or attach to a *draft* and both finish here, so the order they run in stops
# mattering: whichever is second finds the asset set complete and publishes.
#
# Why a draft and not just "upload then publish": site/install.sh resolves
# https://api.github.com/repos/muni-works/frog/releases/latest, and GitHub's "latest" is the most
# recently published non-prerelease release. A published release that's missing its tarballs
# therefore 404s `curl -fsSL https://frog.toys/install.sh | sh` for everyone on every platform.
# Drafts are invisible to releases/latest, so an incomplete release can only ever leave the last
# good version serving.
#
# That is exactly what v0.2.1 did: release.sh published Frog.dmg + appcast.xml at 19:15:26 and
# the CI run that was supposed to attach the tarballs died on a retired runner label, so
# releases/latest pointed at a release with no CLI in it.
set -eu

REPO=${FROG_RELEASE_REPO:-muni-works/frog}
TARGETS="aarch64-apple-darwin x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu"
# The unversioned x86_64 asset the Frog Cloud sandbox image fetches (frog at the tarball root).
CLOUD=x86_64-unknown-linux-gnu

err() { printf 'release-assets: error: %s\n' "$*" >&2; exit 1; }
info() { printf 'release-assets: %s\n' "$*"; }
warn() { printf 'release-assets: warning: %s\n' "$*" >&2; }

usage() {
    cat >&2 <<'EOF'
usage: release-assets.sh check   <tag|latest>
       release-assets.sh publish <tag>

check    exit 1, listing what's missing, unless the release carries every asset that
         site/install.sh and frog.toys/download need.
publish  publish a draft release, but only once check passes. A draft that's still
         incomplete is left alone (the other publisher hasn't run yet).
EOF
    exit 2
}

command -v gh >/dev/null 2>&1 || err "missing required command: gh"

CMD=${1:-}
REF=${2:-}
[ -n "$CMD" ] && [ -n "$REF" ] || usage

# One "<field>\t<value>" line per field, one "asset\t<name>" line per asset.
read_release() { # <tag|latest>
    if [ "$1" = latest ]; then
        # The same endpoint install.sh resolves, so "latest" means what install.sh sees.
        gh api "repos/$REPO/releases/latest" --jq '
            "tag\t" + .tag_name,
            "draft\tfalse",
            "prerelease\t" + (.prerelease | tostring),
            (.assets[] | "asset\t" + .name)'
    else
        gh release view "$1" --repo "$REPO" --json tagName,isDraft,isPrerelease,assets --jq '
            "tag\t" + .tagName,
            "draft\t" + (.isDraft | tostring),
            "prerelease\t" + (.isPrerelease | tostring),
            (.assets[] | "asset\t" + .name)'
    fi
}

RAW=$(read_release "$REF") || err "no release '$REF' on $REPO"

TAG=
DRAFT=false
PRERELEASE=false
ASSETS=" "
# A here-doc, not a pipe: a pipeline would run the loop in a subshell and lose these.
while IFS="$(printf '\t')" read -r field value; do
    case $field in
        tag) TAG=$value ;;
        draft) DRAFT=$value ;;
        prerelease) PRERELEASE=$value ;;
        asset) ASSETS="$ASSETS$value " ;;
    esac
done <<EOF
$RAW
EOF

has() { case $ASSETS in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# What install.sh needs: for each target, the tarball and the checksum it verifies against it
# (a missing checksum is fatal there, not a warning). The .minisig is optional by design —
# install.sh warns and installs on the checksum alone when a release ships unsigned.
CLI=
EXPECTED=
for target in $TARGETS; do
    CLI="$CLI frog-$TAG-$target.tar.gz frog-$TAG-$target.tar.gz.sha256"
    EXPECTED="$EXPECTED frog-$TAG-$target.tar.gz.minisig"
done
CLI="$CLI frog-$CLOUD.tar.gz frog-$CLOUD.tar.gz.sha256"
EXPECTED="$EXPECTED frog-$CLOUD.tar.gz.minisig"

if [ "$PRERELEASE" = true ]; then
    # releases/latest never resolves to a prerelease and frog.toys/download points at
    # releases/latest, so publishing an rc can't break the install path. Warn about a missing
    # CLI (an rc is installed by pinning FROG_VERSION, so it should carry one) but don't block:
    # apps/macos/scripts/release.sh's unsigned build publishes an app-only prerelease on purpose.
    REQUIRED=
    for asset in $CLI; do
        has "$asset" || warn "no $asset (an rc installed with FROG_VERSION would 404)"
    done
else
    # A stable release is what install.sh and frog.toys/download resolve to: it needs the CLI
    # *and* the app, or one of the two install paths is broken.
    REQUIRED="$CLI SHA256SUMS frog.rb Frog.dmg appcast.xml"
fi

MISSING=
for asset in $REQUIRED; do
    has "$asset" || MISSING="$MISSING $asset"
done
for asset in $EXPECTED; do
    has "$asset" || warn "no $asset; install.sh installs it with a warning (checksum only)"
done

report() {
    printf 'release-assets: %s is missing %s asset(s):\n' "$TAG" "$(printf '%s' "$MISSING" | wc -w | tr -d ' ')" >&2
    for asset in $MISSING; do printf '  %s\n' "$asset" >&2; done
}

case $CMD in
check)
    if [ -n "$MISSING" ]; then
        report
        err "$TAG is not installable: curl -fsSL https://frog.toys/install.sh | sh would 404"
    fi
    info "$TAG has every asset install.sh needs"
    ;;
publish)
    if [ -z "$MISSING" ]; then
        if [ "$DRAFT" = true ]; then
            if [ "$PRERELEASE" = true ]; then
                gh release edit "$TAG" --repo "$REPO" --draft=false --prerelease
            else
                gh release edit "$TAG" --repo "$REPO" --draft=false
            fi
            info "published $TAG (asset set complete)"
        else
            info "$TAG is already published and its asset set is complete"
        fi
        exit 0
    fi
    report
    if [ "$DRAFT" = true ]; then
        info "left $TAG as a draft: the other publisher hasn't attached its assets yet."
        info "releases/latest skips drafts, so install.sh keeps serving the last good release."
        exit 0
    fi
    err "$TAG is published but incomplete; install.sh 404s for every user until it's fixed"
    ;;
*)
    usage
    ;;
esac

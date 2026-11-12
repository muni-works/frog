#!/bin/sh
# Assert that a GitHub release carries every asset frog's public download paths need, and gate
# publishing on it.
#
#   scripts/release-assets.sh check   <tag|latest>   # exit 1, listing what's missing
#   scripts/release-assets.sh publish <tag>          # publish a draft, but only once check passes
#   scripts/release-assets.sh drafts  [max-hours]    # exit 1 if a draft is stuck or ready
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
#
# `drafts` closes the other half of that hole. Drafts keep install.sh working, but they also make
# a dead publisher quiet: a release that never shipped looks exactly like one not yet cut. Every
# release since v0.1.1-rc2 had to be finished by hand because nothing said a run had died. So a
# draft that is complete (publishing was skipped) or older than max-hours (a publisher never
# finished) is an error, and the scheduled workflow turns it into a red run.
set -eu

REPO=${FROG_RELEASE_REPO:-muni-works/frog}
TARGETS="aarch64-apple-darwin x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu"
# The unversioned x86_64 asset the Frog Cloud sandbox image fetches (frog at the tarball root).
CLOUD=x86_64-unknown-linux-gnu
# How long a draft may stay incomplete before it counts as a publisher that died.
DEFAULT_MAX_HOURS=6

err() { printf 'release-assets: error: %s\n' "$*" >&2; exit 1; }
info() { printf 'release-assets: %s\n' "$*"; }
warn() { printf 'release-assets: warning: %s\n' "$*" >&2; }

usage() {
    cat >&2 <<'EOF'
usage: release-assets.sh check   <tag|latest>
       release-assets.sh publish <tag>
       release-assets.sh drafts  [max-hours]

check    exit 1, listing what's missing, unless the release carries every asset that
         site/install.sh and frog.toys/download need.
publish  publish a draft release, but only once check passes. A draft that's still
         incomplete is left alone (the other publisher hasn't run yet).
drafts   exit 1 if any draft is complete but unpublished, or has been incomplete for
         longer than max-hours (default 6) — a publisher that died.
EOF
    exit 2
}

command -v gh >/dev/null 2>&1 || err "missing required command: gh"

CMD=${1:-}
REF=${2:-}
[ -n "$CMD" ] || usage

# One "<field>\t<value>" line per field, one "asset\t<name>" line per asset.
read_release() { # <tag|latest>
    if [ "$1" = latest ]; then
        # The same endpoint install.sh resolves, so "latest" means what install.sh sees.
        gh api "repos/$REPO/releases/latest" --jq '
            "tag\t" + .tag_name,
            "draft\tfalse",
            "prerelease\t" + (.prerelease | tostring),
            "created\t" + .created_at,
            (.assets[] | "asset\t" + .name)'
    else
        gh release view "$1" --repo "$REPO" --json tagName,isDraft,isPrerelease,createdAt,assets --jq '
            "tag\t" + .tagName,
            "draft\t" + (.isDraft | tostring),
            "prerelease\t" + (.isPrerelease | tostring),
            "created\t" + .createdAt,
            (.assets[] | "asset\t" + .name)'
    fi
}

TAG=
DRAFT=false
PRERELEASE=false
CREATED=
ASSETS=" "

load_release() { # <tag|latest>: fill the globals above
    _raw=$(read_release "$1") || return 1
    TAG=; DRAFT=false; PRERELEASE=false; CREATED=; ASSETS=" "
    # A here-doc, not a pipe: a pipeline would run the loop in a subshell and lose these.
    while IFS="$(printf '\t')" read -r field value; do
        case $field in
            tag) TAG=$value ;;
            draft) DRAFT=$value ;;
            prerelease) PRERELEASE=$value ;;
            created) CREATED=$value ;;
            asset) ASSETS="$ASSETS$value " ;;
        esac
    done <<EOF
$_raw
EOF
}

has() { case $ASSETS in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# What install.sh fetches, and so what must exist before a release is visible as latest: for each
# target the tarball and the checksum it verifies against (a missing checksum is fatal there, not
# a warning), plus the unversioned cloud asset.
cli_assets() { # <tag>
    for target in $TARGETS; do
        printf '%s\n' "frog-$1-$target.tar.gz" "frog-$1-$target.tar.gz.sha256"
    done
    printf '%s\n' "frog-$CLOUD.tar.gz" "frog-$CLOUD.tar.gz.sha256"
}

required_assets() { # <tag> <prerelease>
    cli_assets "$1"
    # releases/latest never resolves to a prerelease and frog.toys/download points at
    # releases/latest, so publishing an rc can't break either install path.
    [ "$2" = true ] && return 0
    # A stable release is what both install paths resolve to: the CLI *and* the app.
    printf '%s\n' SHA256SUMS frog.rb Frog.dmg appcast.xml
}

# Sets MISSING from the globals. The .minisig is optional by design — install.sh warns and
# installs on the checksum alone when a release ships unsigned.
MISSING=
check_missing() {
    MISSING=
    for asset in $(required_assets "$TAG" "$PRERELEASE"); do
        has "$asset" || MISSING="$MISSING $asset"
    done
    for asset in $(cli_assets "$TAG"); do
        has "$asset" && ! has "$asset.minisig" && \
            warn "no $asset.minisig; install.sh installs it with a warning (checksum only)"
    done
    return 0
}

report_missing() {
    printf 'release-assets: %s is missing %s asset(s):\n' "$TAG" "$(printf '%s' "$MISSING" | wc -w | tr -d ' ')" >&2
    for asset in $MISSING; do printf '  %s\n' "$asset" >&2; done
}

# ISO8601 -> epoch seconds. GNU date, then BSD date; empty when neither can parse it.
epoch() {
    [ -n "$1" ] || return 0
    date -u -d "$1" +%s 2>/dev/null || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s 2>/dev/null || true
}

case $CMD in
check)
    [ -n "$REF" ] || usage
    load_release "$REF" || err "no release '$REF' on $REPO"
    check_missing
    if [ -n "$MISSING" ]; then
        report_missing
        err "$TAG is not installable: curl -fsSL https://frog.toys/install.sh | sh would 404"
    fi
    info "$TAG has every asset install.sh needs"
    ;;
publish)
    [ -n "$REF" ] || usage
    load_release "$REF" || err "no release '$REF' on $REPO"
    check_missing
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
    report_missing
    if [ "$DRAFT" = true ]; then
        info "left $TAG as a draft: the other publisher hasn't attached its assets yet."
        info "releases/latest skips drafts, so install.sh keeps serving the last good release."
        exit 0
    fi
    err "$TAG is published but incomplete; install.sh 404s for every user until it's fixed"
    ;;
drafts)
    MAX_HOURS=${REF:-$DEFAULT_MAX_HOURS}
    NOW=$(date -u +%s)
    OPEN=$(gh api "repos/$REPO/releases?per_page=100" --jq '.[] | select(.draft) | .tag_name') \
        || err "couldn't list releases on $REPO"
    [ -n "$OPEN" ] || { info "no open drafts"; exit 0; }
    BAD=0
    for tag in $OPEN; do
        load_release "$tag" || { warn "couldn't read draft $tag"; BAD=1; continue; }
        check_missing
        if [ -z "$MISSING" ]; then
            printf 'release-assets: error: %s is a draft with a complete asset set; publishing was skipped\n' "$tag" >&2
            printf '  fix: scripts/release-assets.sh publish %s\n' "$tag" >&2
            BAD=1
            continue
        fi
        born=$(epoch "$CREATED")
        age_h=
        [ -n "$born" ] && age_h=$(( (NOW - born) / 3600 ))
        if [ -z "$age_h" ]; then
            warn "$tag is an incomplete draft (age unknown)"
        elif [ "$age_h" -ge "$MAX_HOURS" ]; then
            printf 'release-assets: error: %s has been an incomplete draft for %sh (limit %sh)\n' \
                "$tag" "$age_h" "$MAX_HOURS" >&2
            printf '  a publisher died before attaching %s asset(s)\n' \
                "$(printf '%s' "$MISSING" | wc -w | tr -d ' ')" >&2
            printf '  fix: gh workflow run release.yml --repo %s -f tag=%s\n' "$REPO" "$tag" >&2
            BAD=1
        else
            info "$tag is an incomplete draft (${age_h}h old); waiting on the other publisher"
        fi
    done
    [ "$BAD" = 0 ] || exit 1
    info "no stuck drafts"
    ;;
*)
    usage
    ;;
esac

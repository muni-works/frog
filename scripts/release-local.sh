#!/bin/zsh
# Build, sign and publish frog's CLI release without GitHub Actions (what release.yml did).
#
#   scripts/release-local.sh 0.2.0 build     # tarballs, checksums, minisig, frog.rb in dist/v0.2.0
#   scripts/release-local.sh 0.2.0 publish   # upload dist/v0.2.0 to the GitHub release
#
# build:
#   - Linux x86_64 + aarch64 on $FROG_LINUX_HOST (default mew) with cargo-zigbuild; x86_64 pins
#     glibc 2.36 (debian trixie, the Frog Cloud sandbox base). Builds into ~/build/target-<name>
#     there and deletes it after.
#   - macOS arm64 on this Mac (CARGO_BUILD_JOBS=4). Developer ID signed and notarized when the
#     certificate and the `frog` notary profile exist; otherwise unsigned (install.sh ad-hoc signs).
#   - SHA256SUMS, a minisign signature per tarball ($FROG_MINISIGN_KEY = path to the secret key;
#     minisign asks for its password itself), and the rendered Homebrew formula.
# publish: creates the release (notes from docs/releases/v<version>.md), or, when
#   apps/macos/scripts/release.sh already made it with Frog.dmg + appcast.xml, adds the CLI
#   assets to it and replaces its generated notes.
set -euo pipefail

VERSION=${1:?usage: release-local.sh <version> build|publish}
CMD=${2:?usage: release-local.sh <version> build|publish}
TAG="v$VERSION"
REPO=${FROG_RELEASE_REPO:-muni-works/frog}
HOST=${FROG_LINUX_HOST:-mew}
SIGN_ID=${FROG_SIGN_ID:-Developer ID Application}
NOTARY_PROFILE=${FROG_NOTARY_PROFILE:-frog}
ROOT=${0:A:h:h}
DIST="$ROOT/dist/$TAG"
NOTES="$ROOT/docs/releases/$TAG.md"
cd "$ROOT"

step() { print -P "%F{green}==>%f $*" }
fail() { print -P "%F{red}error:%f $*" >&2; exit 1 }

[[ $VERSION =~ '^[0-9]+\.[0-9]+\.[0-9]+(-rc[0-9]+)?$' ]] || fail "version must look like 1.2.3 or 1.2.3-rc1"
grep -q "^version = \"$VERSION\"" Cargo.toml || fail "Cargo.toml's workspace version isn't $VERSION"

package() { # <target> <binary>: dist/frog-<tag>-<target>.tar.gz with frog + README
    local name="frog-$TAG-$1"
    rm -rf "$DIST/$name"; mkdir -p "$DIST/$name"
    cp "$2" "$DIST/$name/frog"; cp README.md "$DIST/$name/"
    tar -C "$DIST" -czf "$DIST/$name.tar.gz" "$name"
    rm -rf "$DIST/$name"
    (cd "$DIST" && shasum -a 256 "$name.tar.gz" > "$name.tar.gz.sha256")
}

build_linux() {
    local work="build/frog-release-$VERSION" tgt="build/target-frog-release-$VERSION"
    step "Linux CLIs on $HOST ($(git rev-parse --short HEAD))"
    ssh "$HOST" "rm -rf ~/$work && mkdir -p ~/$work"
    git archive HEAD | ssh "$HOST" "tar -x -C ~/$work"
    ssh "$HOST" "set -e; source ~/.cargo/env; export PATH=\$HOME/.local/bin:\$PATH CARGO_TARGET_DIR=~/$tgt
        cd ~/$work
        cargo zigbuild --release --locked -p frog --target x86_64-unknown-linux-gnu.2.36
        cargo zigbuild --release --locked -p frog --target aarch64-unknown-linux-gnu
        strip \$CARGO_TARGET_DIR/x86_64-unknown-linux-gnu/release/frog
        \$CARGO_TARGET_DIR/x86_64-unknown-linux-gnu/release/frog --version"
    local t
    for t in x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu; do
        mkdir -p "$DIST/bin/$t"
        scp -q "$HOST:$tgt/$t/release/frog" "$DIST/bin/$t/frog"
    done
    # Smoke the cloud asset on the sandbox base image, as release.yml's smoke-cloud did.
    if ssh "$HOST" "command -v docker >/dev/null && docker info >/dev/null 2>&1"; then
        step "Smoke on node:24-trixie-slim"
        ssh "$HOST" "docker run --rm --privileged -v ~/$tgt/x86_64-unknown-linux-gnu/release:/b:ro node:24-trixie-slim sh -euc '
            apt-get update -qq && apt-get install -y -qq --no-install-recommends bubblewrap >/dev/null
            /b/frog --version && bwrap --ro-bind / / --dev-bind /dev /dev /bin/sh -c :'"
    else
        print "warning: no docker on $HOST; skipped the trixie smoke"
    fi
    ssh "$HOST" "rm -rf ~/$work ~/$tgt"
}

build_macos() {
    step "macOS CLI on this Mac"
    rustup target add aarch64-apple-darwin >/dev/null
    CARGO_BUILD_JOBS=4 cargo build --release --locked -p frog --target aarch64-apple-darwin
    local bin="$DIST/bin/aarch64-apple-darwin/frog"
    mkdir -p "${bin:h}"; cp target/aarch64-apple-darwin/release/frog "$bin"; strip "$bin"
    if security find-identity -v -p codesigning | grep -q "$SIGN_ID"; then
        codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$bin"
        codesign --verify --strict --verbose=2 "$bin"
        # a bare binary can't be stapled; Gatekeeper checks the ticket online
        ditto -c -k "$bin" "$DIST/frog-notarize.zip"
        xcrun notarytool submit "$DIST/frog-notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait \
            | tee "$DIST/notary-cli.log"
        grep -q "status: Accepted" "$DIST/notary-cli.log" || fail "CLI notarization rejected"
        rm -f "$DIST/frog-notarize.zip"
    else
        print "warning: no \"$SIGN_ID\" certificate; the darwin CLI ships unsigned"
    fi
    "$bin" --version
}

build() {
    [[ -z $(git status --porcelain) ]] || fail "working tree isn't clean"
    rm -rf "$DIST"; mkdir -p "$DIST"
    build_linux
    build_macos
    step "Packaging"
    local t
    for t in x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu aarch64-apple-darwin; do
        package "$t" "$DIST/bin/$t/frog"
    done
    # Unversioned asset for the Frog Cloud sandbox image (zest fetches it by tag); frog at the root.
    tar -C "$DIST/bin/x86_64-unknown-linux-gnu" -czf "$DIST/frog-x86_64-unknown-linux-gnu.tar.gz" frog
    (cd "$DIST" && shasum -a 256 frog-x86_64-unknown-linux-gnu.tar.gz > frog-x86_64-unknown-linux-gnu.tar.gz.sha256)
    rm -rf "$DIST/bin"
    (cd "$DIST" && cat ./*.tar.gz.sha256 > SHA256SUMS)

    if [[ -n ${FROG_MINISIGN_KEY:-} ]]; then
        step "minisign"
        [[ -r $FROG_MINISIGN_KEY ]] || fail "FROG_MINISIGN_KEY ($FROG_MINISIGN_KEY) isn't readable"
        local f
        for f in "$DIST"/*.tar.gz; do
            minisign -S -s "$FROG_MINISIGN_KEY" -m "$f" -t "frog $TAG ${f:t}"
        done
    else
        print "warning: FROG_MINISIGN_KEY not set; tarballs are unsigned"
    fi

    if [[ $VERSION != *-* ]]; then
        step "Homebrew formula"
        sha() { cut -d' ' -f1 < "$DIST/frog-$TAG-$1.tar.gz.sha256" }
        sed -e "s/@VERSION@/$VERSION/" \
            -e "s/@SHA256_AARCH64_APPLE_DARWIN@/$(sha aarch64-apple-darwin)/" \
            -e "s/@SHA256_AARCH64_UNKNOWN_LINUX_GNU@/$(sha aarch64-unknown-linux-gnu)/" \
            -e "s/@SHA256_X86_64_UNKNOWN_LINUX_GNU@/$(sha x86_64-unknown-linux-gnu)/" \
            packaging/homebrew/frog.rb > "$DIST/frog.rb"
        ! grep -n '@[A-Z0-9_]*@' "$DIST/frog.rb" || fail "unfilled placeholder in frog.rb"
    fi
    step "Done: $DIST"; ls -1 "$DIST"
}

publish() {
    [[ -f $DIST/SHA256SUMS ]] || fail "nothing built in $DIST; run: $0 $VERSION build"
    [[ -f $NOTES ]] || fail "no release notes at $NOTES"
    local files=("$DIST"/*.tar.gz "$DIST"/*.sha256 "$DIST/SHA256SUMS")
    files+=("$DIST"/*.minisig(N) "$DIST"/frog.rb(N))
    local pre=(); [[ $VERSION == *-* ]] && pre=(--prerelease)
    if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
        step "Adding the CLI to the existing $TAG"
        gh release upload "$TAG" "${files[@]}" --repo "$REPO" --clobber
        gh release edit "$TAG" --repo "$REPO" --notes-file "$NOTES" "${pre[@]}"
    else
        step "Creating $TAG on $REPO"
        gh release create "$TAG" "${files[@]}" --repo "$REPO" --target "$(git rev-parse HEAD)" \
            --title "frog $VERSION" --notes-file "$NOTES" "${pre[@]}"
    fi
    step "Done: https://github.com/$REPO/releases/tag/$TAG"
}

case $CMD in
    build) build ;;
    publish) publish ;;
    *) fail "unknown command: $CMD (build|publish)" ;;
esac

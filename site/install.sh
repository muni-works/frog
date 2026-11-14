#!/bin/sh
# frog installer: curl -fsSL https://frog.toys/install.sh | sh
# env: FROG_VERSION (e.g. v0.1.0-rc1; default latest), FROG_INSTALL_DIR (default ~/.local/bin),
#      FROG_REQUIRE_SIGNATURE=1 (fail unless the minisign signature is present and verified)
set -eu

# Public GitHub repo. Change once the name is final.
FROG_REPO="${FROG_REPO:-muni-works/frog}"

# minisign public key for release signatures (the second line of minisign.pub, "RW...").
FROG_MINISIGN_PUBKEY="RWRxRLpWXDJlkcb7OZvuKFrMJn/XlofsgSMtRT9i8UUtQHmfT4xM+Dov"

err() { printf 'frog-install: error: %s\n' "$*" >&2; exit 1; }
info() { printf 'frog-install: %s\n' "$*"; }
need() { command -v "$1" >/dev/null 2>&1 || err "missing required command: $1"; }

detect_target() {
  os=$(uname -s)
  arch=$(uname -m)
  case "$os" in
    Darwin) os=apple-darwin ;;
    Linux) os=unknown-linux-gnu ;;
    *) err "unsupported OS: $os (supported: macOS, Linux)" ;;
  esac
  case "$arch" in
    arm64|aarch64) arch=aarch64 ;;
    x86_64|amd64) arch=x86_64 ;;
    *) err "unsupported architecture: $arch" ;;
  esac
  if [ "$os" = apple-darwin ] && [ "$arch" = x86_64 ]; then
    err "Intel macOS builds aren't published; build from source with cargo"
  fi
  printf '%s-%s\n' "$arch" "$os"
}

fetch() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$1" -o "$2" || err "download failed: $1"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$2" "$1" || err "download failed: $1"
  else
    err "need curl or wget"
  fi
}

resolve_version() {
  if [ -n "${FROG_VERSION:-}" ]; then
    case "$FROG_VERSION" in
      v*) printf '%s\n' "$FROG_VERSION" ;;
      *) printf 'v%s\n' "$FROG_VERSION" ;;
    esac
    return
  fi
  # Fetches the latest non-prerelease release (GitHub's releases/latest skips prereleases).
  # To install an rc, set FROG_VERSION (e.g. FROG_VERSION=v0.1.0-rc1).
  meta="$tmp/latest.json"
  fetch "https://api.github.com/repos/$FROG_REPO/releases/latest" "$meta"
  v=$(sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$meta" | head -n1)
  [ -n "$v" ] || err "couldn't determine latest release of $FROG_REPO"
  printf '%s\n' "$v"
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | cut -d' ' -f1
  else
    err "need sha256sum or shasum to verify the download"
  fi
}

# Returns 1 quietly when the URL isn't there (e.g. an unsigned release).
fetch_optional() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$1" -o "$2" 2>/dev/null
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$2" "$1" 2>/dev/null
  else
    return 1
  fi
}

# The checksum comes from the same host as the tarball; the signature proves who built it.
# When a release publishes a .minisig, it must verify: a mismatch is fatal, and so is a missing
# minisign when FROG_REQUIRE_SIGNATURE=1. Without minisign, the install goes ahead on the
# checksum alone, with a loud warning.
verify_signature() {
  [ -n "$FROG_MINISIGN_PUBKEY" ] || err "no minisign public key embedded in this installer"
  if ! fetch_optional "$2.minisig" "$1.minisig"; then
    [ "${FROG_REQUIRE_SIGNATURE:-}" = 1 ] && err "no signature published for $(basename "$1") and FROG_REQUIRE_SIGNATURE=1"
    info "warning: no signature published for $(basename "$1"); checksum only"
    return 0
  fi
  if ! command -v minisign >/dev/null 2>&1; then
    [ "${FROG_REQUIRE_SIGNATURE:-}" = 1 ] && err "minisign not installed and FROG_REQUIRE_SIGNATURE=1"
    printf '\nfrog-install: WARNING: %s is signed, but minisign is not installed, so the\n' "$(basename "$1")" >&2
    printf 'frog-install: WARNING: signature was NOT checked (checksum only). Install minisign\n' >&2
    printf 'frog-install: WARNING: (brew install minisign / apt install minisign) and rerun to verify.\n\n' >&2
    return 0
  fi
  minisign -Vqm "$1" -x "$1.minisig" -P "$FROG_MINISIGN_PUBKEY" \
    || err "signature verification failed for $(basename "$1"); not installing"
  info "signature verified"
}

main() {
  need uname
  need tar
  target=$(detect_target)
  dir="${FROG_INSTALL_DIR:-$HOME/.local/bin}"
  if [ "${FROG_INSTALL_DRY_RUN:-}" = 1 ]; then
    printf 'target=%s\ndir=%s\nrepo=%s\n' "$target" "$dir" "$FROG_REPO"
    exit 0
  fi

  tmp=$(mktemp -d 2>/dev/null || mktemp -d -t frog)
  trap 'rm -rf "$tmp"' EXIT INT TERM

  version=$(resolve_version)
  name="frog-$version-$target"
  base="https://github.com/$FROG_REPO/releases/download/$version"

  info "downloading $name"
  fetch "$base/$name.tar.gz" "$tmp/$name.tar.gz"
  fetch "$base/$name.tar.gz.sha256" "$tmp/$name.tar.gz.sha256"

  want=$(cut -d' ' -f1 < "$tmp/$name.tar.gz.sha256")
  got=$(sha256_of "$tmp/$name.tar.gz")
  if [ -z "$want" ] || [ "$want" != "$got" ]; then
    err "checksum mismatch for $name.tar.gz (want $want, got $got)"
  fi
  verify_signature "$tmp/$name.tar.gz" "$base/$name.tar.gz"

  tar -xzf "$tmp/$name.tar.gz" -C "$tmp" || err "failed to extract $name.tar.gz"
  [ -f "$tmp/$name/frog" ] || err "archive missing frog binary"

  mkdir -p "$dir" || err "can't create $dir"
  [ -w "$dir" ] || err "$dir isn't writable; set FROG_INSTALL_DIR to a directory you own"
  { cp "$tmp/$name/frog" "$dir/frog.tmp" && chmod 755 "$dir/frog.tmp" && mv "$dir/frog.tmp" "$dir/frog"; } \
    || err "failed to install to $dir"
  # Unsigned builds: curl sets no quarantine flag, but clear it anyway, and ad-hoc sign if
  # needed (Apple silicon won't run unsigned code). Signed builds pass codesign -v untouched.
  if [ "$(uname -s)" = Darwin ]; then
    xattr -d com.apple.quarantine "$dir/frog" 2>/dev/null || true
    codesign -v "$dir/frog" 2>/dev/null || codesign -s - -f "$dir/frog" 2>/dev/null || true
  fi
  info "installed frog $version to $dir/frog"

  case ":$PATH:" in
    *":$dir:"*) ;;
    *)
      info "$dir is not on your PATH. add this to your shell profile:"
      # shellcheck disable=SC2016
      printf '\n  export PATH="%s:$PATH"\n\n' "$dir"
      ;;
  esac
}

main "$@"

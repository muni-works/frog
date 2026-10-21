#!/bin/sh
# frog installer: curl -fsSL https://frog.toys/install.sh | sh
# env: FROG_VERSION (e.g. v0.1.0; default latest), FROG_INSTALL_DIR (default ~/.local/bin)
set -eu

# Public GitHub repo. Change once the name is final.
FROG_REPO="${FROG_REPO:-muni-works/frog}"

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

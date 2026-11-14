#!/bin/sh
# Make this Linux box a frog node: curl -fsSL https://frog.toys/node | sh
#
# Downloads tang-llm (CUDA build when nvidia-smi finds a GPU, else CPU), installs it to
# ~/.local/bin, runs `tang-llm serve --host 0.0.0.0` as a user systemd service so the box
# advertises itself on the local network, then opens a pairing window and prints the code.
# Re-running upgrades in place.
#
# Options (pass after `sh -s --`, e.g. `curl -fsSL https://frog.toys/node | sh -s -- --uninstall`):
#   --uninstall      stop and remove the service and binary (paired clients stay in tang's cache)
#   --system         install a system-wide service under /usr/local/bin (uses sudo)
#   --model M        preload model M (default: none; load models from the Mac app)
#   --port P         listen port (default 8911)
#   --cpu            use the CPU build even if there is an NVIDIA GPU
#   --no-pair        skip the pairing step at the end
#   --dry-run        print what would happen, change nothing
# Env: TANG_VERSION (tag, default latest), TANG_REPO (default muni-works/tang),
#      TANG_NODE_TARBALL (a local .tar.gz to install instead of downloading),
#      TANG_NODE_OS / TANG_NODE_ARCH (override uname, for tests)
set -eu

TANG_REPO="${TANG_REPO:-muni-works/tang}"
# minisign public key for tang release signatures (same signer as frog's releases).
TANG_MINISIGN_PUBKEY="${TANG_MINISIGN_PUBKEY:-RWRxRLpWXDJlkcb7OZvuKFrMJn/XlofsgSMtRT9i8UUtQHmfT4xM+Dov}"
UNIT=tang-node.service

err() { printf 'frog-node: error: %s\n' "$*" >&2; exit 1; }
info() { printf 'frog-node: %s\n' "$*"; }

dry=0 system=0 uninstall=0 cpu=0 pair=1 model="" port=8911
while [ $# -gt 0 ]; do
  case "$1" in
    --uninstall) uninstall=1 ;;
    --system) system=1 ;;
    --model) [ $# -ge 2 ] || err "--model needs a value"; model="$2"; shift ;;
    --port) [ $# -ge 2 ] || err "--port needs a value"; port="$2"; shift ;;
    --cpu) cpu=1 ;;
    --no-pair) pair=0 ;;
    --dry-run) dry=1 ;;
    -h|--help) sed -n '2,22p' "$0" 2>/dev/null || true; exit 0 ;;
    *) err "unknown option: $1" ;;
  esac
  shift
done
case "$port" in ''|*[!0-9]*) err "--port must be a number" ;; esac

# Every change goes through run: printed under --dry-run, executed otherwise.
run() {
  if [ "$dry" = 1 ]; then printf '[dry-run] %s\n' "$*"; return 0; fi
  "$@"
}
# Writes stdin to a file (as root under --system).
put() {
  if [ "$dry" = 1 ]; then printf '[dry-run] write %s:\n' "$1"; sed 's/^/  | /'; return 0; fi
  if [ "$system" = 1 ]; then sudo tee "$1" >/dev/null; else cat >"$1"; fi
}

[ "${TANG_NODE_OS:-$(uname -s)}" = Linux ] || err "this installer is for Linux; on a Mac, turn on Settings > Lend this Mac in the Frog app"

if [ "$system" = 1 ]; then
  bindir=/usr/local/bin
  unitdir=/etc/systemd/system
  sudo=sudo
  sctl() { run sudo systemctl "$@"; }
else
  bindir="$HOME/.local/bin"
  unitdir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
  sudo=""
  sctl() { run systemctl --user "$@"; }
fi
bin="$bindir/tang-llm"

if [ "$uninstall" = 1 ]; then
  if [ -f "$unitdir/$UNIT" ] || [ "$dry" = 1 ]; then
    sctl disable --now "$UNIT" || true
    run $sudo rm -f "$unitdir/$UNIT"
    sctl daemon-reload
  fi
  run $sudo rm -f "$bin"
  info "removed. Paired Macs will show this node as gone; un-pair them in the Frog app."
  exit 0
fi

# What to download: tang-llm-<arch>-unknown-linux-gnu[-cuda12].tar.gz
machine="${TANG_NODE_ARCH:-$(uname -m)}"
case "$machine" in
  x86_64|amd64) arch=x86_64 ;;
  aarch64|arm64) arch=aarch64 ;;
  *) err "unsupported architecture: $machine" ;;
esac
flavor=""
gpu="CPU"
if [ "$cpu" = 0 ] && command -v nvidia-smi >/dev/null 2>&1; then
  name=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -n1 || true)
  if [ -n "$name" ]; then flavor="-cuda12"; gpu="$name"; fi
fi
asset="tang-llm-$arch-unknown-linux-gnu$flavor.tar.gz"
if [ -n "${TANG_VERSION:-}" ]; then
  base="https://github.com/$TANG_REPO/releases/download/$TANG_VERSION"
else
  base="https://github.com/$TANG_REPO/releases/latest/download"
fi
info "this box: $arch, $gpu"

fetch() {
  if command -v curl >/dev/null 2>&1; then curl -fsSL "$1" -o "$2"
  elif command -v wget >/dev/null 2>&1; then wget -qO "$2" "$1"
  else err "need curl or wget"; fi
}
sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

if [ -n "${TANG_NODE_TARBALL:-}" ]; then
  info "installing $TANG_NODE_TARBALL"
  cp "$TANG_NODE_TARBALL" "$tmp/$asset"
elif [ "$dry" = 1 ]; then
  printf '[dry-run] download %s/%s (+ .sha256)\n' "$base" "$asset"
else
  info "downloading $asset"
  fetch "$base/$asset" "$tmp/$asset" || err "download failed: $base/$asset (no build for this box yet?)"
  fetch "$base/$asset.sha256" "$tmp/sum" || err "download failed: $base/$asset.sha256"
  want=$(cut -d' ' -f1 <"$tmp/sum")
  [ "$(sha256 "$tmp/$asset")" = "$want" ] || err "checksum mismatch for $asset"
  # A published .minisig must verify; a mismatch is fatal. No minisign: loud warning, or fatal
  # with TANG_REQUIRE_SIGNATURE=1.
  if fetch "$base/$asset.minisig" "$tmp/$asset.minisig" 2>/dev/null; then
    if command -v minisign >/dev/null 2>&1; then
      minisign -Vqm "$tmp/$asset" -x "$tmp/$asset.minisig" -P "$TANG_MINISIGN_PUBKEY" \
        || err "signature verification failed for $asset; not installing"
      info "signature verified"
    elif [ "${TANG_REQUIRE_SIGNATURE:-}" = 1 ]; then
      err "minisign not installed and TANG_REQUIRE_SIGNATURE=1"
    else
      printf '\nWARNING: %s is signed, but minisign is not installed, so the signature was\nWARNING: NOT checked (checksum only). Install minisign and rerun to verify.\n\n' "$asset" >&2
    fi
  elif [ "${TANG_REQUIRE_SIGNATURE:-}" = 1 ]; then
    err "no signature published for $asset and TANG_REQUIRE_SIGNATURE=1"
  else
    info "warning: no signature published for $asset; checksum only"
  fi
fi

if [ "$dry" = 0 ]; then
  tar -xzf "$tmp/$asset" -C "$tmp"
  [ -f "$tmp/tang-llm" ] || err "$asset has no tang-llm inside"
fi
run $sudo mkdir -p "$bindir" "$unitdir"
# Replace through a temp name so a running service keeps its old inode until restart.
run $sudo install -m 0755 "$tmp/tang-llm" "$bin.new"
run $sudo mv -f "$bin.new" "$bin"

args="serve"
[ -n "$model" ] && args="$args $model"
args="$args --host 0.0.0.0 --port $port"
if [ "$system" = 1 ]; then
  user_line="User=$(id -un)
"
  wanted=multi-user.target
else
  user_line=""
  wanted=default.target
fi
put "$unitdir/$UNIT" <<EOF
[Unit]
Description=frog node (tang-llm serve)
After=network-online.target
Wants=network-online.target

[Service]
${user_line}ExecStart=$bin $args
Restart=on-failure
RestartSec=5
Nice=5

[Install]
WantedBy=$wanted
EOF

sctl daemon-reload
sctl enable "$UNIT"
sctl restart "$UNIT"

if [ "$system" = 0 ] && command -v loginctl >/dev/null 2>&1; then
  linger=$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null || echo unknown)
  if [ "$linger" = no ]; then
    info "the node stops when you log out. To keep it running: sudo loginctl enable-linger $(id -un)"
  fi
fi

case ":$PATH:" in *":$bindir:"*) ;; *) info "note: $bindir is not on your PATH" ;; esac

if [ "$system" = 1 ]; then logs="journalctl -u $UNIT"; else logs="journalctl --user -u $UNIT"; fi
if [ "$dry" = 0 ]; then
  # Wait for the server to answer before opening a pairing window.
  i=0
  until fetch "http://127.0.0.1:$port/health" "$tmp/health" 2>/dev/null; do
    i=$((i + 1))
    [ "$i" -lt 30 ] || err "tang-llm didn't start; see: $logs"
    sleep 1
  done
fi
info "running: tang-llm on port $port, advertising on the local network"

if [ "$pair" = 1 ]; then
  # `tang-llm pair` talks to the server on loopback (POST /pair/open) and prints the code.
  if [ "$port" = 8911 ]; then run "$bin" pair; else run "$bin" pair --port "$port"; fi
  info "on your Mac: Frog > Devices, pick this box, and type the code above."
else
  info "to pair later: tang-llm pair"
fi

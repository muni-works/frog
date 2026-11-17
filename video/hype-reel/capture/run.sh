#!/bin/zsh
# Recapture the reel's web footage: the reel gateway, vite dev against it, then capture.mjs in
# headless Chrome. Nothing opens a window. Needs `npm ci` in apps/web and Google Chrome.
#
#   video/hype-reel/capture/run.sh            # every shot, into video/hype-reel/footage/
#   video/hype-reel/capture/run.sh probe      # one still of / and the live session
set -euo pipefail
HERE=${0:A:h}
ROOT=${HERE:h:h:h}
GW_PORT=${REEL_GW_PORT:-8811}
VITE_PORT=${REEL_VITE_PORT:-5211}
LOG=$(mktemp -d -t frog-reel)
pids=()
trap 'for p in $pids; do kill $p 2>/dev/null || true; done' EXIT

node "$HERE/gateway.mjs" --port $GW_PORT > "$LOG/gateway.log" 2>&1 & pids+=($!)
cd "$ROOT/apps/web"
# VITE_API is the page's own origin, so /v1/me and /v1/models go through the same proxy. No
# VITE_DEV_KEY: capture.mjs seeds a key instead, so the app loads the account like a signed-in one.
GATEWAY=http://127.0.0.1:$GW_PORT VITE_API=http://127.0.0.1:$VITE_PORT \
  npx vite --host 127.0.0.1 --port $VITE_PORT --strictPort > "$LOG/vite.log" 2>&1 & pids+=($!)
for i in {1..60}; do curl -sf "http://127.0.0.1:$VITE_PORT/" >/dev/null && break; sleep 0.5; done
curl -sf "http://127.0.0.1:$VITE_PORT/" >/dev/null || { print -u2 "vite didn't start:"; cat "$LOG/vite.log" >&2; exit 1; }
REEL_WEB=http://127.0.0.1:$VITE_PORT REEL_GW=http://127.0.0.1:$GW_PORT node "$HERE/capture.mjs" "${1:-all}"
# The mark, for the open and the end card.
rsvg-convert -w 1200 "$ROOT/apps/web/public/frog-mark.svg" -o "$ROOT/video/hype-reel/footage/mark.png"

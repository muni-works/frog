#!/bin/sh
# Composer tray parity: every state in composer-states.json, Mac and web, dark and light, into
# composer/ (see composer.html). Mac: FrogTests/ComposerParityTests draws the tray's parts.
# Web: vite serves apps/web/parity/composer.html and web-shot.mjs captures it.
#   PARITY_SKIP_MAC=1 / PARITY_SKIP_WEB=1 skip a side; FROG_PREBUILT_DIR as in capture.sh.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/../../.."
OUT="$HERE/composer"
mkdir -p "$OUT"
STATES=$(node -e 'console.log(require(process.argv[1]).states.map(s=>s.name).join(" "))' "$HERE/composer-states.json")

if [ -z "$PARITY_SKIP_MAC" ]; then
  (cd "$ROOT/apps/macos" && xcodegen generate -q &&
    TEST_RUNNER_FROG_PARITY_OUT="$OUT" xcodebuild -project Frog.xcodeproj -scheme Frog -destination 'platform=macOS' \
      ${DERIVED:+-derivedDataPath "$DERIVED"} test -only-testing:FrogTests/ComposerParityTests -quiet)
fi

if [ -z "$PARITY_SKIP_WEB" ]; then
  PORT=${PORT:-5181}
  (cd "$ROOT/apps/web" && npx vite --port "$PORT" --strictPort >/dev/null 2>&1) &
  VITE=$!
  trap 'kill $VITE 2>/dev/null' EXIT
  sleep 4
  for s in $STATES; do
    h=210; [ "$s" = stack ] && h=360
    for look in dark light; do
      WEB_SHOT_WAIT=2500 node "$HERE/web-shot.mjs" "http://localhost:$PORT/parity/composer.html?state=$s&theme=$look" \
        "$OUT/composer-$s-web-$look.png" 720 $h $look
    done
  done
fi

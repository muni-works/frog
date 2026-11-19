#!/bin/zsh
# Chrome parity: the parity fixture (../../parity/fixture.mjs) in the Mac app and the web app at
# 1280 × 800, each writing where its window chrome's controls stand (frog-chrome-metrics/1) and a
# picture of the window, then diff-chrome.mjs compares the two.
#
#   docs/design/chrome/parity/capture.sh            # dark
#   LOOKS="dark light" docs/design/chrome/parity/capture.sh
#   PARITY_SKIP_BUILD=1 (use the built parity app) PARITY_SKIP_MAC=1 / PARITY_SKIP_WEB=1
#   OUT=before (a name for this run's files: <app>-<look>-<OUT>.json/png; default "now")
#   INSPECTOR=1 opens the inspector in both apps (-FrogInspector / frog.inspector): the on state
#
# Writes mac-<look>-<OUT>.{json,png}, web-<look>-<OUT>.{json,png} and diff-<look>-<OUT>.json here.
# Same needs as ../../parity/capture.sh: Xcode + xcodegen, npm deps in apps/web, Google Chrome.
# The Mac app is launched from its binary (never activated) and parked off-screen.
set -euo pipefail
HERE=${0:A:h}
ROOT=${HERE:h:h:h:h}
PARITY=$ROOT/docs/design/parity
MAC=$ROOT/apps/macos
WEB=$ROOT/apps/web
ID=toys.frog.parity
PORT=${PARITY_PORT:-8798}
VITE_PORT=${PARITY_VITE_PORT:-5198}
LOOKS=(${=LOOKS:-dark})
OUT=${OUT:-now}
SIZE=1280x800
WORK=$(mktemp -d -t frog-chrome)
pids=()
trap 'for p in $pids; do kill $p 2>/dev/null || true; done; rm -rf "$WORK"' EXIT
APP=${PARITY_APP:-$MAC/build/parity/Build/Products/Debug/Frog.app}

if [[ -z ${PARITY_SKIP_MAC:-} ]]; then
if [[ -z ${PARITY_SKIP_BUILD:-} ]]; then
    (cd "$MAC" && xcodegen generate --quiet && xcodebuild build -quiet -jobs 4 -project Frog.xcodeproj -scheme Frog \
        -configuration Debug -derivedDataPath build/parity -destination 'generic/platform=macOS' PRODUCT_BUNDLE_IDENTIFIER=$ID)
fi
for look in $LOOKS; do
    home="$WORK/home-$look"
    mkdir -p "$home/code/lilypad/src" "$home/.local/share/frog/sessions"
    node "$PARITY/fixture.mjs" "$home/code/lilypad" > "$home/parity.jsonl"
    cp "$home/parity.jsonl" "$home/.local/share/frog/sessions/20261111-120000-parity.jsonl"
    rm -rf ~/Library/Saved\ Application\ State/$ID.savedState
    style=(-NSRequiresAquaSystemAppearance YES); [[ $look == dark ]] && style=(-AppleInterfaceStyle Dark)
    rm -f "$HERE/mac-$look-$OUT.json" "$HERE/mac-$look-$OUT.png"
    HOME="$home" "$APP/Contents/MacOS/Frog" -FrogFolder "$home/code/lilypad" -FrogReplay "$home/parity.jsonl" \
        -FrogReplaySpeed 4 -FrogSnapshotSize $SIZE -FrogOffscreen YES \
        ${=INSPECTOR:+-FrogInspector YES} -FrogChromeMetrics "$HERE/mac-$look-$OUT.json" -FrogSnapshot "$HERE/mac-$look-$OUT.png" -FrogSnapshotDelay ${PARITY_MAC_WAIT:-14} \
        -ApplePersistenceIgnoreState YES -importedLegacyDefaults YES -autoArchiveChats NO -archivedSessions "()" \
        -NSAppSleepDisabled YES -remoteEnabled NO -density comfortable -verbosity normal -showEnergy NO -verbosityBySession "{}" \
        $style >/dev/null 2>"$WORK/mac-$look.log" || true
    [[ -s $HERE/mac-$look-$OUT.json ]] || { print -u2 "capture.sh: the Mac app didn't write mac-$look-$OUT.json"; tail -20 "$WORK/mac-$look.log" >&2; exit 1; }
done
fi

if [[ -z ${PARITY_SKIP_WEB:-} ]]; then
node "$PARITY/gateway.mjs" --port $PORT > "$WORK/gateway.log" 2>&1 & pids+=($!)
cd "$WEB"
GATEWAY=http://127.0.0.1:$PORT VITE_DEV_KEY=parity VITE_API= npx vite --host 127.0.0.1 --port $VITE_PORT --strictPort > "$WORK/vite.log" 2>&1 & pids+=($!)
for i in {1..60}; do curl -sf "http://127.0.0.1:$VITE_PORT/" >/dev/null && break; sleep 0.5; done
curl -sf "http://127.0.0.1:$VITE_PORT/" >/dev/null || { print -u2 "capture.sh: vite didn't start:"; cat "$WORK/vite.log" >&2; exit 1; }
W=${SIZE%x*} H=${SIZE#*x}
for look in $LOOKS; do
    storage='{}'; [[ -n ${INSPECTOR:-} ]] && storage='{"frog.inspector":"1","frog.inspectorTab":"changes"}'
    METRICS_STORAGE=$storage node "$HERE/chrome-metrics.mjs" "http://127.0.0.1:$VITE_PORT/s/s_parity" "$HERE/web-$look-$OUT.json" $W $H $look
    WEB_SHOT_STORAGE=$storage node "$PARITY/web-shot.mjs" "http://127.0.0.1:$VITE_PORT/s/s_parity" "$HERE/web-$look-$OUT.png" $W $H $look >/dev/null
done
fi

rc=0
for look in $LOOKS; do
    # Where each icon's ink is inside its button (and the title's), from the pictures.
    for app in mac web; do
        [[ -f $HERE/$app-$look-$OUT.json && -f $HERE/$app-$look-$OUT.png ]] && swift "$HERE/ink.swift" "$HERE/$app-$look-$OUT.png" "$HERE/$app-$look-$OUT.json"
    done
    [[ -f $HERE/web-$look-$OUT.json && -f $HERE/mac-$look-$OUT.json ]] || continue
    node "$HERE/diff-chrome.mjs" "$HERE/web-$look-$OUT.json" "$HERE/mac-$look-$OUT.json" --json "$HERE/diff-$look-$OUT.json" || rc=1
done
exit $rc

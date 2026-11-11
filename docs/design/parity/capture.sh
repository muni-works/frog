#!/bin/zsh
# The parity harness: the same fixture session (fixture.mjs) in the Mac app and the web app, at the
# same size, in dark and light, side by side in docs/design/parity/index.html.
#
#   docs/design/parity/capture.sh            # both looks
#   LOOKS=dark docs/design/parity/capture.sh # just one
#
# Needs: Xcode + xcodegen, npm deps in apps/web, Google Chrome, and Screen Recording permission for
# the terminal running it. It builds its own copy of the app (toys.frog.parity) with a throwaway
# HOME, and the engine binaries from a scratch copy of /Applications/Frog.app's (FROG_PREBUILT_DIR,
# or set it yourself), never the bundle it builds.
set -euo pipefail

HERE=${0:A:h}
ROOT=${HERE:h:h:h}
MAC=$ROOT/apps/macos
WEB=$ROOT/apps/web
ID=toys.frog.parity
PORT=${PARITY_PORT:-8799}
VITE_PORT=${PARITY_VITE_PORT:-5199}
LOOKS=(${=LOOKS:-dark light})
WORK=$(mktemp -d -t frog-parity)
pids=()
trap 'for p in $pids; do kill $p 2>/dev/null || true; done; rm -rf "$WORK"' EXIT

if [[ -z ${FROG_PREBUILT_DIR:-} ]]; then
    mkdir -p "$WORK/prebuilt"
    cp -R /Applications/Frog.app/Contents/Resources/frog* "$WORK/prebuilt/"
    export FROG_PREBUILT_DIR=$WORK/prebuilt
fi

if [[ -z ${PARITY_SKIP_MAC:-} ]]; then
# --- Mac ---------------------------------------------------------------------------------------
cd "$MAC"
xcodegen generate --quiet
xcodebuild build -quiet -jobs 4 -project Frog.xcodeproj -scheme Frog -configuration Debug \
    -derivedDataPath build/parity -destination 'generic/platform=macOS' PRODUCT_BUNDLE_IDENTIFIER=$ID
APP="$MAC/build/parity/Build/Products/Debug/Frog.app"

# hero-shot.sh's window finder: `winid park` moves the pointer away, `winid <pid>` prints the
# main window's id.
sed -n "/^cat > \"\$WORK\/winid.swift\" <<'EOF'$/,/^EOF$/p" "$MAC/scripts/hero-shot.sh" | sed '1d;$d' > "$WORK/winid.swift"
swiftc -O -o "$WORK/winid" "$WORK/winid.swift"

mac_shot() {
    local look=$1 home="$WORK/home-$1"
    mkdir -p "$home/code/lilypad/src"
    print '// Exponential backoff with jitter.' > "$home/code/lilypad/src/retry.rs"
    node "$HERE/fixture.mjs" "$home/code/lilypad" > "$home/parity.jsonl"
    defaults delete $ID >/dev/null 2>&1 || true
    rm -rf ~/Library/Saved\ Application\ State/$ID.savedState
    local style=(-NSRequiresAquaSystemAppearance YES); [[ $look == dark ]] && style=(-AppleInterfaceStyle Dark)
    "$WORK/winid" park
    HOME="$home" "$APP/Contents/MacOS/Frog" -FrogFolder "$home/code/lilypad" -FrogReplay "$home/parity.jsonl" \
        -FrogReplaySpeed 2 -ApplePersistenceIgnoreState YES -importedLegacyDefaults YES $style >/dev/null 2>&1 &
    local pid=$!
    sleep ${PARITY_MAC_WAIT:-12}
    "$WORK/winid" park
    screencapture -o -l$("$WORK/winid" $pid) -x "$HERE/mac-$look.png" || {
        print -u2 "capture.sh: screencapture failed; give this terminal Screen Recording permission"
        print -u2 "(System Settings → Privacy & Security), or run with PARITY_SKIP_MAC=1 for the web half."
        kill $pid; exit 1
    }
    kill $pid; wait $pid 2>/dev/null || true
}
for look in $LOOKS; do mac_shot $look; done
fi

# The web shoots at the Mac window's size, in points (or 1280×800 with no Mac shot yet).
first=$HERE/mac-${LOOKS[1]}.png
W=1280 H=800
if [[ -f $first ]]; then
    W=$(( $(sips -g pixelWidth "$first" | awk '/pixelWidth/ {print $2}') / 2 ))
    H=$(( $(sips -g pixelHeight "$first" | awk '/pixelHeight/ {print $2}') / 2 ))
fi

# --- Web ---------------------------------------------------------------------------------------
node "$HERE/gateway.mjs" --port $PORT > "$WORK/gateway.log" 2>&1 & pids+=($!)
cd "$WEB"
GATEWAY=http://127.0.0.1:$PORT VITE_DEV_KEY=parity npx vite --host 127.0.0.1 --port $VITE_PORT --strictPort > "$WORK/vite.log" 2>&1 & pids+=($!)
for i in {1..60}; do curl -sf "http://127.0.0.1:$VITE_PORT/" >/dev/null && break; sleep 0.5; done
curl -sf "http://127.0.0.1:$VITE_PORT/" >/dev/null || { print -u2 "capture.sh: vite didn't start:"; cat "$WORK/vite.log" >&2; exit 1; }
for look in $LOOKS; do
    node "$HERE/web-shot.mjs" "http://127.0.0.1:$VITE_PORT/s/s_parity" "$HERE/web-$look.png" $W $H $look >/dev/null
done

# --- Side by side ------------------------------------------------------------------------------
{
    print "<!doctype html><meta charset=utf-8><title>Frog parity</title>"
    print "<style>body{margin:0;padding:24px;background:#222;color:#ddd;font:13px -apple-system,sans-serif}"
    print "h2{font-weight:600;margin:28px 0 10px}.row{display:flex;gap:16px}figure{margin:0;flex:1;min-width:0}"
    print "img{width:100%;display:block;border-radius:10px}figcaption{margin:6px 0;color:#999}</style>"
    print "<h1>Frog parity: one fixture, Mac and web</h1>"
    print "<p>${W}×${H} pt, captured $(date '+%Y-%m-%d %H:%M') at $(git -C "$ROOT" rev-parse --short HEAD) by <code>docs/design/parity/capture.sh</code>. Spec: docs/design/frog-web/README.md, “One look”.</p>"
    for look in $LOOKS; do
        print "<h2>${(C)look}</h2><div class=row>"
        if [[ -f $HERE/mac-$look.png ]]; then print "<figure><figcaption>Mac</figcaption><img src=mac-$look.png></figure>"
        else print "<figure><figcaption>Mac: not captured yet (run capture.sh with Screen Recording permission)</figcaption></figure>"; fi
        print "<figure><figcaption>Web</figcaption><img src=web-$look.png></figure></div>"
    done
} > "$HERE/index.html"
print "$HERE/index.html"

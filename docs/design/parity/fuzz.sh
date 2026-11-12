#!/bin/zsh
# The parity fuzz: every case in fuzz/cases.mjs, played in the Mac app and the web app at the same
# size, in dark, light and a narrow dark window, side by side in fuzz/index.html.
#
#   docs/design/parity/fuzz.sh                       # every case, every variant
#   CASES="images thoughts" docs/design/parity/fuzz.sh
#   VARIANTS=dark OUT=/tmp/shots docs/design/parity/fuzz.sh
#
# Needs what capture.sh needs (Xcode + xcodegen, npm deps in apps/web, Google Chrome). Shots land
# in $OUT (default fuzz/shots) as <case>-<mac|web>-<variant>.png at 1×, so the repo stays small.
set -euo pipefail

HERE=${0:A:h}
ROOT=${HERE:h:h:h}
MAC=$ROOT/apps/macos
WEB=$ROOT/apps/web
ID=toys.frog.parity
PORT=${PARITY_PORT:-8799}
VITE_PORT=${PARITY_VITE_PORT:-5199}
CASES=(${=CASES:-$(node "$HERE/fuzz/cases.mjs" --list)})
VARIANTS=(${=VARIANTS:-dark light narrow})
OUT=${OUT:-$HERE/fuzz/shots}
W=1100 H=760 NARROW=680
WORK=$(mktemp -d -t frog-fuzz)
pids=()
trap 'for p in $pids; do kill $p 2>/dev/null || true; done; rm -rf "$WORK"' EXIT
mkdir -p "$OUT"

if [[ -z ${FROG_PREBUILT_DIR:-} ]]; then
    mkdir -p "$WORK/prebuilt"
    cp -R /Applications/Frog.app/Contents/Resources/frog* "$WORK/prebuilt/"
    export FROG_PREBUILT_DIR=$WORK/prebuilt
fi

look_of() { [[ $1 == light ]] && print light || print dark; }
size_of() { [[ $1 == narrow ]] && print "${NARROW}x$H" || print "${W}x$H"; }
# 2× captures down to 1×: the shots are for eyes and diffs, not print.
shrink() { sips -Z $(( $(sips -g pixelWidth "$1" | awk '/pixelWidth/ {print $2}') / 2 )) "$1" >/dev/null; }

if [[ -z ${PARITY_SKIP_MAC:-} ]]; then
# --- Mac ---------------------------------------------------------------------------------------
cd "$MAC"
xcodegen generate --quiet
xcodebuild build -quiet -jobs 4 -project Frog.xcodeproj -scheme Frog -configuration Debug \
    -derivedDataPath build/parity -destination 'generic/platform=macOS' PRODUCT_BUNDLE_IDENTIFIER=$ID
APP="$MAC/build/parity/Build/Products/Debug/Frog.app"

for c in $CASES; do
    for v in $VARIANTS; do
        home="$WORK/home-$c-$v" look=$(look_of $v)
        mkdir -p "$home/code/lilypad" "$home/.local/share/frog/sessions"
        node "$HERE/fuzz/cases.mjs" $c "$home/code/lilypad" > "$home/case.jsonl"
        cp "$home/case.jsonl" "$home/.local/share/frog/sessions/20261112-120000-$c.jsonl"
        defaults delete $ID >/dev/null 2>&1 || true
        rm -rf ~/Library/Saved\ Application\ State/$ID.savedState
        style=(-NSRequiresAquaSystemAppearance YES); [[ $look == dark ]] && style=(-AppleInterfaceStyle Dark)
        shot="$OUT/$c-mac-$v.png"; rm -f "$shot"
        HOME="$home" "$APP/Contents/MacOS/Frog" -FrogFolder "$home/code/lilypad" -FrogReplay "$home/case.jsonl" \
            -FrogReplaySpeed 8 -FrogSnapshot "$shot" -FrogSnapshotSize $(size_of $v) \
            -FrogSnapshotDelay $(node "$HERE/fuzz/cases.mjs" --wait $c) \
            -ApplePersistenceIgnoreState YES -importedLegacyDefaults YES -autoArchiveChats NO -archivedSessions "()" $style >/dev/null 2>&1 || true
        if [[ -s $shot ]]; then shrink "$shot"; print "mac $c $v"; else print -u2 "fuzz.sh: no Mac shot for $c $v"; fi
    done
done
fi

if [[ -n ${PARITY_SKIP_WEB:-} ]]; then exit 0; fi
# --- Web ---------------------------------------------------------------------------------------
cd "$WEB"
GATEWAY=http://127.0.0.1:$PORT VITE_DEV_KEY=parity npx vite --host 127.0.0.1 --port $VITE_PORT --strictPort > "$WORK/vite.log" 2>&1 & pids+=($!)
for i in {1..60}; do curl -sf "http://127.0.0.1:$VITE_PORT/" >/dev/null && break; sleep 0.5; done
curl -sf "http://127.0.0.1:$VITE_PORT/" >/dev/null || { print -u2 "fuzz.sh: vite didn't start:"; cat "$WORK/vite.log" >&2; exit 1; }
for c in $CASES; do
    node "$HERE/fuzz/cases.mjs" $c /tmp/lilypad > "$WORK/$c.jsonl"
    node "$HERE/gateway.mjs" --port $PORT --fixture "$WORK/$c.jsonl" --title "$c" > "$WORK/gateway.log" 2>&1 & gw=$!
    for i in {1..20}; do curl -sf "http://127.0.0.1:$PORT/v1/sessions" >/dev/null && break; sleep 0.25; done
    for v in $VARIANTS; do
        sz=$(size_of $v)
        WEB_SHOT_WAIT=${WEB_SHOT_WAIT:-4000} node "$HERE/web-shot.mjs" "http://127.0.0.1:$VITE_PORT/s/s_parity" "$OUT/$c-web-$v.png" ${sz%x*} ${sz#*x} $(look_of $v) >/dev/null
        shrink "$OUT/$c-web-$v.png"; print "web $c $v"
    done
    kill $gw 2>/dev/null || true; wait $gw 2>/dev/null || true
done

# --- Side by side ------------------------------------------------------------------------------
{
    print "<!doctype html><meta charset=utf-8><title>Frog parity fuzz</title>"
    print "<style>body{margin:0;padding:24px;background:#222;color:#ddd;font:13px -apple-system,sans-serif}"
    print "h2{font-weight:600;margin:32px 0 6px}h3{font-weight:500;color:#aaa;margin:14px 0 6px}.row{display:flex;gap:16px;align-items:flex-start}figure{margin:0;flex:1;min-width:0}"
    print "img{max-width:100%;display:block;border-radius:8px}figcaption{margin:6px 0;color:#999}</style>"
    print "<h1>Frog parity fuzz</h1>"
    print "<p>Cases from <code>fuzz/cases.mjs</code>, ${W}×${H} pt (narrow ${NARROW}), captured $(date '+%Y-%m-%d %H:%M') at $(git -C "$ROOT" rev-parse --short HEAD) by <code>docs/design/parity/fuzz.sh</code>.</p>"
    for c in $CASES; do
        print "<h2 id=$c>$c</h2>"
        for v in $VARIANTS; do
            print "<h3>$v</h3><div class=row><figure><figcaption>Mac</figcaption><img src=shots/$c-mac-$v.png></figure><figure><figcaption>Web</figcaption><img src=shots/$c-web-$v.png></figure></div>"
        done
    done
} > "$HERE/fuzz/index.html"
print "$HERE/fuzz/index.html"

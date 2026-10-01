#!/bin/zsh
# frog.eco's hero screenshots: the real app, replaying scripts/hero_fixture.py's session, captured
# with its window shadow in light and dark, into site/public/shot-{light,dark}.png.
#
#   apps/macos/scripts/hero-shot.sh
#
# It builds its own copy of the app (eco.frog.shot) with a throwaway HOME, so the window starts at
# its default size and the sidebar holds only the fixture's invented sessions, never yours.
# The terminal running it needs Screen Recording permission.
set -euo pipefail

HERE=${0:A:h}
APP_DIR=${HERE:h}
ROOT=${APP_DIR:h:h}
ID=eco.frog.shot
WORK=$(mktemp -d -t frog-shot)
trap 'rm -rf "$WORK"' EXIT

cd "$APP_DIR"
xcodegen generate --quiet
xcodebuild build -quiet -project Frog.xcodeproj -scheme Frog -configuration Debug \
    -derivedDataPath build/shot -destination 'generic/platform=macOS' PRODUCT_BUNDLE_IDENTIFIER=$ID
APP="$APP_DIR/build/shot/Build/Products/Debug/Frog.app"

# The id of the app's main window (layer 0, largest), from CoreGraphics.
cat > "$WORK/winid.swift" <<'EOF'
import CoreGraphics
import Foundation
// `winid park` moves the pointer to the screen's corner, so no hover state shows in the shot.
if CommandLine.arguments[1] == "park" {
    CGWarpMouseCursorPosition(CGPoint(x: 0, y: CGDisplayBounds(CGMainDisplayID()).height - 1))
    exit(0)
}
let pid = Int32(CommandLine.arguments[1])!
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
let area = { (w: [String: Any]) -> CGFloat in
    let b = w[kCGWindowBounds as String] as! [String: CGFloat]
    return b["Width"]! * b["Height"]!
}
let best = list.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
    .max { area($0) < area($1) }
guard let id = best?[kCGWindowNumber as String] as? Int else { exit(1) }
print(id)
EOF
swiftc -O -o "$WORK/winid" "$WORK/winid.swift"

shoot() {
    local look=$1 out=$2 home="$WORK/home-$1"
    mkdir -p "$home"
    local fixture=$(python3 "$HERE/hero_fixture.py" "$home")
    defaults delete $ID >/dev/null 2>&1 || true
    rm -rf ~/Library/Saved\ Application\ State/$ID.savedState
    # Dark, or Aqua whatever the system is set to. Skip the one-time import of old kiln
    # preferences, which would bring back a window size and archive list from this Mac.
    local style=(-NSRequiresAquaSystemAppearance YES); [[ $look == dark ]] && style=(-AppleInterfaceStyle Dark)
    "$WORK/winid" park
    HOME="$home" "$APP/Contents/MacOS/Frog" -FrogFolder "$home/code/lilypad" -FrogReplay "$fixture" \
        -FrogReplaySpeed 1 -ApplePersistenceIgnoreState YES -importedLegacyDefaults YES $style >/dev/null 2>&1 &
    local pid=$!
    # The replay runs in real time so the header reads a true duration; then let it settle.
    sleep ${FROG_SHOT_WAIT:-24}
    "$WORK/winid" park
    local win=$("$WORK/winid" $pid)
    screencapture -l$win -x "$out"
    kill $pid; wait $pid 2>/dev/null || true
    print "$out"
}

# One at a time: a second copy with the same bundle id would hand its folder to the first.
shoot light "$ROOT/site/public/shot-light.png"
shoot dark "$ROOT/site/public/shot-dark.png"

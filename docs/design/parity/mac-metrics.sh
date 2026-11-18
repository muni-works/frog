#!/bin/zsh
# The Mac's parity metrics: replays fixture.jsonl in the Mac app at the web's size and writes
# frog-transcript-metrics/1 (README.md, "Metrics"), then diffs it against the web's dump.
#
#   docs/design/parity/mac-metrics.sh [out.json] [WxH] [look] [web.json]
#   defaults: docs/design/transcript/metrics/mac-1280.json 1280x800 dark metrics/web-1280.json
#
# Needs a built parity app (capture.sh builds it; or PARITY_APP=…/Frog.app) whose engine
# replays with the log's own times and carries `tests` (FROG_PREBUILT_DIR at build time).
# Headless: launched straight from the binary, which doesn't activate it, and `-FrogOffscreen`
# (drawn off-screen).
set -euo pipefail
HERE=${0:A:h}
ROOT=${HERE:h:h:h}
OUT=${1:-$ROOT/docs/design/transcript/metrics/mac-1280.json}
SIZE=${2:-1280x800}
LOOK=${3:-dark}
WEB=${4:-$ROOT/docs/design/transcript/metrics/web-1280.json}
APP=${PARITY_APP:-$ROOT/apps/macos/build/parity/Build/Products/Debug/Frog.app}
ID=toys.frog.parity
WORK=$(mktemp -d -t frog-metrics)
trap 'rm -rf "$WORK"' EXIT

home="$WORK/home"
mkdir -p "$home/code/lilypad/src" "$home/.local/share/frog/sessions"
node "$HERE/fixture.mjs" "$home/code/lilypad" > "$home/parity.jsonl"
cp "$home/parity.jsonl" "$home/.local/share/frog/sessions/20261111-120000-parity.jsonl"
rm -rf ~/Library/Saved\ Application\ State/$ID.savedState
style=(-NSRequiresAquaSystemAppearance YES); [[ $LOOK == dark ]] && style=(-AppleInterfaceStyle Dark)
rm -f "$OUT"
shot=(); [[ -n ${PARITY_PNG:-} ]] && shot=(-FrogSnapshot "$PARITY_PNG")
HOME="$home" "$APP/Contents/MacOS/Frog" -FrogFolder "$home/code/lilypad" -FrogReplay "$home/parity.jsonl" \
    -FrogReplaySpeed 4 -FrogSnapshotSize "$SIZE" -FrogOffscreen ${PARITY_OFFSCREEN:-YES} -FrogMetrics "$OUT" $shot \
    -FrogSnapshotDelay ${PARITY_MAC_WAIT:-14} -ApplePersistenceIgnoreState YES -importedLegacyDefaults YES \
    -autoArchiveChats NO -archivedSessions "()" -NSAppSleepDisabled YES -remoteEnabled NO -density comfortable -verbosity normal -showEnergy NO -verbosityBySession "{}" $style >/dev/null 2>"$WORK/stderr.log" || true
[[ -s $OUT ]] || { print -u2 "mac-metrics.sh: the Mac app didn't write $OUT"; tail -20 "$WORK/stderr.log" >&2; exit 1; }
node "$HERE/diff-metrics.mjs" "$WEB" "$OUT"

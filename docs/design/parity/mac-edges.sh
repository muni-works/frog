#!/bin/zsh
# The Mac's transcript edges: replays edges-fixture.mjs in the parity build, writes
# frog-transcript-edges/1 (edges.mjs has the format) and checks it (check-edges.mjs).
#
#   docs/design/parity/mac-edges.sh [out.json] [WxH] [look] [png]
#   defaults: docs/design/transcript/metrics/edges-mac.json 1280x2600 dark (no png)
#
# A replay re-asks only Ask tool calls, so the fixture's question card doesn't show here (the
# check runs with --no-require for that one kind); FrogTests/TranscriptEdgesTests feeds the same
# events to a hosted pane and requires every kind. Needs the parity build (capture.sh makes it).
set -euo pipefail
HERE=${0:A:h}
ROOT=${HERE:h:h:h}
OUT=${1:-$ROOT/docs/design/transcript/metrics/edges-mac.json}
SIZE=${2:-1280x2600}
LOOK=${3:-dark}
PNG=${4:-}
APP=${PARITY_APP:-$ROOT/apps/macos/build/parity/Build/Products/Debug/Frog.app}
ID=toys.frog.parity
WORK=$(mktemp -d -t frog-edges)
trap 'rm -rf "$WORK"' EXIT
home="$WORK/home"
mkdir -p "$home/code/lilypad/src" "$home/.local/share/frog/sessions"
node "$HERE/edges-fixture.mjs" "$home/code/lilypad" > "$home/edges.jsonl"
cp "$home/edges.jsonl" "$home/.local/share/frog/sessions/20261118-120000-edges.jsonl"
rm -rf ~/Library/Saved\ Application\ State/$ID.savedState
style=(-NSRequiresAquaSystemAppearance YES); [[ $LOOK == dark ]] && style=(-AppleInterfaceStyle Dark)
rm -f "$OUT"
shot=(); [[ -n $PNG ]] && shot=(-FrogSnapshot "$PNG")
HOME="$home" "$APP/Contents/MacOS/Frog" -FrogFolder "$home/code/lilypad" -FrogReplay "$home/edges.jsonl" \
    -FrogReplaySpeed 4 -FrogSnapshotSize "$SIZE" -FrogOffscreen YES -FrogEdges "$OUT" $shot \
    -FrogSnapshotDelay ${PARITY_MAC_WAIT:-22} -ApplePersistenceIgnoreState YES -importedLegacyDefaults YES \
    -autoArchiveChats NO -archivedSessions "()" -NSAppSleepDisabled YES -remoteEnabled NO -density comfortable -verbosity normal -showEnergy NO -verbosityBySession "{}" $style >/dev/null 2>"$WORK/stderr.log" || true
[[ -s $OUT ]] || { print -u2 "mac-edges.sh: the Mac app didn't write $OUT"; tail -20 "$WORK/stderr.log" >&2; exit 1; }
node "$HERE/check-edges.mjs" --no-require "$OUT"

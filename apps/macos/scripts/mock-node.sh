#!/bin/sh
# A mock tang node (docs/node-protocol.md §1–5) for developing pairing in the Mac app.
#   scripts/mock-node.sh [name] [port]     MOCK_CODE=123456 pins the code.
set -e
here=$(cd "$(dirname "$0")" && pwd)
out="${TMPDIR:-/tmp}/frog-mock-node"
swiftc -O -D MOCK_NODE_STANDALONE -target arm64-apple-macos26 -o "$out" \
  "$here/mock-node/main.swift" "$here/../FrogTests/MockNode.swift" \
  "$here/../Frog/Model/Spake2.swift" "$here/../Frog/Model/NodePairing.swift"
exec "$out" "$@"

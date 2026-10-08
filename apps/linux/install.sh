#!/bin/sh
# Install the frog window (Quickshell) and its desktop entry.
#   apps/linux/install.sh                    -> /usr/local
#   PREFIX=$HOME/.local apps/linux/install.sh
#   DESTDIR=/rootfs PREFIX=/usr apps/linux/install.sh   (an OS image)
# Needs quickshell (qs) >= 0.2 and frog on PATH (or FROG_BIN).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
p=${DESTDIR:-}${PREFIX:-/usr/local}
install -Dm755 "$here/frog-app" "$p/bin/frog-app"
mkdir -p "$p/share/frog/quickshell"
for f in "$here"/quickshell/*.qml "$here/quickshell/frog.svg"; do
  install -m644 "$f" "$p/share/frog/quickshell/"
done
install -Dm644 "$here/frog.desktop" "$p/share/applications/frog.desktop"
install -Dm644 "$here/quickshell/frog.svg" "$p/share/icons/hicolor/scalable/apps/frog.svg"
echo "installed frog-app in $p"

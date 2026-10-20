#!/bin/sh
# Install the Frog app (eco.frog.Frog): the binary, desktop entry, AppStream
# metainfo and icons. Build first: cargo build --release -p frog-gtk (needs
# gtk4, libadwaita and gtksourceview5 development files).
#   apps/linux/install.sh                          -> /usr/local
#   PREFIX=$HOME/.local apps/linux/install.sh
#   DESTDIR=/rootfs PREFIX=/usr apps/linux/install.sh  (an OS image)
# BIN overrides the binary (default: target/release/frog-app).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
prefix=${PREFIX:-/usr/local}
p=${DESTDIR:-}$prefix
bin=${BIN:-$here/../../target/release/frog-app}
install -Dm755 "$bin" "$p/bin/frog-app"
# absolute Exec when the prefix may not be on the desktop's PATH
if [ "$prefix" = /usr ]; then exec_=frog-app; else exec_=$prefix/bin/frog-app; fi
mkdir -p "$p/share/applications"
sed "s|^Exec=frog-app|Exec=$exec_|" "$here/data/eco.frog.Frog.desktop" > "$p/share/applications/eco.frog.Frog.desktop"
chmod 644 "$p/share/applications/eco.frog.Frog.desktop"
install -Dm644 "$here/data/eco.frog.Frog.metainfo.xml" "$p/share/metainfo/eco.frog.Frog.metainfo.xml"
for f in "$here"/data/icons/hicolor/scalable/apps/*.svg; do
  install -Dm644 "$f" "$p/share/icons/hicolor/scalable/apps/$(basename "$f")"
done
for f in "$here"/data/icons/hicolor/symbolic/apps/*.svg; do
  install -Dm644 "$f" "$p/share/icons/hicolor/symbolic/apps/$(basename "$f")"
done
echo "installed frog-app in $p"

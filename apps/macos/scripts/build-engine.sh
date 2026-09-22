#!/bin/sh
# Build the Rust engine and put it in the app bundle's Resources, where the app looks first.
set -e
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
REPO="$SRCROOT/../.."
PROFILE=release
cargo build --manifest-path "$REPO/Cargo.toml" --release -p kiln
DEST="$BUILT_PRODUCTS_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
mkdir -p "$DEST"
cp "$REPO/target/$PROFILE/kiln" "$DEST/kiln"

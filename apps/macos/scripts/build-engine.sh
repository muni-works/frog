#!/bin/sh
# Build the Rust engine and put it in the app bundle's Resources, where the app looks first.
set -e
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
REPO="$SRCROOT/../.."
PROFILE=release
cargo build --manifest-path "$REPO/Cargo.toml" --release -p kiln
DEST="$BUILT_PRODUCTS_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
mkdir -p "$DEST"
rm -f "$DEST/kiln"; cp "$REPO/target/$PROFILE/kiln" "$DEST/kiln"

# Inference sidecars, next to the engine (kiln looks there): kiln-apple from this repo, and
# tang-llm from a tang checkout if there is one (TANG_DIR, else ../tang next to this repo).
swift build -c release --package-path "$REPO/sidecars/kiln-apple"
rm -f "$DEST/kiln-apple"; cp "$REPO/sidecars/kiln-apple/.build/release/kiln-apple" "$DEST/kiln-apple"
swift build -c release --package-path "$REPO/sidecars/kiln-desktop"
rm -f "$DEST/kiln-desktop"; cp "$REPO/sidecars/kiln-desktop/.build/release/kiln-desktop" "$DEST/kiln-desktop"
TANG_DIR="${TANG_DIR:-$REPO/../tang}"
if [ -f "$TANG_DIR/crates/tang-llm/Cargo.toml" ]; then
    cargo build --manifest-path "$TANG_DIR/Cargo.toml" --release -p tang-llm
    rm -f "$DEST/tang-llm"; cp "$TANG_DIR/target/release/tang-llm" "$DEST/tang-llm"
else
    echo "warning: no tang checkout at $TANG_DIR; tang/ models won't be available" >&2
fi

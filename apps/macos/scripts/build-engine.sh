#!/bin/sh
# Build the Rust engine and put it in the app bundle's Resources, where the app looks first.
set -e
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
REPO="$SRCROOT/../.."
PROFILE=release
cargo build --manifest-path "$REPO/Cargo.toml" --release -p frog
DEST="$BUILT_PRODUCTS_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
mkdir -p "$DEST"
rm -f "$DEST/frog"; cp "$REPO/target/$PROFILE/frog" "$DEST/frog"

# Inference sidecars, next to the engine (frog looks there): frog-apple from this repo, and
# tang-llm from a tang checkout if there is one (TANG_DIR, else ../tang next to this repo).
swift build -c release --package-path "$REPO/sidecars/frog-apple"
rm -f "$DEST/frog-apple"; cp "$REPO/sidecars/frog-apple/.build/release/frog-apple" "$DEST/frog-apple"
swift build -c release --package-path "$REPO/sidecars/frog-desktop"
rm -f "$DEST/frog-desktop"; cp "$REPO/sidecars/frog-desktop/.build/release/frog-desktop" "$DEST/frog-desktop"
# tang-llm lives on tang's kiln-llm branch; prefer its worktree when the main checkout lacks it.
if [ -z "$TANG_DIR" ] && [ ! -f "$REPO/../tang/crates/tang-llm/Cargo.toml" ] && [ -f "$REPO/../tang-kiln/crates/tang-llm/Cargo.toml" ]; then
    TANG_DIR="$REPO/../tang-kiln"
fi
TANG_DIR="${TANG_DIR:-$REPO/../tang}"
if [ -f "$TANG_DIR/crates/tang-llm/Cargo.toml" ]; then
    cargo build --manifest-path "$TANG_DIR/Cargo.toml" --release -p tang-llm
    rm -f "$DEST/tang-llm"; cp "$TANG_DIR/target/release/tang-llm" "$DEST/tang-llm"
else
    echo "warning: no tang checkout at $TANG_DIR; tang/ models won't be available" >&2
fi

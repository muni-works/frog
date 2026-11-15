#!/bin/sh
# Build the Rust engine and put it in the app bundle's Resources, where the app looks first.
set -e
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
REPO="$SRCROOT/../.."
PROFILE=release
DEST="$BUILT_PRODUCTS_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
mkdir -p "$DEST"
# Dev escape hatch: copy engine binaries built outside Xcode (for environments whose own
# sandboxing conflicts with SwiftPM's or Cargo's, which set FROG_PREBUILT_DIR).
if [ -n "$FROG_PREBUILT_DIR" ]; then
    rm -f "$DEST/frog" "$DEST/frog-apple" "$DEST/frog-desktop"
    cp "$FROG_PREBUILT_DIR/frog" "$DEST/frog"
    cp "$FROG_PREBUILT_DIR/frog-apple" "$DEST/frog-apple"
    cp "$FROG_PREBUILT_DIR/frog-desktop" "$DEST/frog-desktop"
    exit 0
fi
cargo build --manifest-path "$REPO/Cargo.toml" --release -p frog
# This workspace, like tang below, may configure a shared Cargo target directory.
FROG_TARGET="$(cargo metadata --manifest-path "$REPO/Cargo.toml" --no-deps --format-version 1 --quiet | sed -n 's/.*"target_directory":"\([^"]*\)".*/\1/p')"
rm -f "$DEST/frog"; cp "$FROG_TARGET/$PROFILE/frog" "$DEST/frog"

# Inference sidecars, next to the engine (frog looks there): frog-apple from this repo, and
# tang-llm from a tang checkout if there is one (TANG_DIR, else ../tang next to this repo).
swift build -c release --package-path "$REPO/sidecars/frog-apple"
rm -f "$DEST/frog-apple"; cp "$REPO/sidecars/frog-apple/.build/release/frog-apple" "$DEST/frog-apple"
swift build -c release --package-path "$REPO/sidecars/frog-desktop"
rm -f "$DEST/frog-desktop"; cp "$REPO/sidecars/frog-desktop/.build/release/frog-desktop" "$DEST/frog-desktop"
# tang-llm is on tang's main (speculative decoding, shared KV blocks, MLX q4 weights). When the
# ../tang checkout is on a branch without it, use a main worktree next to it (../tang-main,
# `git -C ../tang worktree add --detach ../tang-main origin/main`), else the old ../tang-kiln.
if [ -z "$TANG_DIR" ] && [ ! -f "$REPO/../tang/crates/tang-llm/Cargo.toml" ]; then
    for d in tang-main tang-kiln; do
        if [ -f "$REPO/../$d/crates/tang-llm/Cargo.toml" ]; then TANG_DIR="$REPO/../$d"; break; fi
    done
fi
TANG_DIR="${TANG_DIR:-$REPO/../tang}"
if [ -f "$TANG_DIR/crates/tang-llm/Cargo.toml" ]; then
    cargo build --manifest-path "$TANG_DIR/Cargo.toml" --release -p tang-llm --features metal
    # tang may set a shared target directory in .cargo/config.toml. Ask Cargo where it put
    # the release binary rather than assuming the workspace-local target/ directory.
    TANG_TARGET="$(cargo metadata --manifest-path "$TANG_DIR/Cargo.toml" --no-deps --format-version 1 --quiet | sed -n 's/.*"target_directory":"\([^"]*\)".*/\1/p')"
    rm -f "$DEST/tang-llm"; cp "$TANG_TARGET/release/tang-llm" "$DEST/tang-llm"
elif [ -n "$FROG_REQUIRE_TANG" ]; then
    echo "error: no tang checkout at $TANG_DIR; a release must ship tang-llm (set TANG_DIR)" >&2
    exit 1
else
    echo "warning: no tang checkout at $TANG_DIR; tang/ models won't be available" >&2
fi

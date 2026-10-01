#!/bin/zsh
# Build, sign, notarize and publish a release of Frog.app for download from the web.
#
#   apps/macos/scripts/release.sh 0.2.0            # build, notarize, publish to frog.eco
#   apps/macos/scripts/release.sh 0.2.0 --local    # stop before publishing: dist/ only
#
# One-time setup on the release Mac:
#   1. A "Developer ID Application" certificate in the login Keychain (developer.apple.com).
#   2. Notary credentials:  xcrun notarytool store-credentials frog --apple-id … --team-id …
#   3. The Sparkle private key ("Private key for signing Sparkle updates" in the login
#      Keychain). Its public half is project.yml's SPARKLE_PUBLIC_KEY. To move it to another
#      Mac: generate_keys -x key.txt here, generate_keys -f key.txt there (Sparkle's bin/).
#   4. A tang checkout (TANG_DIR, else ../tang): a release always ships tang-llm.
#   5. Cloudflare: cd site && npm install && npx wrangler login (Node 22+). The bucket is
#      created once with: npx wrangler r2 bucket create frog-releases
#
# The release lands in the frog-releases R2 bucket: releases/<version>/Frog.dmg, plus Frog.dmg
# and appcast.xml for the latest. frog.eco serves /download, /appcast.xml and /releases/…
# from it (site/worker/index.js), and the version is tagged v<version> on origin.
set -euo pipefail

VERSION=${1:?usage: release.sh <version> [--local]}
LOCAL=${2:-}
SIGN_ID=${FROG_SIGN_ID:-Developer ID Application}
NOTARY_PROFILE=${FROG_NOTARY_PROFILE:-frog}
BUCKET=${FROG_RELEASE_BUCKET:-frog-releases}
TAG="v$VERSION"

HERE=${0:A:h}
APP_DIR=${HERE:h}
cd "$APP_DIR"
ROOT=$(git rev-parse --show-toplevel)
BUILD_NUMBER=$(git rev-list --count HEAD)
DERIVED="$APP_DIR/build/release"
DIST="$APP_DIR/build/dist/$VERSION"

step() { print -P "%F{green}==>%f $*" }
fail() { print -P "%F{red}error:%f $*" >&2; exit 1 }

# Preflight: everything that can fail late, checked before a 10 minute build.
[[ $VERSION =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || fail "version must look like 1.2.3"
[[ -z $(git status --porcelain) ]] || fail "working tree isn't clean"
security find-identity -v -p codesigning | grep -q "$SIGN_ID" || fail "no \"$SIGN_ID\" certificate in the Keychain"
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || fail "no notary credentials; run: xcrun notarytool store-credentials $NOTARY_PROFILE"
wrangler() { (cd "$ROOT/site" && npx --no-install wrangler "$@") }
if [[ $LOCAL != --local ]]; then
    (( ${$(node -v 2>/dev/null)[2,3]:-0} >= 22 )) || fail "wrangler needs Node 22 or newer (node -v: $(node -v 2>/dev/null))"
    git ls-remote --exit-code --tags origin "$TAG" >/dev/null 2>&1 && fail "$TAG already exists on origin"
    wrangler whoami 2>/dev/null | grep -q "associated with" || fail "wrangler isn't logged in; run: cd site && npx wrangler login"
fi

step "Building Frog $VERSION ($BUILD_NUMBER)"
xcodegen generate --quiet
rm -rf "$DIST"; mkdir -p "$DIST"
xcodebuild build -quiet \
    -project Frog.xcodeproj -scheme Frog -configuration Release \
    -derivedDataPath "$DERIVED" -destination 'generic/platform=macOS' \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    FROG_REQUIRE_TANG=1
APP="$DIST/Frog.app"
ditto "$DERIVED/Build/Products/Release/Frog.app" "$APP"

[[ -n $(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP/Contents/Info.plist" 2>/dev/null) ]] \
    || fail "SPARKLE_PUBLIC_KEY is empty in project.yml; updates couldn't be verified"
[[ -x $APP/Contents/Resources/tang-llm ]] || fail "tang-llm is missing from the bundle"

# Inside out: every Mach-O gets the hardened runtime and a secure timestamp, or notarization
# refuses the whole app. Xcode signs none of the engine binaries (they're resources to it).
step "Signing with $SIGN_ID"
sign() { codesign --force --timestamp --options runtime --sign "$SIGN_ID" "$@" }
for bin in "$APP"/Contents/Resources/*(.x); do sign "$bin"; done
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
sign "$SPARKLE/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$SPARKLE/XPCServices/Downloader.xpc"
sign "$SPARKLE/Autoupdate"
sign "$SPARKLE/Updater.app"
sign "$APP/Contents/Frameworks/Sparkle.framework"
sign --entitlements "$APP_DIR/Frog/Frog.entitlements" "$APP"
codesign --verify --deep --strict "$APP"

notarize() {
    xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait --timeout 30m \
        | tee "$DIST/notary.log"
    grep -q "status: Accepted" "$DIST/notary.log" || fail "notarization rejected; see notarytool log <id>"
}

step "Notarizing the app"
ditto -c -k --keepParent "$APP" "$DIST/Frog.zip"
notarize "$DIST/Frog.zip"
xcrun stapler staple "$APP"
rm "$DIST/Frog.zip"

step "Making the disk image"
STAGE="$DIST/stage"; mkdir -p "$STAGE"; ditto "$APP" "$STAGE/Frog.app"
DMG="$DIST/Frog.dmg"
create-dmg --volname "Frog" --window-size 540 360 --icon-size 128 \
    --icon Frog.app 140 170 --hide-extension Frog.app --app-drop-link 400 170 \
    --no-internet-enable "$DMG" "$STAGE" >/dev/null
rm -rf "$STAGE"
codesign --force --timestamp --sign "$SIGN_ID" "$DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature "$DMG"

step "Writing the appcast"
SIGN_UPDATE="$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
ED=$("$SIGN_UPDATE" "$DMG")   # sparkle:edSignature="…" length="…"
cat > "$DIST/appcast.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Frog</title>
    <item>
      <title>$VERSION</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$BUILD_NUMBER</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <enclosure url="https://frog.eco/releases/$VERSION/Frog.dmg" type="application/octet-stream" $ED/>
    </item>
  </channel>
</rss>
EOF

if [[ $LOCAL == --local ]]; then
    step "Done: $DIST"
    exit 0
fi

# The appcast goes last, so it never points at a DMG that isn't there yet.
step "Publishing $VERSION to frog.eco"
put() { wrangler r2 object put "$BUCKET/$1" --remote --file "$2" --content-type "$3" }
put "releases/$VERSION/Frog.dmg" "$DMG" application/x-apple-diskimage
put Frog.dmg "$DMG" application/x-apple-diskimage
put appcast.xml "$DIST/appcast.xml" application/xml
git tag "$TAG" && git push origin "$TAG"
step "Done: https://frog.eco/releases/$VERSION/Frog.dmg"

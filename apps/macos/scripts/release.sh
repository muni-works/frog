#!/bin/zsh
# Build, sign, notarize and publish a release of Frog.app for download from the web.
#
#   apps/macos/scripts/release.sh 0.2.0            # build, notarize, publish to GitHub
#   apps/macos/scripts/release.sh 0.2.0 --local    # stop before GitHub: dist/ only
#   apps/macos/scripts/release.sh 0.2.0 --unsigned # unsigned build, no notarization, dist/ only
#
# One-time setup on the release Mac:
#   1. A "Developer ID Application" certificate in the login Keychain (developer.apple.com).
#   2. Notary credentials:  xcrun notarytool store-credentials frog --apple-id ... --team-id ...
#   3. The Sparkle private key ("Private key for signing Sparkle updates" in the login
#      Keychain). Its public half is project.yml's SPARKLE_PUBLIC_KEY. To move it to another
#      Mac: generate_keys -x key.txt here, generate_keys -f key.txt there (Sparkle's bin/).
#   4. A tang checkout (TANG_DIR, else ../tang): a release always ships tang-llm.
#
# The release lands on $FROG_RELEASE_REPO (muni-works/frog) as Frog.dmg and appcast.xml. frog.toys
# redirects /download and /appcast.xml to the latest release's copies (site/vercel.json).
set -euo pipefail

VERSION=${1:?usage: release.sh <version> [--local|--unsigned]}
MODE=${2:-}
SIGN_ID=${FROG_SIGN_ID:-Developer ID Application}
NOTARY_PROFILE=${FROG_NOTARY_PROFILE:-frog}
REPO=${FROG_RELEASE_REPO:-muni-works/frog}
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
if [[ $MODE != --unsigned ]]; then
    security find-identity -v -p codesigning | grep -q "$SIGN_ID" || fail "no \"$SIGN_ID\" certificate in the Keychain"
    xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
        || fail "no notary credentials; run: xcrun notarytool store-credentials $NOTARY_PROFILE"
fi
if [[ $MODE != --local ]] && [[ $MODE != --unsigned || -n ${FROG_PUBLISH_UNSIGNED:-} ]]; then
    gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1 && fail "$TAG already exists on $REPO"
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

if [[ $MODE == --unsigned ]]; then
    step "Unsigned build: skipping signing and notarization"
    ditto -c -k --keepParent "$APP" "$DIST/Frog.zip"
    sha256sum "$DIST/Frog.zip" > "$DIST/Frog.zip.sha256"
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
      <sparkle:releaseNotesLink>https://github.com/$REPO/releases/tag/$TAG</sparkle:releaseNotesLink>
      <enclosure url="https://github.com/$REPO/releases/download/$TAG/Frog.zip" type="application/zip" />
    </item>
  </channel>
</rss>
EOF
    # An unsigned build stays local unless asked for: it would take the release's tag.
    if [[ -z ${FROG_PUBLISH_UNSIGNED:-} ]]; then
        step "Done: $DIST (set FROG_PUBLISH_UNSIGNED=1 to publish it as a prerelease)"
        exit 0
    fi
    step "Publishing $TAG to $REPO (unsigned prerelease)"
    gh release create "$TAG" "$DIST/Frog.zip" "$DIST/Frog.zip.sha256" "$DIST/appcast.xml" --repo "$REPO" \
        --target "$(git rev-parse HEAD)" --title "Frog $VERSION (unsigned)" --prerelease --generate-notes
    step "Done: https://github.com/$REPO/releases/tag/$TAG"
    exit 0
fi

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
ED=$("$SIGN_UPDATE" "$DMG")
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
      <sparkle:releaseNotesLink>https://github.com/$REPO/releases/tag/$TAG</sparkle:releaseNotesLink>
      <enclosure url="https://github.com/$REPO/releases/download/$TAG/Frog.dmg" type="application/octet-stream" $ED/>
    </item>
  </channel>
</rss>
EOF

if [[ $MODE == --local ]]; then
    step "Done: $DIST"
    exit 0
fi

step "Publishing $TAG to $REPO"
gh release create "$TAG" "$DMG" "$DIST/appcast.xml" --repo "$REPO" \
    --target "$(git rev-parse HEAD)" --title "Frog $VERSION" --generate-notes
step "Done: https://github.com/$REPO/releases/tag/$TAG"

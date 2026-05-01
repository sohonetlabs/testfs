#!/bin/bash
# Build a Developer ID signed Release archive, export it, package
# as a notarized DMG containing the app, an Applications symlink,
# and the bundled Examples folder. Notarization credentials live
# in the macOS keychain under the profile name `testFS`, set up
# once via:
#   xcrun notarytool store-credentials "testFS" \
#       --apple-id <your-apple-id> --team-id H6XW263G62 \
#       --password <app-specific-password>
# No password ever lives in this repo or in shell history.
set -euo pipefail

KEYCHAIN_PROFILE="testFS"      # notarytool keychain profile name (camelCase)
SPARKLE_KEY_ACCOUNT="testfs"   # sign_update --account name (lowercase) — distinct keychain item from notarytool's

REPO="$(cd "$(dirname "$0")/.." && pwd)"
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$REPO"

if ! command -v create-dmg >/dev/null 2>&1; then
    echo "FAIL: create-dmg not found. Install with: brew install create-dmg" >&2
    exit 1
fi

if ! command -v swiftlint >/dev/null 2>&1; then
    echo "FAIL: swiftlint not found. Install with: brew install swiftlint" >&2
    exit 1
fi

echo "=== lint preflight ==="
if ! swiftlint --strict; then
    echo "FAIL: swiftlint found violations. Fix them before releasing." >&2
    exit 1
fi

VERSION="$(tr -d '[:space:]' < VERSION)"

ARCHIVE=build/TestFS.xcarchive
EXPORT=build/export
STAGING=build/release-staging
DMG="build/TestFS-$VERSION.dmg"

rm -rf "$ARCHIVE" "$EXPORT" "$STAGING" "$DMG"

echo "=== archive ==="
xcodebuild \
    -project TestFS.xcodeproj \
    -scheme TestFS \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -allowProvisioningUpdates \
    -archivePath "$ARCHIVE" \
    archive

echo ""
echo "=== export (method=developer-id) ==="
xcodebuild \
    -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportPath "$EXPORT" \
    -exportOptionsPlist "$HERE/ExportOptions.plist" \
    -allowProvisioningUpdates

APP="$EXPORT/TestFS.app"
if [ ! -d "$APP" ]; then
    echo "FAIL: expected $APP after export" >&2
    exit 1
fi

echo ""
echo "=== stage DMG layout ==="
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/TestFS.app"
# Mirror the bundled Examples folder out to the DMG's top level so
# users can browse it without right-click → Show Package Contents.
# The single source of truth is research/test_json_fs/example/,
# already copied into the .app at build time.
if [ -d "$STAGING/TestFS.app/Contents/Resources/Examples" ]; then
    cp -R "$STAGING/TestFS.app/Contents/Resources/Examples" "$STAGING/Examples"
else
    echo "FAIL: bundled Examples missing from $STAGING/TestFS.app" >&2
    exit 1
fi

echo ""
echo "=== create-dmg ==="
create-dmg \
    --volname "TestFS $VERSION" \
    --window-size 580 400 \
    --icon-size 96 \
    --icon "TestFS.app" 140 170 \
    --app-drop-link 400 170 \
    --icon "Examples" 270 290 \
    --no-internet-enable \
    "$DMG" \
    "$STAGING/"

echo ""
echo "=== notarize ==="
xcrun notarytool submit "$DMG" --keychain-profile "$KEYCHAIN_PROFILE" --wait

echo ""
echo "=== staple ==="
xcrun stapler staple "$DMG"

echo ""
echo "=== verify ==="
# DMGs aren't directly code-signed; the notarization ticket is stapled
# and checked at download/attach time. Validate the ticket and mount
# the DMG so we can spctl-assess the .app inside the way Gatekeeper
# does when a user double-clicks it after downloading.
xcrun stapler validate "$DMG"
MOUNT_DIR="$(/usr/bin/mktemp -d)"
/usr/bin/hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT_DIR" "$DMG" >/dev/null
trap 'hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1; rmdir "$MOUNT_DIR" 2>/dev/null || true' EXIT
spctl -a -vvv -t exec "$MOUNT_DIR/TestFS.app"
hdiutil detach "$MOUNT_DIR" >/dev/null
rmdir "$MOUNT_DIR"
trap - EXIT

echo ""
echo "=== sparkle: sign update ==="
# Multiple DerivedData dirs (TestFS-<hash>) can pile up if the project is
# cloned to several paths. -td picks the most recently modified one, which
# is the one the just-completed archive populated.
SPARKLE_BIN_GLOB=~/Library/Developer/Xcode/DerivedData/TestFS-*/SourcePackages/artifacts/sparkle/Sparkle/bin
SPARKLE_BIN="$(ls -td $SPARKLE_BIN_GLOB 2>/dev/null | head -1)"
if [ -z "$SPARKLE_BIN" ] || [ ! -x "$SPARKLE_BIN/sign_update" ]; then
    echo "FAIL: sign_update not found. Build the project once first to populate" >&2
    echo "      DerivedData with the Sparkle artifacts." >&2
    exit 1
fi
SIG_LINE="$("$SPARKLE_BIN/sign_update" --account "$SPARKLE_KEY_ACCOUNT" "$DMG")"
echo "$SIG_LINE"
ED_SIG="$(echo "$SIG_LINE" | sed -n 's/.*sparkle:edSignature="\([A-Za-z0-9+/=]\{1,\}\)".*/\1/p')"
LENGTH="$(echo "$SIG_LINE" | sed -n 's/.*length="\([0-9]\{1,\}\)".*/\1/p')"
if [ -z "$ED_SIG" ] || [ -z "$LENGTH" ]; then
    echo "FAIL: couldn't parse sign_update output: $SIG_LINE" >&2
    exit 1
fi

BUILD="$(tr -d '[:space:]' < .build_number)"

echo ""
echo "=== sparkle: update appcast.xml ==="
ruby "$HERE/update_appcast.rb" "$VERSION" "$BUILD" "$LENGTH" "$ED_SIG"
echo "appcast.xml updated with v$VERSION (build $BUILD)"

echo ""
echo "=== prune stale build registrations ==="
# Both `xcodebuild archive` and `xcodebuild -exportArchive` register
# their output bundles with LaunchServices. After we have a notarized
# DMG, those staging bundles have served their purpose, and leaving
# them registered means the user (or test machines) end up with
# multiple `+ enabled` pluginkit entries for `com.sohonet.testfsmount.appex`
# pointing at different UUIDs — exactly the duplication that makes
# extensionkitd resolve to a stale bundle and `mount -t testfs` fail
# with `extensionKit.errorDomain error 2`.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
for stale_app in \
    "$STAGING/TestFS.app" \
    "$EXPORT/TestFS.app" \
    "$ARCHIVE/Products/Applications/TestFS.app"; do
    [ -d "$stale_app" ] && "$LSREGISTER" -u "$stale_app" 2>/dev/null || true
done

echo ""
echo "=== done ==="
echo "Notarized DMG: $DMG"
shasum -a 256 "$DMG"
echo ""
echo "Next steps:"
echo "  git push origin main          # push BEFORE creating the release, so gh tags the right commit"
echo "  gh release create v$VERSION \"$DMG\" --notes 'Release notes here'"
echo "  git add appcast.xml .build_number && git commit -m 'Appcast: $VERSION' && git push"

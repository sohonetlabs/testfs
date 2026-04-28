#!/bin/bash
# Build the project if needed, install into /Applications, re-register with
# LaunchServices and pluginkit, and deep-link to System Settings so the user
# can flip the enable toggle.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
DERIVED_GLOB=~/Library/Developer/Xcode/DerivedData/TestFS-*/Build/Products/Debug/TestFS.app

# Build if there's no existing DerivedData output.
if ! ls $DERIVED_GLOB 1>/dev/null 2>&1; then
    echo "No built TestFS.app found; running xcodebuild build..."
    xcodebuild -project TestFS.xcodeproj \
        -scheme TestFS \
        -configuration Debug \
        -destination 'platform=macOS' \
        -allowProvisioningUpdates \
        build
fi

SRC_APP="$(ls -d $DERIVED_GLOB | head -1)"
if [ ! -d "$SRC_APP" ]; then
    echo "FAIL: could not locate built TestFS.app"
    exit 1
fi

# Drop every TestFS.app LaunchServices currently knows about — including
# the existing /Applications copy and any build-tree leftovers — before
# we install the new one. LaunchServices doesn't auto-evict entries when
# a path is overwritten or deleted, so pluginkit ends up with multiple
# `+ enabled` entries pointing at different UUIDs for the same bundle
# ID. extensionkitd picks one and if its backing bundle isn't usable,
# `mount -t testfs` fails with `extensionKit.errorDomain error 2`. We've
# seen four-way duplication on this machine after a single round-trip
# of build + install + release.sh.
echo "Pruning stale TestFS.app registrations..."
shopt -s nullglob
for stale_app in \
    ~/Library/Developer/Xcode/DerivedData/TestFS-*/Build/Products/*/TestFS.app \
    "$REPO"/build/derived/Build/Products/*/TestFS.app \
    "$REPO"/build/export/TestFS.app \
    "$REPO"/build/release-staging/TestFS.app \
    /Applications/TestFS.app; do
    "$LSREGISTER" -u "$stale_app" 2>/dev/null || true
done
shopt -u nullglob

echo "Installing $SRC_APP to /Applications/TestFS.app"
rm -rf /Applications/TestFS.app
cp -R "$SRC_APP" /Applications/TestFS.app

# Register only the /Applications copy. Unregister SRC_APP afterwards so
# the just-built DerivedData bundle doesn't compete for the same
# pluginkit fstype slot — that's exactly the duplication that bit us.
"$LSREGISTER" -f /Applications/TestFS.app
"$LSREGISTER" -u "$SRC_APP" 2>/dev/null || true

APPEX=/Applications/TestFS.app/Contents/Extensions/TestFSExtension.appex
if [ -d "$APPEX" ]; then
    pluginkit -v -a "$APPEX" || true
    # Toggle pluginkit's adjudication state off and back on. The
    # transition (not the end state) is what forces extensionkitd to
    # drop its cached UUID and re-resolve against the just-installed
    # bundle — without it, mount-by-fstype fails with
    # `extensionKit.errorDomain error 2 / File system named testfs
    # not found`. Same toggle cycle the in-app
    # AppEnvironment.reregisterExtensionIfNeeded runs after a Sparkle
    # update; kept in sync so manual install and auto-update converge
    # on the same end state.
    pluginkit -e ignore -i com.sohonet.testfsmount.appex || true
    pluginkit -e use -i com.sohonet.testfsmount.appex || true
else
    echo "WARN: no .appex found at $APPEX - extension target may not be embedded"
fi

echo ""
echo "Registered + enabled. Verify in System Settings if you want to be sure:"
echo "  System Settings > General > Login Items & Extensions > File System Extensions"
open "x-apple.systempreferences:com.apple.LoginItems-Settings.extension?Extensions" || true

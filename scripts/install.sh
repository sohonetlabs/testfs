#!/bin/bash
# Build the project if needed, install into /Applications, re-register with
# LaunchServices and pluginkit, and deep-link to System Settings so the user
# can flip the enable toggle.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister

# Always rebuild from the current checkout — the previous "skip if any
# DerivedData exists" short-circuit could pick up an unrelated clone's
# bundle from the shared `~/Library/Developer/Xcode/DerivedData/TestFS-*`
# pool. Build into the repo's own derived path so SRC_APP is unambiguous.
echo "Building TestFS into build/derived..."
xcodebuild -project TestFS.xcodeproj \
    -scheme TestFS \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$REPO/build/derived" \
    -allowProvisioningUpdates \
    build

SRC_APP="$REPO/build/derived/Build/Products/Debug/TestFS.app"
if [ ! -d "$SRC_APP" ]; then
    echo "FAIL: expected build output at $SRC_APP"
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

# Register only the /Applications copy. SRC_APP under build/derived/
# was already swept by the prune loop above, so it can't compete for
# the same pluginkit fstype slot.
"$LSREGISTER" -f /Applications/TestFS.app

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

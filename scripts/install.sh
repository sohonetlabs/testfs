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
#
# Inject CURRENT_PROJECT_VERSION + MARKETING_VERSION on the xcodebuild
# command line so the host's synthesized Info.plist agrees with the
# embedded extension's. The "Bump build number" Run Script PlistBuddy-
# patches the host plist, but Xcode's `ProcessInfoPlistFile` step runs
# AFTER the Run Script and regenerates the plist from the project's
# `CURRENT_PROJECT_VERSION` (default `1`), clobbering the patch. The
# extension's plist patch sticks because its `ProcessInfoPlistFile`
# already ran by then. Result without this override: parent
# CFBundleVersion=1, extension CFBundleVersion=131,
# embeddedBinaryValidationUtility warns, extensionkitd async-evicts
# our pluginkit registration ~5s after install completes, and
# `mount -t testfs` fails with extensionKit.errorDomain error 2.
NEXT_BUILD=$(($(tr -d '[:space:]' < "$REPO/.build_number" 2>/dev/null || echo 0) + 1))
VERSION=$(tr -d '[:space:]' < "$REPO/VERSION")
echo "Building TestFS $VERSION (build $NEXT_BUILD) into build/derived..."
xcodebuild -project TestFS.xcodeproj \
    -scheme TestFS \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$REPO/build/derived" \
    -allowProvisioningUpdates \
    "CURRENT_PROJECT_VERSION=$NEXT_BUILD" \
    "MARKETING_VERSION=$VERSION" \
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
# Don't unregister /Applications/TestFS.app here — `rm -rf` + `cp -R`
# below replaces it in place, and an explicit `lsregister -u` race
# against the upcoming `lsregister -f` was leaving extensionkitd with
# a stale eviction in flight, which then evicted our pluginkit
# registration 2–7 seconds after install.sh exited (so `mount -t
# testfs` failed with extensionKit.errorDomain error 2 even though
# the script reported success). Other DerivedData / build-tree paths
# still need explicit cleanup since they aren't on the install path.
shopt -s nullglob
for stale_app in \
    ~/Library/Developer/Xcode/DerivedData/TestFS-*/Build/Products/*/TestFS.app \
    "$REPO"/build/derived/Build/Products/*/TestFS.app \
    "$REPO"/build/export/TestFS.app \
    "$REPO"/build/release-staging/TestFS.app; do
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
APPEX_ID=com.sohonet.testfsmount.appex

if [ ! -d "$APPEX" ]; then
    echo "FAIL: no .appex found at $APPEX - extension target may not be embedded"
    exit 1
fi

# Register the just-installed bundle, then toggle pluginkit's
# adjudication state off and back on. The transition (not the end
# state) is what forces extensionkitd to drop its cached UUID and
# re-resolve against the just-installed bundle — without it, mount-
# by-fstype fails with `extensionKit.errorDomain error 2 / File
# system named testfs not found`. Same toggle cycle the in-app
# AppEnvironment.reregisterExtensionIfNeeded runs after a Sparkle
# update; kept in sync so manual install and auto-update converge
# on the same end state.
# Register the appex with pluginkit, then toggle the adjudication
# state to force extensionkitd to drop its cached UUID and re-resolve
# against the just-installed bundle. The settle sleeps are load-
# bearing: an `lsregister -u` of a stale build-tree TestFS.app earlier
# in the script kicks off async LaunchServices propagation; without
# this delay extensionkitd processes the eviction AFTER our `pluginkit
# -v -a` runs, drops our registration, and `mount -t testfs` then
# fails with extensionKit.errorDomain error 2 even though install.sh
# reported success.
sleep 2
pluginkit -v -a "$APPEX"
sleep 2
pluginkit -e ignore -i "$APPEX_ID"
pluginkit -e use -i "$APPEX_ID"

# Verify the registration actually stuck. After the initial register
# we sleep again so an async eviction (still in flight from the prune
# loop) lands before we read back. If it evicted us, do one more
# `pluginkit -v -a` and re-verify; if THAT misses too, fail loudly
# rather than printing a dishonest "Registered + enabled".
sleep 2
if [ -z "$(pluginkit -m -i "$APPEX_ID" 2>/dev/null)" ]; then
    echo "WARN: $APPEX_ID not registered after first attempt; retrying..."
    sleep 2
    pluginkit -v -a "$APPEX"
    sleep 2
    if [ -z "$(pluginkit -m -i "$APPEX_ID" 2>/dev/null)" ]; then
        echo "FAIL: $APPEX_ID not registered after retry."
        echo "      mount -t testfs will fail with extensionKit.errorDomain error 2"
        echo "      until you re-run scripts/install.sh or manually:"
        echo "        pluginkit -v -a $APPEX"
        exit 1
    fi
fi

echo ""
echo "Registered + enabled. Verify in System Settings if you want to be sure:"
echo "  System Settings > General > Login Items & Extensions > File System Extensions"
open "x-apple.systempreferences:com.apple.LoginItems-Settings.extension?Extensions" || true

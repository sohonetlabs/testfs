#!/bin/bash
# Build the project if needed, install into /Applications, re-register with
# LaunchServices and pluginkit, and deep-link to System Settings so the user
# can flip the enable toggle.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

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

echo "Installing $SRC_APP to /Applications/TestFS.app"
rm -rf /Applications/TestFS.app
cp -R "$SRC_APP" /Applications/TestFS.app

LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
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

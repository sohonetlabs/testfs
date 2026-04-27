#!/bin/bash
# Sanity-check an installed copy of TestFS: the .app is present in
# /Applications, the FSKit extension is embedded, both bundles pass
# codesign --verify, and pluginkit knows about the extension. Doesn't
# attempt a mount — for that, run scripts/mount.sh after enabling the
# extension in System Settings.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"

if [ "${1:-}" = "--version" ] || [ "${1:-}" = "-v" ]; then
    VERSION=$(tr -d '[:space:]' < "$REPO/VERSION")
    BUILD=$(tr -d '[:space:]' < "$REPO/.build_number" 2>/dev/null || echo 0)
    echo "TestFS $VERSION (build $BUILD)"
    exit 0
fi

APP=/Applications/TestFS.app
APPEX=$APP/Contents/Extensions/TestFSExtension.appex

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

[ -d "$APP" ]   || fail "$APP not installed - run scripts/install.sh first"
pass "$APP present"

[ -d "$APPEX" ] || fail "$APPEX not embedded in the app bundle"
pass "$APPEX embedded"

codesign --verify --verbose=0 "$APP"   || fail "codesign verify failed on host app"
codesign --verify --verbose=0 "$APPEX" || fail "codesign verify failed on extension"
pass "both bundles pass codesign --verify"

if pluginkit -mA -p com.apple.fskit.fsmodule 2>&1 | grep -q "com.sohonet.testfsmount.appex"; then
    pass "com.sohonet.testfsmount.appex registered with pluginkit"
else
    fail "com.sohonet.testfsmount.appex not registered - try running scripts/install.sh"
fi

echo ""
echo "Smoke test passed. Manual follow-ups:"
echo "  1. Ensure TestFS is toggled ON under System Settings > General > Login Items & Extensions > File System Extensions"
echo "  2. scripts/mount.sh    — mount the bundled test.json at /tmp/testfs"
echo "  3. ls /tmp/testfs      — should list the synthesized files"
echo "  4. scripts/unmount.sh  — clean up"

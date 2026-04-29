#!/bin/bash
# Mount the testfs extension with the given tree JSON as its config.
# Usage: scripts/mount.sh [path/to/tree.json] [mountpoint]
#   config defaults to research/test_json_fs/example/test.json
#   mountpoint defaults to /tmp/testfs
#
# Must be run as the current user, NOT via sudo. mount -F under sudo
# fails because fskitd refuses requests whose audit-token uid doesn't
# match the dev-node owner that hdiutil attached as the user.
#
# Files are staged into the extension's own sandbox Application Support
# so the extension can read them without cross-sandbox friction:
#   ~/Library/Containers/com.sohonet.testfsmount.appex/Data/
#       Library/Application Support/TestFS/
#         tree-<bsdName>.json       (copied tree JSON)
#         active-<bsdName>.json     (sidecar pointing at the tree)
# The extension keys its sidecar lookup by BSD name, so concurrent
# mounts on distinct /dev/diskN devices get independent content.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
HERE="$(cd "$(dirname "$0")" && pwd)"

if [ "${1:-}" = "--version" ] || [ "${1:-}" = "-v" ]; then
    VERSION=$(tr -d '[:space:]' < "$REPO/VERSION")
    BUILD=$(tr -d '[:space:]' < "$REPO/.build_number" 2>/dev/null || echo 0)
    echo "TestFS $VERSION (build $BUILD)"
    exit 0
fi

CONFIG="${1:-$REPO/research/test_json_fs/example/test.json}"
MNT="${2:-/tmp/testfs}"

CONFIG_ABS="$(perl -MCwd=abs_path -le 'print abs_path(shift)' "$CONFIG")"
if [ ! -f "$CONFIG_ABS" ]; then
    echo "FAIL: config JSON not found at $CONFIG" >&2
    exit 1
fi

# Unmount anything already at the mountpoint.
if mount | grep -q " on $MNT "; then
    echo "Existing mount at $MNT — unmounting first."
    "$HERE/unmount.sh" "$MNT"
fi

DEV=$("$HERE/devdisk.sh")
BSD="${DEV#/dev/}"
echo "Dummy dev node: $DEV (bsdName=$BSD)"

CONTAINER_DIR="$HOME/Library/Containers/com.sohonet.testfsmount.appex/Data/Library/Application Support/TestFS"
mkdir -p "$CONTAINER_DIR"
TREE="$CONTAINER_DIR/tree-$BSD.json"
SIDECAR="$CONTAINER_DIR/active-$BSD.json"
cp "$CONFIG_ABS" "$TREE"
# Encode via python3: bash has no JSON encoder, and a path or volume
# name with `"`, `\`, or newline would break a heredoc. The python
# body is static — pass any new sidecar field via env vars too,
# never inline shell-interpolated.
TREE_PATH="$TREE" VOLUME_NAME="$(basename "$CONFIG_ABS" .json)" \
    /usr/bin/python3 -c '
import json, os, sys
sys.stdout.write(json.dumps({
    "config": os.environ["TREE_PATH"],
    "volume_name": os.environ["VOLUME_NAME"],
}))
' > "$SIDECAR"
echo "Staged $TREE (from $CONFIG_ABS)"
echo "Wrote   $SIDECAR"

mkdir -p "$MNT"
echo "Mounting testfs on $MNT"
mount -F -t testfs "$DEV" "$MNT"
mount | grep "$MNT" || true

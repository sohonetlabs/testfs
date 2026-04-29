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

# Allocate a fresh per-UUID image so concurrent mount.sh invocations
# get distinct /dev/diskN devices. Mirror MountManager.prepareMount's
# scheme — a singleton dummy.img would key the sidecar files (which
# the extension looks up by BSD name) the same for every concurrent
# mount, so the second mount would stomp the first's staged state.
# Note: the osascript admin prompt now fires on every invocation
# (the deleted devdisk.sh fired only when its singleton image was
# missing). Worth knowing before scripting this in a test loop.
DUMMIES_DIR="$HOME/Library/Application Support/TestFS/dummies"
mkdir -p "$DUMMIES_DIR"
UUID=$(/usr/bin/uuidgen)
IMG="$DUMMIES_DIR/dummy-$UUID.img"
DEV=""
# Detach the device + remove the image on any abnormal exit so a
# user-cancelled osascript prompt or a downstream mount(8) failure
# can't leak /dev/diskN attachments and orphan image files.
cleanup_alloc() {
    if [ -n "$DEV" ]; then
        hdiutil detach "$DEV" -quiet 2>/dev/null || true
    fi
    rm -f "$IMG"
}
trap cleanup_alloc EXIT
mkfile -n 100m "$IMG"

# Match MountManager.hdiutilAttach's parser: pick the first line
# containing `/dev/`, not literally line 1, so a leading blank or
# warning line from hdiutil doesn't poison DEV.
DEV=$(/usr/bin/hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$IMG" \
    | awk '/\/dev\// {print $1; exit}')
if [ -z "$DEV" ]; then
    echo "FAIL: hdiutil did not return a device node" >&2
    exit 1
fi

# fskitd's audit-token check rejects uid 0 against a user-owned dev
# node, so mount -F under sudo would fail. osascript surfaces the
# admin prompt as a GUI dialog so this works non-interactively from
# outside a tty.
#
# `$DEV` is read inside AppleScript via `system attribute`, then
# `quoted form of` re-quotes it for the inner shell — keeps untrusted
# bytes out of the AppleScript source text so they can't break into
# `do shell script ... with administrator privileges`. Username comes
# from `system info` (kernel credential) rather than the env, so a
# tampered `USER` can't be a privesc primitive either.
TESTFS_DEV="$DEV" osascript <<'APPLESCRIPT' >/dev/null
set u to short user name of (system info)
set dev to system attribute "TESTFS_DEV"
do shell script "/usr/sbin/chown " & quoted form of u & " " & quoted form of dev with administrator privileges
APPLESCRIPT

BSD="${DEV#/dev/}"
echo "Allocated $DEV (image $IMG, bsdName=$BSD)"

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
# Mount succeeded — clear the alloc cleanup trap so the script's
# normal exit doesn't detach the device that's now backing the mount.
trap - EXIT
mount | grep "$MNT" || true

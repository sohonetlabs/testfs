#!/bin/bash
# Unmount a testfs mount point and detach its backing /dev/diskN.
# Usage: scripts/unmount.sh [mountpoint]
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"

if [ "${1:-}" = "--version" ] || [ "${1:-}" = "-v" ]; then
    VERSION=$(tr -d '[:space:]' < "$REPO/VERSION")
    BUILD=$(tr -d '[:space:]' < "$REPO/.build_number" 2>/dev/null || echo 0)
    echo "TestFS $VERSION (build $BUILD)"
    exit 0
fi

MNT="${1:-/tmp/testfs}"
MNT_ABS="$(perl -MCwd=abs_path -le 'print abs_path(shift)' "$MNT" 2>/dev/null || echo "$MNT")"

# Look up the device backing this mount BEFORE unmounting.
DEV=$(mount | awk -v m="$MNT_ABS" '$3 == m { print $1 }')
BSD=""
if [ -n "$DEV" ]; then
    BSD="${DEV#/dev/}"
fi

if [ -n "$DEV" ]; then
    echo "Unmounting $MNT_ABS (dev $DEV)"
    umount "$MNT_ABS" || true
fi

# Clean up the per-device sidecar + staged tree JSON in the extension's
# container.
if [ -n "$BSD" ]; then
    CONTAINER_DIR="$HOME/Library/Containers/com.sohonet.testfsmount.appex/Data/Library/Application Support/TestFS"
    rm -f "$CONTAINER_DIR/active-$BSD.json" "$CONTAINER_DIR/tree-$BSD.json"
fi

# Detach the dummy disk image if it's attached and nothing else uses it.
IMG="$HOME/Library/Application Support/TestFS/dummy.img"
IMG_DEV=$(hdiutil info 2>/dev/null \
    | awk -v img="$IMG" '
        /^image-path/ { path = $3; for (i=4; i<=NF; i++) path = path " " $i }
        /^\/dev\/disk/ && path == img { print $1; exit }
    ')
if [ -n "$IMG_DEV" ] && ! mount | grep -q "^$IMG_DEV "; then
    echo "Detaching $IMG_DEV"
    hdiutil detach "$IMG_DEV" || true
fi

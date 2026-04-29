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

# The host writes one image per mount under TestFS/dummies/, so we
# can't match by a fixed filename — resolve the device through the
# mount table instead, then sweep stragglers by image directory.
if [ -n "$DEV" ]; then
    echo "Detaching $DEV"
    hdiutil detach "$DEV" || true
fi

# Sweep orphan attachments: anything under TestFS/dummies/ that's
# still attached but no longer mounted (left over from previous
# unclean unmounts or app-driven mounts that never ran this script).
DUMMIES_DIR="$HOME/Library/Application Support/TestFS/dummies/"
hdiutil info 2>/dev/null \
    | awk -v dir="$DUMMIES_DIR" '
        /^image-path/ { path = $3; for (i=4; i<=NF; i++) path = path " " $i }
        /^\/dev\/disk/ && index(path, dir) == 1 { print $1 "\t" path }
    ' \
    | while IFS=$'\t' read -r dev img_path; do
        [ -z "$dev" ] && continue
        if ! mount | grep -q "^$dev "; then
            echo "Detaching orphan $dev ($img_path)"
            hdiutil detach "$dev" || true
        fi
    done

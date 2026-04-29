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
# Parse `hdiutil info -plist` instead of the text format — the
# text-format `image-path` token is unreliable on newer macOS
# versions, and the app-side sweep (MountManager.attachedImagePaths)
# already moved to plistlib for the same reason.
DUMMIES_DIR="$HOME/Library/Application Support/TestFS/dummies/"
# Static python body; pass field values via env vars, never inline-
# interpolate from the shell. Same invariant as scripts/mount.sh.
# system-entities[0] is the whole-disk entry — TestFS dummy images
# are raw files (mkfile + hdiutil attach -nomount), so they have no
# slice table and the first entry is the only entry.
DUMMIES_DIR="$DUMMIES_DIR" /usr/bin/python3 -c '
import os, plistlib, subprocess, sys
info = subprocess.run(
    ["/usr/bin/hdiutil", "info", "-plist"],
    capture_output=True, check=False
)
if info.returncode != 0:
    sys.exit(0)
data = plistlib.loads(info.stdout)
prefix = os.environ["DUMMIES_DIR"]
for image in data.get("images", []):
    path = image.get("image-path", "")
    if not path.startswith(prefix):
        continue
    for entity in image.get("system-entities", []):
        dev = entity.get("dev-entry", "")
        if dev:
            print(f"{dev}\t{path}")
            break
' \
    | while IFS=$'\t' read -r dev img_path; do
        [ -z "$dev" ] && continue
        if ! mount | grep -q "^$dev "; then
            echo "Detaching orphan $dev ($img_path)"
            hdiutil detach "$dev" || true
        fi
    done

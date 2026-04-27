#!/bin/bash
# Create (if needed) and attach a 100MB raw dummy block device in
# ~/Library/Application Support/TestFS/ for testfs to mount against.
# FSKit V1 requires a block device source even when the extension ignores it.
# Prints the device node (/dev/diskN) on stdout.
set -euo pipefail

IMG_DIR="$HOME/Library/Application Support/TestFS"
IMG="$IMG_DIR/dummy.img"

mkdir -p "$IMG_DIR"

if [ ! -f "$IMG" ]; then
    echo "Creating 100MB raw disk image at $IMG" >&2
    mkfile -n 100m "$IMG"
fi

# If the image is already attached, reuse the existing node.
EXISTING=$(hdiutil info 2>/dev/null \
    | awk -v img="$IMG" '
        /^image-path/ { path = $3; for (i=4; i<=NF; i++) path = path " " $i }
        /^\/dev\/disk/ && path == img { print $1; exit }
    ')

if [ -n "$EXISTING" ]; then
    echo "$EXISTING"
    exit 0
fi

# Attach fresh.
DEV=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount "$IMG" \
    | awk 'NR==1 {print $1}')

if [ -z "$DEV" ]; then
    echo "FAIL: hdiutil did not return a device node" >&2
    exit 1
fi

# Chown so mount -F can be run as the current user (mount -F under sudo
# fails because fskitd's audit-token check rejects uid 0 against a
# user-owned dev node). Use osascript so the admin prompt comes up as
# a GUI dialog rather than a terminal sudo, which lets us drive this
# non-interactively from outside a tty.
osascript -e "do shell script \"chown $USER $DEV\" with administrator privileges" >/dev/null

echo "$DEV"

#!/bin/bash
# Mount the same tree-JSON fixture under both the Python reference
# (jsonfs.py via fuse-t) and the Swift port (testfs via FSKit), walk
# both mountpoints, and diff the listings. Exits 0 on match, nonzero
# on divergence. Cleans up both mounts on any exit path.
#
# Usage:
#   scripts/compare/compare.sh path/to/tree.json
#
# Prereqs:
#   - venv at repo root with fusepy installed
#       python3 -m venv venv && venv/bin/pip install -r research/test_json_fs/requirements/requirements.txt
#   - fuse-t installed (brew install macos-fuse-t/cask/fuse-t)
#   - TestFS app installed and FSKit extension toggled on
#       scripts/install.sh (then enable in System Settings)
#
# Comparison axes (matching the parity-suite design choices):
#   - byte-accurate filenames + tree shape (find -print0 | sort -z)
#   - per-path attrs: type, mode, size, uid, gid, mtime (stat -f)
# Not yet covered:
#   - file-content byte parity (deferred)
#   - lookup edge cases / normalization probes (deferred)
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO"

if [ $# -ne 1 ]; then
    echo "usage: $0 path/to/tree.json" >&2
    exit 2
fi

FIXTURE="$1"
if [ ! -f "$FIXTURE" ]; then
    echo "FAIL: fixture not found: $FIXTURE" >&2
    exit 2
fi
FIXTURE_ABS="$(perl -MCwd=abs_path -le 'print abs_path(shift)' "$FIXTURE")"
FIXTURE_NAME="$(basename "$FIXTURE_ABS")"

# ---- preflight: TestFS app installed ---------------------------------------
if ! [ -d /Applications/TestFS.app ]; then
    echo "FAIL: /Applications/TestFS.app not installed. Run scripts/install.sh first." >&2
    exit 1
fi

PY_MNT="/tmp/parity-py-$$"
SW_MNT="/tmp/parity-sw-$$"
# Used for mount-table grepping. /tmp is a symlink to /private/tmp on
# macOS, so `mount(8)` reports the canonical path; the literal $PY_MNT
# string never appears. The unique-per-PID suffix is the dependable
# match key.
PY_MNT_TAG="parity-py-$$"
SW_MNT_TAG="parity-sw-$$"
OUT_DIR="$REPO/build/parity"
mkdir -p "$OUT_DIR"
PY_LIST="$OUT_DIR/$FIXTURE_NAME.py.list"
SW_LIST="$OUT_DIR/$FIXTURE_NAME.sw.list"
DIFF_OUT="$OUT_DIR/$FIXTURE_NAME.diff"

PY_PID=""
cleanup() {
    set +e
    if [ -n "$PY_PID" ]; then
        kill "$PY_PID" 2>/dev/null
    fi
    if mount | grep -q "/$PY_MNT_TAG "; then
        umount "$PY_MNT" 2>/dev/null || diskutil unmount force "$PY_MNT" 2>/dev/null
    fi
    if mount | grep -q "/$SW_MNT_TAG "; then
        "$REPO/scripts/unmount.sh" "$SW_MNT" 2>/dev/null
    fi
    rmdir "$PY_MNT" 2>/dev/null
    rmdir "$SW_MNT" 2>/dev/null
}
trap cleanup EXIT

# ---- mount Python via fuse-t ------------------------------------------------
mkdir -p "$PY_MNT"
echo "[py] mounting $FIXTURE_NAME at $PY_MNT"
PY_LOG="$OUT_DIR/$FIXTURE_NAME.py.mountlog"
"$REPO/venv/bin/python" "$REPO/research/test_json_fs/jsonfs.py" \
    "$FIXTURE_ABS" "$PY_MNT" \
    --uid "$(id -u)" --gid "$(id -g)" --mtime 2017-10-17 \
    --log-to-syslog \
    > "$PY_LOG" 2>&1 &
PY_PID=$!
# Poll for the mount to become visible. fuse-t is async; without a wait
# the listing below races against the mount syscall and returns empty.
# 30s ceiling tolerates the larger archive_torture / naughty-strings
# fixtures (10K+ entries) whose path_map build dwarfs the kernel-mount
# step; bump it further if a future fixture crosses 100K entries.
for _ in $(seq 1 60); do
    if mount | grep -q "/$PY_MNT_TAG "; then break; fi
    sleep 0.5
done
if ! mount | grep -q "/$PY_MNT_TAG "; then
    echo "FAIL: python mount never appeared at $PY_MNT" >&2
    if [ -s "$PY_LOG" ]; then
        echo "Last lines from python:" >&2
        tail -20 "$PY_LOG" >&2
    fi
    exit 1
fi
# Mount worked — keep the log around only on later failure for triage.
rm -f "$PY_LOG"

# ---- mount Swift via existing scripts ---------------------------------------
mkdir -p "$SW_MNT"
echo "[sw] mounting $FIXTURE_NAME at $SW_MNT"
SW_LOG="$OUT_DIR/$FIXTURE_NAME.sw.mountlog"
if ! "$REPO/scripts/mount.sh" "$FIXTURE_ABS" "$SW_MNT" > "$SW_LOG" 2>&1; then
    if grep -q "is disabled" "$SW_LOG"; then
        cat >&2 <<EOF
FAIL: TestFS FSKit extension is not enabled.

Open System Settings -> General -> Login Items & Extensions ->
File System Extensions, and toggle TestFS on. Then re-run.

  open "x-apple.systempreferences:com.apple.LoginItems-Settings.extension?Extensions"
EOF
        exit 1
    fi
    echo "FAIL: scripts/mount.sh exited nonzero. Last lines:" >&2
    tail -10 "$SW_LOG" >&2
    exit 1
fi
if ! mount | grep -q "/$SW_MNT_TAG "; then
    echo "FAIL: swift mount never appeared at $SW_MNT" >&2
    tail -10 "$SW_LOG" >&2
    exit 1
fi
rm -f "$SW_LOG"

# ---- walk + stat both, in identical formats ---------------------------------
# `find -print0 | sort -z` is byte-faithful: filenames with spaces, newlines,
# or unicode all round-trip cleanly. xargs -0 then feeds null-separated
# paths into a single stat invocation.
walk() {
    local mnt="$1" out="$2"
    (cd "$mnt" && find . -print0 | sort -z \
        | xargs -0 stat -f '%N|%p|%z|%u|%g|%m') > "$out"
}

walk "$PY_MNT" "$PY_LIST"
walk "$SW_MNT" "$SW_LIST"

# ---- diff -------------------------------------------------------------------
if diff -u "$PY_LIST" "$SW_LIST" > "$DIFF_OUT"; then
    PY_LINES=$(wc -l < "$PY_LIST" | tr -d ' ')
    echo "PASS: $FIXTURE_NAME  ($PY_LINES entries)"
    rm -f "$DIFF_OUT"
    exit 0
else
    echo "FAIL: $FIXTURE_NAME  (see $DIFF_OUT)"
    head -40 "$DIFF_OUT"
    exit 1
fi

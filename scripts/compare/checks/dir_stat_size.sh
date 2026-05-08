#!/bin/bash
# Bug A regression test — directory `st_size` parity with Python.
#
# What the bug was: TestFSVolume.swift's `buildAttributes` returned
# `attrs.size = 0` (and `allocSize = 0`) for directory items. Python
# `jsonfs.py` returns `st_size = 4096` for directories — one volume
# block. Tools that look at directory sizes saw 0 instead of 4096.
#
# What this script asserts: after mounting `test.json` as testfs,
# every directory entry's reported size matches what Python reports
# under the same options. Pre-fix the Swift dir lines were
# `40555|0|...`; Python's were `40555|4096|...`. Post-fix Swift
# matches Python and this script passes.
#
# Pass: directory size columns match between python and swift listings.
# Fail: any divergence; or the underlying mount/walk failed.
#
# Side effect: fires one osascript admin prompt (mount.sh chowns the
# dummy dev node). One per invocation.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$REPO"

PY="$REPO/build/parity/test.json.py.list"
SW="$REPO/build/parity/test.json.sw.list"

# Refresh artifacts so the assertion can't pass on stale output from a
# prior run.
rm -f "$PY" "$SW" "$REPO/build/parity/test.json.diff"

# Run compare.sh; we expect it to exit nonzero (other parity bugs
# remain) but it MUST produce both listings. If it fails before
# reaching the walk step, the artifacts won't exist and we abort.
"$REPO/scripts/compare/compare.sh" \
    research/test_json_fs/example/test.json \
    >/dev/null 2>&1 || true

if [ ! -s "$PY" ] || [ ! -s "$SW" ]; then
    echo "FAIL: compare.sh did not produce listings (mount/walk failed)"
    exit 2
fi

# Directory lines have a permission column starting with `40` (S_IFDIR
# in stat -f '%p' octal output is `40<mode>`). Pull (path, size) pairs
# from each side; both lists are already sorted. Write to files so the
# count comes from the file, not `echo` on a shell var (which would
# report `1` line for empty input).
PY_DIRS=$(mktemp)
SW_DIRS=$(mktemp)
trap 'rm -f "$PY_DIRS" "$SW_DIRS"' EXIT

awk -F'|' '$2 ~ /^40/ {print $1"|"$3}' "$PY" > "$PY_DIRS"
awk -F'|' '$2 ~ /^40/ {print $1"|"$3}' "$SW" > "$SW_DIRS"

py_count=$(wc -l < "$PY_DIRS" | tr -d ' ')
if [ "$py_count" = "0" ]; then
    echo "FAIL: no directory rows found in python listing (filter regression?)"
    exit 2
fi

if cmp -s "$PY_DIRS" "$SW_DIRS"; then
    echo "PASS: $py_count directory entries match on size column"
    exit 0
else
    echo "FAIL: directory size column diverges"
    diff "$PY_DIRS" "$SW_DIRS"
    exit 1
fi

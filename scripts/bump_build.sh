#!/bin/bash
# Increments the .build_number file at the repo root by 1, writes it
# back, and prints the new value on stdout. Used by the TestFS
# Xcode target's "Bump build number" Run Script phase to give every
# build a fresh CFBundleVersion, and by `mount.sh --version` (and
# friends) so the CLI prints the same number the bundled app shows.
#
# Hidden-file name (`.build_number`) avoids clashing with the
# Xcode-managed `build/` directory at the repo root.
#
# Idempotent shape: read, +1, write, echo. Safe to run from any cwd.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
BUILD_FILE="$ROOT/.build_number"

current=0
if [ -f "$BUILD_FILE" ]; then
    current=$(cat "$BUILD_FILE" | tr -d '[:space:]')
fi
case "$current" in
    *[!0-9]*) current=0 ;;
    "") current=0 ;;
esac

new=$((current + 1))
echo "$new" > "$BUILD_FILE"
echo "$new"

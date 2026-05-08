#!/bin/bash
# Parity-test driver — option matrix edition.
#
# Mounts each tree-JSON fixture under both the Python reference (jsonfs.py
# via fuse-t) and the Swift port (testfs via FSKit) under multiple
# option-sets, walks both, and diffs the listings. The matrix exposes
# divergences that are hidden when only the default options are tested
# (e.g., NFD-equal sibling collisions only matter when normalization is
# enabled; cache-file dedup only matters when add_macos_cache_files=true).
#
# Architecture: one shared dummy dev node (single admin prompt at start),
# then for each (option-set, fixture) cell we swap the staged sidecar
# JSON, mount + walk + diff, and unmount before the next cell. FSKit's
# loadResource reads the sidecar fresh on each mount, so per-cell
# options take effect cleanly.
#
# Output layout:
#   build/parity/<fixture>/<option-key>.py.list
#   build/parity/<fixture>/<option-key>.sw.list
#   build/parity/<fixture>/<option-key>.diff       (only if non-empty)
#   build/parity/<fixture>/<option-key>.sw.err     (only on Swift mount fail)
#   build/parity/<fixture>/<option-key>.py.mountlog (only on Python mount fail)
#   build/parity/summary.txt                       (per-cell PASS/FAIL list)
#
# Skipped fixtures: imdbfslayout.json.zip (zip, not JSON) and
# generate_archive_torture.py (generator).
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO"

EXAMPLES="$REPO/research/test_json_fs/example"
OUT_DIR="$REPO/build/parity"
SUMMARY="$OUT_DIR/summary.txt"
SIDECAR_HELPER="$REPO/scripts/compare/_write_sidecar.py"

mkdir -p "$OUT_DIR"
: > "$SUMMARY"

# ---- preflight --------------------------------------------------------------
[ -d /Applications/TestFS.app ] || { echo "FAIL: install /Applications/TestFS.app first (scripts/install.sh)" >&2; exit 1; }
[ -x "$REPO/venv/bin/python" ]   || { echo "FAIL: venv missing. Run: python3 -m venv venv && venv/bin/pip install -r research/test_json_fs/requirements/requirements.txt" >&2; exit 1; }
[ -x "$SIDECAR_HELPER" ]         || { echo "FAIL: $SIDECAR_HELPER not executable" >&2; exit 1; }

# ---- allocate one shared dev node ------------------------------------------
DUMMIES_DIR="$HOME/Library/Application Support/TestFS/dummies"
mkdir -p "$DUMMIES_DIR"
UUID=$(/usr/bin/uuidgen)
IMG="$DUMMIES_DIR/parity-suite-$UUID.img"
DEV=""
SW_MNT="/tmp/parity-sw-$$"
PY_MNT="/tmp/parity-py-$$"
PY_PID=""
SW_MNT_TAG="parity-sw-$$"
PY_MNT_TAG="parity-py-$$"

cleanup() {
    set +e
    if [ -n "$PY_PID" ]; then kill "$PY_PID" 2>/dev/null; fi
    if mount | grep -q "/$PY_MNT_TAG "; then
        umount "$PY_MNT" 2>/dev/null || diskutil unmount force "$PY_MNT" 2>/dev/null
    fi
    if mount | grep -q "/$SW_MNT_TAG "; then
        umount "$SW_MNT" 2>/dev/null || diskutil unmount force "$SW_MNT" 2>/dev/null
    fi
    if [ -n "$DEV" ]; then
        hdiutil detach "$DEV" -quiet 2>/dev/null || true
    fi
    rm -f "$IMG"
    rmdir "$SW_MNT" "$PY_MNT" 2>/dev/null
}
trap cleanup EXIT

mkfile -n 100m "$IMG"
DEV=$(/usr/bin/hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$IMG" \
    | awk '/\/dev\// {print $1; exit}')
[ -n "$DEV" ] || { echo "FAIL: hdiutil did not return a device node" >&2; exit 1; }
BSD="${DEV#/dev/}"
echo "Allocated $DEV (bsdName=$BSD)"

echo "Authenticating once for the suite (admin needed to chown $DEV)..."
TESTFS_DEV="$DEV" osascript <<'APPLESCRIPT' >/dev/null
set u to short user name of (system info)
set dev to system attribute "TESTFS_DEV"
do shell script "/usr/sbin/chown " & quoted form of u & " " & quoted form of dev with administrator privileges
APPLESCRIPT

CONTAINER_DIR="$HOME/Library/Containers/com.sohonet.testfsmount.appex/Data/Library/Application Support/TestFS"
mkdir -p "$CONTAINER_DIR"
TREE="$CONTAINER_DIR/tree-$BSD.json"
SIDECAR="$CONTAINER_DIR/active-$BSD.json"

mkdir -p "$SW_MNT" "$PY_MNT"

# ---- the matrix -------------------------------------------------------------
# 5 normalizations × 2 cache-files × 2 ignore-appledouble = 20 option-sets.
# Each is a 4-tuple: option-key, normalization, add_macos_cache_files, ignore_appledouble.
NORMS=(NFD NFC NFKD NFKC none)
CACHES=(true false)
APPLEDOUBLES=(false true)

CELL_TOTAL=0
CELL_PASS=0
CELL_FAIL=0
declare -a CELL_FAILS=()

for norm in "${NORMS[@]}"; do
    norm_lc=$(echo "$norm" | tr '[:upper:]' '[:lower:]')
    for cache in "${CACHES[@]}"; do
        cache_key="cache"; [ "$cache" = "false" ] && cache_key="nocache"
        for ad in "${APPLEDOUBLES[@]}"; do
            ad_key="noad"; [ "$ad" = "true" ] && ad_key="ad"
            opt_key="${norm_lc}-${cache_key}-${ad_key}"

            # Python CLI args mirroring this option-set.
            py_args=(
                --uid "$(id -u)"
                --gid "$(id -g)"
                --mtime 2017-10-17
                --unicode-normalization "$norm"
                --log-to-syslog
            )
            [ "$cache" = "false" ] && py_args+=(--no-macos-cache-files)
            [ "$ad" = "true" ]     && py_args+=(--ignore-appledouble)

            # Swift sidecar env vars (consumed by _write_sidecar.py).
            export TESTFS_UID="$(id -u)"
            export TESTFS_GID="$(id -g)"
            export TESTFS_MTIME=2017-10-17
            export TESTFS_UNICODE_NORMALIZATION="$norm"
            export TESTFS_ADD_MACOS_CACHE_FILES="$cache"
            export TESTFS_IGNORE_APPLEDOUBLE="$ad"

            for fixture in "$EXAMPLES"/*.json; do
                name="$(basename "$fixture")"
                CELL_TOTAL=$((CELL_TOTAL + 1))
                fix_dir="$OUT_DIR/$name"
                mkdir -p "$fix_dir"
                py_list="$fix_dir/$opt_key.py.list"
                sw_list="$fix_dir/$opt_key.sw.list"
                diff_out="$fix_dir/$opt_key.diff"
                py_log="$fix_dir/$opt_key.py.mountlog"
                sw_err="$fix_dir/$opt_key.sw.err"

                # Stage tree + sidecar for Swift.
                cp "$fixture" "$TREE"
                export TESTFS_CONFIG="$TREE"
                export TESTFS_VOLUME_NAME="$(basename "$fixture" .json)"
                "$SIDECAR_HELPER" "$SIDECAR"

                # Mount Swift.
                if ! mount -F -t testfs "$DEV" "$SW_MNT" 2>"$sw_err"; then
                    echo "FAIL  $opt_key  $name  (swift mount failed)"
                    CELL_FAIL=$((CELL_FAIL + 1))
                    CELL_FAILS+=("$opt_key:$name:swift-mount")
                    continue
                fi
                rm -f "$sw_err"

                # Mount Python (background).
                "$REPO/venv/bin/python" "$REPO/research/test_json_fs/jsonfs.py" \
                    "$fixture" "$PY_MNT" "${py_args[@]}" \
                    > "$py_log" 2>&1 &
                PY_PID=$!
                py_ready=0
                for _ in $(seq 1 60); do
                    if mount | grep -q "/$PY_MNT_TAG "; then py_ready=1; break; fi
                    sleep 0.5
                done
                if [ "$py_ready" -ne 1 ]; then
                    echo "FAIL  $opt_key  $name  (python mount never appeared)"
                    umount "$SW_MNT" 2>/dev/null
                    kill "$PY_PID" 2>/dev/null; PY_PID=""
                    CELL_FAIL=$((CELL_FAIL + 1))
                    CELL_FAILS+=("$opt_key:$name:python-mount")
                    continue
                fi
                rm -f "$py_log"

                # Walk both.
                (cd "$PY_MNT" && find . -print0 | sort -z | xargs -0 stat -f '%N|%p|%z|%u|%g|%m') > "$py_list" 2>/dev/null
                (cd "$SW_MNT" && find . -print0 | sort -z | xargs -0 stat -f '%N|%p|%z|%u|%g|%m') > "$sw_list" 2>/dev/null

                # Tear down both.
                umount "$PY_MNT" 2>/dev/null || diskutil unmount force "$PY_MNT" 2>/dev/null || true
                kill "$PY_PID" 2>/dev/null; wait "$PY_PID" 2>/dev/null; PY_PID=""
                umount "$SW_MNT" 2>/dev/null || diskutil unmount force "$SW_MNT" 2>/dev/null || true

                # Diff.
                if diff -u "$py_list" "$sw_list" > "$diff_out"; then
                    rm -f "$diff_out"
                    CELL_PASS=$((CELL_PASS + 1))
                else
                    CELL_FAIL=$((CELL_FAIL + 1))
                    CELL_FAILS+=("$opt_key:$name:diff")
                fi
            done
            # Per-set tally line.
            echo "[set $opt_key] done"
        done
    done
done

# ---- summary ----------------------------------------------------------------
{
    echo "Cells: $CELL_TOTAL total, $CELL_PASS passed, $CELL_FAIL failed"
    echo ""
    if [ ${#CELL_FAILS[@]} -gt 0 ]; then
        echo "Failures (option-key:fixture:cause):"
        printf '  %s\n' "${CELL_FAILS[@]}"
    fi
} | tee "$SUMMARY"

exit "$CELL_FAIL"

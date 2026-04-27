#!/bin/bash
#
# copy_examples.sh
#
# Mirrors the vendored Python repo's example/ directory into the
# host app bundle's Contents/Resources/Examples/. Run by the
# Xcode "Copy Examples to Resources" Run Script Phase before the
# Copy Bundle Resources step.
#
# Inputs from Xcode environment:
#   SRCROOT             — repo root
#   BUILT_PRODUCTS_DIR  — DerivedData build dir
#   WRAPPER_NAME        — TestFS.app
#
# Filters out non-fixture clutter the example/ dir tends to
# accumulate (Finder metadata, ad-hoc local mountpoints, the
# generator script).
#

set -euo pipefail

SRC="$SRCROOT/research/test_json_fs/example"
DST="$BUILT_PRODUCTS_DIR/$WRAPPER_NAME/Contents/Resources/Examples"

if [ ! -d "$SRC" ]; then
    echo "error: $SRC missing — has the submodule been initialised?" >&2
    exit 1
fi

mkdir -p "$DST"

rsync -a --delete \
    --exclude='.DS_Store' \
    --exclude='foo' \
    --exclude='testmount' \
    --exclude='test_mount_2' \
    --exclude='generate_archive_torture.py' \
    "$SRC/" "$DST/"

cat > "$DST/README.md" <<'EOF'
# TestFS example trees

Each `.json` file in this folder describes a virtual filesystem.
Pick one in TestFS via **File ▸ Try an example…** (or
**Choose JSON…**), pick an empty mountpoint, and click **Mount**.

| File | What it demonstrates |
|---|---|
| `test.json` | Basic 10-file demo |
| `32bit_tests.json` | Files at 32-bit signed/unsigned size boundaries |
| `bad_s3.json` | Filenames that break Amazon S3 |
| `bad_windows.json` | Filenames that break Windows |
| `bad_windows_extended.json` | Extended Windows-bad filename set |
| `big_list_of_naughty_strings_fs.json` | Unicode/edge name fuzzing |
| `tartest_test_dir_spacing.json` | Many directories, even spacing |
| `tartest_test_one_dir.json` | Many files in one directory |
| `archive_torture_evil_filenames.json` | Archive torture: evil names |
| `archive_torture_filename_lengths.json` | Archive torture: name-length boundaries |
| `archive_torture_format_sentinels.json` | Archive torture: format-detection sentinels |
| `archive_torture_mojibake_traps.json` | Archive torture: encoding traps |
| `archive_torture_path_lengths.json` | Archive torture: path-length boundaries |
| `archive_torture_size_boundaries_large.json` | Archive torture: large-file boundaries |
| `archive_torture_size_boundaries_medium.json` | Archive torture: medium-file boundaries |
| `archive_torture_size_boundaries_small.json` | Archive torture: small-file boundaries |
| `imdbfslayout.json.zip` | 460k-file IMDB dataset (zipped — `unzip` first) |

The IMDB layout ships zipped because it's ~265 GB of virtual
content and the JSON itself is 6 MB. Unzip before mounting.
EOF

echo "copied $(ls "$DST" | wc -l | tr -d ' ') items into $DST"

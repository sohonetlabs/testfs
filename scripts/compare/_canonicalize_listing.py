#!/usr/bin/env python3
"""
NFC-canonicalize the name column of a parity-listing on stdin.

The parity matrix walks each mounted filesystem with `find` + `stat -f
'%N|%p|%z|%u|%g|%m'`, which gives `path|mode|size|uid|gid|mtime`. macOS
HFS+/APFS-style canonicalization runs at the VFS layer for FUSE-T
mounts but not for FSKit mounts: the same JSON-source name surfaces as
NFD via Python's mount and as the original (typically NFC) bytes via
our extension's mount. Both are faithful to the JSON contract; only
the kernel-display form differs.

This filter rewrites just the leading name column to NFC form so a
post-hoc diff can recognise "byte sequences differ but canonicalise to
the same codepoint" as a non-divergence. Mode/size/mtime/etc. fields
pass through untouched so attribute mismatches still surface.
"""

import sys
import unicodedata


def main() -> None:
    for line in sys.stdin:
        # Trailing newline preserved on output to keep diff clean.
        stripped = line.rstrip("\n")
        if not stripped:
            sys.stdout.write(line)
            continue
        # Only the FIRST `|` separates the name from the attribute
        # tail. Filenames may legitimately contain `|`; split with
        # maxsplit=1.
        parts = stripped.split("|", 1)
        name = parts[0]
        rest = parts[1] if len(parts) > 1 else ""
        nfc_name = unicodedata.normalize("NFC", name)
        if rest:
            sys.stdout.write(f"{nfc_name}|{rest}\n")
        else:
            sys.stdout.write(f"{nfc_name}\n")


if __name__ == "__main__":
    main()

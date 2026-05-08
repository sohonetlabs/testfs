#!/usr/bin/env python3
"""Write a Swift TestFS sidecar JSON file.

Reads option values from environment variables (so bash callers don't
have to quote tricky values like a NUL fill char), validates them, and
writes the resulting JSON to the path given as the single CLI argument.

This is the parity test harness's escape hatch from bash quoting. The
end-user mount script (scripts/mount.sh) writes a minimal sidecar with
just `config` and `volume_name`; the parity matrix needs to vary the
full option surface, which is easier to express in Python.

Required env vars:
  TESTFS_CONFIG                   path to the staged tree JSON
  TESTFS_VOLUME_NAME              display name for the volume

Optional env vars (all map onto MountOptions sidecar fields):
  TESTFS_UNICODE_NORMALIZATION    NFC | NFD | NFKC | NFKD | none
  TESTFS_ADD_MACOS_CACHE_FILES    true | false
  TESTFS_IGNORE_APPLEDOUBLE       true | false
  TESTFS_MTIME                    YYYY-MM-DD or full ISO 8601
  TESTFS_UID                      integer
  TESTFS_GID                      integer
  TESTFS_FILL_CHAR                single character (or \\0 for NUL)
  TESTFS_SEMI_RANDOM              true | false
  TESTFS_BLOCK_SIZE               e.g. "128K"
  TESTFS_PRE_GENERATED_BLOCKS     integer
  TESTFS_SEED                     integer
  TESTFS_VERBOSE                  true | false
  TESTFS_REPORT_STATS             true | false
  TESTFS_ATTEMPT_TOKEN            UUID string
"""

import json
import os
import sys


def env_str(name):
    val = os.environ.get(name)
    return val if val else None


def env_bool(name):
    val = os.environ.get(name)
    if val is None or val == "":
        return None
    if val.lower() in ("true", "1", "yes"):
        return True
    if val.lower() in ("false", "0", "no"):
        return False
    raise SystemExit(f"FAIL: {name} must be true/false, got {val!r}")


def env_int(name):
    val = os.environ.get(name)
    if val is None or val == "":
        return None
    try:
        return int(val)
    except ValueError:
        raise SystemExit(f"FAIL: {name} must be an integer, got {val!r}")


def env_fill_char(name):
    val = os.environ.get(name)
    if val is None or val == "":
        return None
    if val == r"\0":
        return "\x00"
    if len(val) != 1:
        raise SystemExit(f"FAIL: {name} must be exactly one character, got {val!r}")
    return val


def main():
    if len(sys.argv) != 2:
        print("usage: _write_sidecar.py <output-path>", file=sys.stderr)
        sys.exit(2)
    out_path = sys.argv[1]

    config = env_str("TESTFS_CONFIG")
    volume_name = env_str("TESTFS_VOLUME_NAME")
    if not config or not volume_name:
        print("FAIL: TESTFS_CONFIG and TESTFS_VOLUME_NAME are required", file=sys.stderr)
        sys.exit(2)

    sidecar = {
        "config": config,
        "volume_name": volume_name,
    }

    optional = {
        "unicode_normalization": env_str("TESTFS_UNICODE_NORMALIZATION"),
        "add_macos_cache_files": env_bool("TESTFS_ADD_MACOS_CACHE_FILES"),
        "ignore_appledouble": env_bool("TESTFS_IGNORE_APPLEDOUBLE"),
        "mtime": env_str("TESTFS_MTIME"),
        "uid": env_int("TESTFS_UID"),
        "gid": env_int("TESTFS_GID"),
        "fill_char": env_fill_char("TESTFS_FILL_CHAR"),
        "semi_random": env_bool("TESTFS_SEMI_RANDOM"),
        "block_size": env_str("TESTFS_BLOCK_SIZE"),
        "pre_generated_blocks": env_int("TESTFS_PRE_GENERATED_BLOCKS"),
        "seed": env_int("TESTFS_SEED"),
        "verbose": env_bool("TESTFS_VERBOSE"),
        "report_stats": env_bool("TESTFS_REPORT_STATS"),
        "attempt_token": env_str("TESTFS_ATTEMPT_TOKEN"),
    }
    for key, value in optional.items():
        if value is not None:
            sidecar[key] = value

    with open(out_path, "w") as fh:
        json.dump(sidecar, fh, indent=2, sort_keys=True)
        fh.write("\n")


if __name__ == "__main__":
    main()

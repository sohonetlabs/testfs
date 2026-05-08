# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

macOS-native port of [`sohonetlabs/test_json_fs`](https://github.com/sohonetlabs/test_json_fs) (Python + FUSE) onto **FSKit V1**. Mounts a `tree -J -s`-shaped JSON file as a read-only synthetic filesystem whose file bytes are made up on demand (fill-char or seeded pseudo-random). macOS 15.4+. The Python original is vendored at `research/test_json_fs/` as a submodule — clone with `--recurse-submodules`.

## Repo layout (the bits that aren't obvious from `ls`)

Two Xcode targets plus an SPM mirror:

- **`TestFS/`** — SwiftUI host app. **Unsandboxed** because in-process mounting needs `hdiutil` to attach a dummy raw disk image (DiskArbitration + IOKit user-client refuse this from a sandbox). Drives mounts via `MountManager`, watches the FSKit extension's enabled state, streams logs.
- **`TestFSExtension/`** — FSKit V1 block-resource extension (`.appex`). **Sandboxed**. Reads its sidecar JSON from its own container at `~/Library/Containers/com.sohonet.testfsmount.appex/Data/Library/Application Support/TestFS/`.
- **`Package.swift` + `Tests/TestFSCoreTests/`** — SPM package `TestFSCore` that re-uses the **pure-Swift** files from `TestFSExtension/` (BlockCache, BundledExamples, JSONTree, LoadFailureMarker, MountOptions, Throttle, TreeBuilder, TreeIndex). Exists purely so unit tests can run via `swift test` without an Xcode test target. The Xcode extension target compiles the same files via its synced group.

### Critical invariant: the dual-membership files must not `import FSKit`

The files listed under `TestFSCore` `sources:` in `Package.swift` are compiled into both the host app target and the extension. FSKit is only linked into the extension. Adding `import FSKit` to any of those files breaks the host build — and only on a clean rebuild, so it's easy to miss locally. Each affected file has a comment header reminding you of this; preserve it.

### Mount sidecar protocol (host ↔ extension)

The host has no IPC channel to the extension. Configuration is passed as JSON files staged in the extension's sandbox container, keyed by BSD device name so concurrent mounts on distinct `/dev/diskN` don't stomp each other:

```
~/Library/Containers/com.sohonet.testfsmount.appex/Data/Library/Application Support/TestFS/
    tree-<bsdName>.json       # copy of the user's tree JSON
    active-<bsdName>.json     # MountOptions sidecar pointing at the tree
    failure-<bsdName>.json    # LoadFailureMarker the extension drops on probe/load errors
```

`MountOptions.attemptToken` flows host → sidecar → extension → marker, so a stale failure marker from a prior `/dev/diskN` attempt can't be misattributed to a new attempt. `scripts/mount.sh` mirrors `MountManager.prepareMount`'s scheme — keep them in sync if the protocol changes.

## Build, lint, test

```bash
# Pure-Swift unit tests (fast loop — no Xcode, no FSKit)
swift test
swift test --filter TreeBuilderTests           # single test class
swift test --filter TreeBuilderTests/test_specific_method

# Full Xcode build (host + extension)
xcodebuild -project TestFS.xcodeproj -scheme TestFS \
    -configuration Debug -destination 'platform=macOS' \
    -allowProvisioningUpdates build

# Lint — release.sh runs this with --strict as a fail-fast gate
swiftlint --strict

# Install the freshly-built app, prune stale LaunchServices/pluginkit
# registrations, and deep-link to System Settings to enable the extension.
scripts/install.sh

# Smoke-check an installed copy (does NOT mount)
scripts/smoke.sh

# CLI mount/unmount
scripts/mount.sh                                 # default tree at /tmp/testfs
scripts/mount.sh path/to/tree.json /mountpoint
scripts/unmount.sh
```

Tests live in `Tests/TestFSCoreTests/` with fixture JSON in `Tests/TestFSCoreTests/Fixtures/`. `AllFixturesTests.swift` runs every fixture through the parser+builder pipeline as a regression net.

## Mounting gotchas (will bite you in scripts and tests)

- **Never run `mount.sh` under `sudo`.** `fskitd`'s audit-token check rejects uid 0 against a user-owned dev node — `mount -F` fails with EACCES. The script uses `osascript` to elevate just the `chown` step. The host app is unsandboxed for the same reason: a `hdiutil attach` done as root binds the disk-image session to root's `diskarbitrationd`, and the user's later open fails.
- **Mountpoint must not be in macOS privacy-protected directories** (Desktop / Documents / Downloads / iCloud Drive / Pictures / Movies / Music). `fskitd` is denied access there and the mount fails with *Operation not permitted*. `/tmp/...` and fresh subdirs under your home root are fine.
- **The volume is case-sensitive** (matches Python `jsonfs.py` upstream). `Foo.txt` and `foo.txt` are independent entries; lookup is byte-exact after `unicode_normalization` (default NFD) is applied.
- **`scripts/install.sh` aggressively prunes prior LaunchServices/pluginkit registrations** before installing. Don't simplify this — extensionkitd cumulates `+ enabled` entries pointing at stale UUIDs across a clone+build+release-sh round-trip, and `mount -t testfs` fails with `extensionKit.errorDomain error 2` when it picks the wrong one. The pluginkit `ignore`/`use` toggle in the same script forces a re-resolution; the *transition* (not the end state) is what matters.

## Releasing

`scripts/release.sh` handles the whole pipeline (lint → archive → export developer-id → DMG via `create-dmg` → `notarytool --wait` → staple → `spctl` assess → Sparkle Ed25519 sign → prepend appcast entry). 3–5 min wall time.

Per release: bump `VERSION`, commit, run `scripts/release.sh`, then `git tag`, push, `gh release create`, and commit the updated `appcast.xml`. README "Releasing (maintainer)" section has the full sequence and one-time keychain setup.

`VERSION` is the user-visible semver (e.g. `0.1.28`). `.build_number` is a monotonically incrementing CFBundleVersion bumped by `scripts/bump_build.sh` and is referenced by recent commits.

## Parity reference

This is a **port**, not a rewrite — behavior should track the Python original at `research/test_json_fs/jsonfs.py`. When changing semantics, default to matching the Python (defaults: `mtime=2017-10-17`, NFD normalization, null-byte fill). That submodule is also the source of `Examples/` shipped in the DMG and the fixtures used by tests.

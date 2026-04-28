# TestFS

A read-only synthetic filesystem for macOS, built on **FSKit**. Mount a
JSON tree as a filesystem whose contents are made up on demand — either a
fill character or deterministic pseudo-random bytes. Useful for testing
software against arbitrarily large directory structures without spending
the disk space.

Native Swift, no kernel extension, no `fuse-t` shim. macOS 15.4 or later
(FSKit V1 is the floor).

This is the macOS-native port of
[`sohonetlabs/test_json_fs`](https://github.com/sohonetlabs/test_json_fs)
(Python + FUSE).

## Install (end users)

1. Grab the latest `TestFS-X.Y.Z.dmg` from
   [Releases](https://github.com/sohonetlabs/testfs/releases).
2. Open the DMG and drag `TestFS.app` to the `Applications` shortcut.
   (The DMG also contains an `Examples/` folder of sample JSON trees —
   drag that to `~/Documents/` if you want them handy.)
3. Launch `/Applications/TestFS.app`. The first time, a banner asks you
   to enable the FSKit extension — click **Open System Settings…**, then
   toggle **TestFS** on under *General → Login Items & Extensions →
   File System Extensions*.
4. Pick a JSON tree (the **File ▸ Try an example…** menu opens an
   embedded set), pick an empty directory as the mountpoint, click
   **Mount**. **Avoid Desktop / Documents / Downloads / iCloud
   Drive / Pictures / Movies / Music** — macOS won't let `fskitd`
   write to those, and the mount will fail with *Operation not
   permitted*. A subdir under your home folder root or `/tmp` works.

The DMG is signed with a Developer ID Application certificate and
notarized by Apple, so Gatekeeper accepts it without warnings.

Subsequent releases install themselves: TestFS embeds
[Sparkle](https://sparkle-project.org), checks
`https://raw.githubusercontent.com/sohonetlabs/testfs/main/appcast.xml`
in the background, and prompts when a new version is available. You
can also force a check from **App ▸ Check for Updates…**.

## Build from source

```bash
git clone --recurse-submodules git@github.com:sohonetlabs/testfs.git
cd testfs
xcodebuild -project TestFS.xcodeproj -scheme TestFS \
    -configuration Debug -destination 'platform=macOS' \
    -allowProvisioningUpdates build
```

The build phase rsyncs `research/test_json_fs/example/` into
`TestFS.app/Contents/Resources/Examples/`, so the in-app picker works
straight from a `Debug` build.

If you don't have a Sohonet team signing identity, change
`DEVELOPMENT_TEAM` and the bundle IDs across both targets to your own.

## Mount from the CLI

Prerequisites: `TestFS.app` is installed (so the FSKit extension is
registered) and toggled on under *General → Login Items & Extensions
→ File System Extensions*. `scripts/smoke.sh` verifies both before
you bother trying to mount. Sample JSON trees live at
`research/test_json_fs/example/` — clone with `--recurse-submodules`.

```bash
scripts/smoke.sh                                # check the install + extension registration
scripts/mount.sh                                # mounts test.json at /tmp/testfs
scripts/mount.sh path/to/tree.json              # custom tree, default /tmp/testfs
scripts/mount.sh path/to/tree.json /mountpoint  # custom tree + mountpoint
scripts/unmount.sh                              # unmount + detach the dummy disk
```

Run as your normal user — **not** `sudo`. The `mount(8) -F` path that
FSKit V1 uses fails under sudo: `fskitd` checks the caller's audit
token uid against the dev node's owner, and the user-owned dev node
that `hdiutil` attached can't be opened by uid 0.

Mountpoint must be outside macOS's privacy-protected directories
(Desktop, Documents, Downloads, iCloud Drive, Pictures, Movies,
Music) — `fskitd` is denied access there and the mount fails with
*Operation not permitted*. The default `/tmp/testfs` and any fresh
subdir under your home folder root are fine.

## Architecture

```
TestFS.app
├── TestFS                       (SwiftUI host, unsandboxed*)
└── TestFSExtension.appex        (FSKit V1 block-resource extension,
                                  sandboxed, reads its sidecar JSON
                                  from its own container)
```

\* The host is intentionally unsandboxed because mounting in-process
needs `hdiutil` access to attach a dummy raw disk image — a path that
DiskArbitration + the IOKit user client refuse from a sandboxed
process. The FSKit extension itself is sandboxed.

## Examples

Sample JSON trees live in
[`research/test_json_fs/example/`](research/test_json_fs/example/) (a
git submodule pointing at `sohonetlabs/test_json_fs`). The
release-built DMG includes a copy of the same set under
`Examples/`. Highlights:

| File | What it demonstrates |
|---|---|
| `test.json` | 10-file basic demo |
| `bad_windows.json` / `bad_s3.json` | Names that break on those platforms |
| `big_list_of_naughty_strings_fs.json` | Unicode/edge-case fuzzing |
| `archive_torture_*.json` | Pathological inputs for archive tools |
| `imdbfslayout.json.zip` | 460k-file IMDB-shaped layout (unzip first) |

## Releasing (maintainer)

The release pipeline produces a notarized, stapled DMG containing
`TestFS.app`, an `Applications` drop-link, and the `Examples/` folder.

One-time setup on each release machine:

- `brew install create-dmg swiftlint`
- Developer ID Application certificate for team `H6XW263G62` in the
  login keychain.
- Notarization keychain profile:
  ```bash
  xcrun notarytool store-credentials testFS \
      --apple-id <your-apple-id> --team-id H6XW263G62 \
      --password <app-specific-password>
  ```
- Sparkle Ed25519 signing key. On the first machine, generate it once:
  ```bash
  $(ls -td ~/Library/Developer/Xcode/DerivedData/TestFS-*/SourcePackages/artifacts/sparkle/Sparkle/bin | head -1)/generate_keys --account testfs
  ```
  Back up the private key (e.g. via 1Password) — losing it means new
  installs would have to ship under a different bundle ID. To restore
  on a second machine, `generate_keys --account testfs -f <key-file>`.

Per release:

```bash
# Bump version
echo 0.1.4 > VERSION
git commit -am "Bump version to $(cat VERSION)"

# Build, lint-gate, sign, notarize, staple, sparkle-sign, update appcast
scripts/release.sh
# ⇒ build/TestFS-0.1.4.dmg + appcast.xml updated locally

# Tag, push code, push the new appcast, upload the DMG to a Release
git tag v$(cat VERSION)
git push --follow-tags
gh release create v$(cat VERSION) build/TestFS-$(cat VERSION).dmg \
    --notes "Release notes here"
git add appcast.xml && git commit -m "Appcast: $(cat VERSION)" && git push
```

`scripts/release.sh` runs `swiftlint --strict` first (cheap fail-fast
gate), then archives in Release configuration, exports with
`method=developer-id`, builds the DMG via `create-dmg`, submits to
`notarytool --wait`, staples, mounts the DMG to assess the embedded
app via `spctl`, signs the DMG with Sparkle's Ed25519 key, and
prepends the new entry to `appcast.xml`. Wall time is 3–5 minutes
depending on Apple's notarization queue.

## Reference implementation

The Python original is vendored at `research/test_json_fs/` as a git
submodule. See its README for the full feature list and CLI flags;
this Swift port aims for parity.

## License

[MIT](LICENSE). The port builds on Sohonet Labs' `test_json_fs` and
KhaosT's [`FSKitSample`](https://github.com/KhaosT/FSKitSample) — see
`LICENSE` for the attribution notices.

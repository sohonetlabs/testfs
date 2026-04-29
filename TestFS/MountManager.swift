//
//  MountManager.swift
//  TestFS
//
//  In-process mount setup and teardown. Runs as the user, NOT as
//  root. The host app must be unsandboxed because fskitd's
//  openWithBSDName binds the dev node open to the caller's audit
//  token, and a hdiutil-attach done as root binds the underlying
//  disk image to root's diskarbitrationd session — the user's open
//  then fails with EACCES regardless of dev-node ownership. Doing
//  hdiutil attach in-process puts the disk-image session, dev-node
//  ownership, and mount(8) invocation all under the same uid.
//

import Foundation
import OSLog

actor MountManager {
    static let shared = MountManager()

    struct PrepareResult {
        let devNodePath: String
        var bsdName: String { .bsdName(fromDevNode: devNodePath) }
    }

    private static let sidecarEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    struct MountError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static func toolError(_ tool: String, exit: Int32, stderr: String) -> MountError {
        MountError(message: "\(tool) exit \(exit): \(stderr)")
    }

    private let log = Logger(subsystem: TestFSConstants.logSubsystem, category: "mount-manager")

    /// Stage everything a successful `mount(8) -F -t testfs <dev> <mnt>`
    /// needs. Caller passes a pre-built `MountOptions`; this method
    /// owns only the mount-specific `config` field (= staged tree
    /// path) and sidecar serialization.
    func prepareMount(treeJSON: Data, options: MountOptions) throws -> PrepareResult {
        var imageURL: URL?
        var devNode: String?
        var stagedTree: URL?
        var stagedSidecar: URL?

        do {
            let imageDir = imageDirectory()
            try FileManager.default.createDirectory(
                at: imageDir, withIntermediateDirectories: true)
            let img = imageDir.appendingPathComponent("dummy-\(UUID().uuidString).img")
            imageURL = img
            try createSparseImage(at: img, sizeMB: 100)

            let dev = try hdiutilAttach(image: img)
            devNode = dev
            let bsd = String.bsdName(fromDevNode: dev)

            let extDir = extensionContainerDir()
            try FileManager.default.createDirectory(
                at: extDir, withIntermediateDirectories: true)
            let paths = sidecarPaths(forBSD: bsd)
            stagedTree = paths.tree
            stagedSidecar = paths.sidecar

            try treeJSON.write(to: paths.tree, options: .atomic)

            var sidecarOptions = options
            sidecarOptions.config = paths.tree.path
            let sidecar = try Self.sidecarEncoder.encode(sidecarOptions)
            try sidecar.write(to: paths.sidecar, options: .atomic)

            log.info("prepareMount: \(bsd, privacy: .public)")
            return PrepareResult(devNodePath: dev)
        } catch {
            if let dev = devNode { try? hdiutilDetach(devNode: dev) }
            if let img = imageURL { try? FileManager.default.removeItem(at: img) }
            if let sidecar = stagedSidecar { try? FileManager.default.removeItem(at: sidecar) }
            if let tree = stagedTree { try? FileManager.default.removeItem(at: tree) }
            log.error("prepareMount failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    func detach(bsdName: String) throws {
        var lastError: Error?
        do {
            try hdiutilDetach(devNode: "/dev/\(bsdName)")
        } catch {
            lastError = error
            let desc = error.localizedDescription
            log.error("detach hdiutil failed for \(bsdName, privacy: .public): \(desc, privacy: .public)")
        }

        let paths = sidecarPaths(forBSD: bsdName)
        try? FileManager.default.removeItem(at: paths.tree)
        try? FileManager.default.removeItem(at: paths.sidecar)

        // Image sweep is best-effort cleanup; pushing it off the
        // user-visible unmount path keeps the UI responsive.
        Task.detached(priority: .background) {
            await MountManager.shared.sweepUnreferencedImages()
        }

        if let lastError { throw lastError }
        log.info("detach: \(bsdName, privacy: .public)")
    }

    // MARK: - Paths

    private func imageDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TestFS/dummies", isDirectory: true)
    }

    /// Path of the extension's sandbox Application Support
    /// directory, hand-built from the user's home + the extension's
    /// bundle ID. This deliberately does NOT call
    /// `MountOptions.extensionContainerTestFSDir()` even though
    /// they reach the same physical directory: that helper resolves
    /// `applicationSupportDirectory` relative to the *caller's*
    /// sandbox, and the host runs unsandboxed — so from here it
    /// would point at `~/Library/Application Support/`, not the
    /// extension's container. Hand-construction is the only way
    /// to address the extension's container from outside it.
    private func extensionContainerDir() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Containers/\(TestFSConstants.extensionBundleID)/Data", isDirectory: true
            )
            .appendingPathComponent(
                "Library/Application Support/TestFS", isDirectory: true)
    }

    private func sidecarPaths(forBSD bsd: String) -> (tree: URL, sidecar: URL) {
        let dir = extensionContainerDir()
        return (
            tree: dir.appendingPathComponent("tree-\(bsd).json"),
            sidecar: dir.appendingPathComponent("active-\(bsd).json")
        )
    }

    // MARK: - hdiutil / mkfile

    private func createSparseImage(at url: URL, sizeMB: Int) throws {
        let result = ShellRunner.run("/usr/sbin/mkfile", ["-n", "\(sizeMB)m", url.path])
        guard result.exit == 0 else {
            throw Self.toolError("mkfile", exit: result.exit, stderr: result.stderr)
        }
    }

    private func hdiutilAttach(image: URL) throws -> String {
        let result = ShellRunner.run(
            "/usr/bin/hdiutil",
            [
                "attach", "-nomount",
                "-imagekey", "diskimage-class=CRawDiskImage",
                image.path
            ])
        guard result.exit == 0 else {
            throw Self.toolError("hdiutil attach", exit: result.exit, stderr: result.stderr)
        }
        guard let line = result.stdout.split(separator: "\n").first(where: { $0.contains("/dev/") }),
            let dev = line.split(separator: " ", omittingEmptySubsequences: true).first.map(String.init)
        else {
            throw MountError(message: "couldn't parse /dev/diskN from hdiutil output: \(result.stdout)")
        }
        return dev
    }

    private func hdiutilDetach(devNode: String) throws {
        let result = ShellRunner.run("/usr/bin/hdiutil", ["detach", devNode])
        guard result.exit == 0 else {
            throw Self.toolError("hdiutil detach", exit: result.exit, stderr: result.stderr)
        }
    }

    /// `mount(8)` invocation. Lives here so ContentView doesn't need
    /// to know the testfs fstype string or the `-F` raw-resource flag.
    /// On failure, log the full stdout + stderr + exit code to OSLog
    /// so the in-app log viewer captures every byte for diagnosis;
    /// the thrown MountError carries the same payload to the UI.
    ///
    /// A successful return only means `mount(8)` accepted the
    /// request and the kernel queued it. FSKit's `loadResource`
    /// runs asynchronously after that and can still fail (JSON
    /// parse error, missing config, etc.). Follow up with
    /// `confirmMountedOrRollback(prep:mountpoint:)` to verify the
    /// volume actually came up.
    func mount(devNode: String, at mountpoint: String) throws {
        let result = ShellRunner.run(
            "/sbin/mount", ["-F", "-t", TestFSConstants.fstype, devNode, mountpoint])
        guard result.exit == 0 else {
            log.error(
                """
                mount failed for \(devNode, privacy: .public) -> \
                \(mountpoint, privacy: .public): exit=\(result.exit, privacy: .public) \
                stderr=\(result.stderr, privacy: .public) \
                stdout=\(result.stdout, privacy: .public)
                """)
            throw Self.toolError("mount", exit: result.exit, stderr: result.stderr)
        }
    }

    /// 15-second ceiling. Warm-system loadResource completes in tens
    /// of ms; cold-start (post-Sparkle, post-reboot, post-TCC-prompt)
    /// can run several seconds. Set the budget high enough that we
    /// don't false-roll-back a mount that would have come up.
    private static let mountConfirmTimeout: Duration = .seconds(15)
    /// 100 ms is short enough that the success path adds barely-
    /// noticeable latency, and a single statfs syscall per tick is
    /// cheap (sub-microsecond VFS lookup).
    private static let mountConfirmPollInterval: Duration = .milliseconds(100)

    /// Verify the FSKit extension finished bringing up the volume
    /// after `mount(8)` returned. On failure, unmount + detach so
    /// we don't leave a phantom mount or an orphaned dev node.
    func confirmMountedOrRollback(prep: PrepareResult, mountpoint: String) async -> Bool {
        if await waitForMount(at: mountpoint) { return true }
        try? unmount(at: mountpoint)
        try? detach(bsdName: prep.bsdName)
        return false
    }

    /// Poll `statfs(2)` until the mountpoint reports `f_fstypename
    /// == "testfs"`, or the timeout elapses. Uses `ContinuousClock`
    /// so a sleep/wake mid-poll doesn't skew the deadline. No more
    /// reliable oracle exists on macOS 26: NSWorkspace mount and
    /// DiskArbitration "appeared" notifications fire on mount(8)
    /// accept (before FSKit's loadResource finishes), so they'd
    /// false-positive a phantom mount. statfs's `f_fstypename`
    /// flips only once the volume is actually usable.
    func waitForMount(
        at mountpoint: String,
        timeout: Duration = mountConfirmTimeout
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if Self.statfsType(at: mountpoint) == TestFSConstants.fstype {
                return true
            }
            try? await Task.sleep(for: Self.mountConfirmPollInterval)
        }
        return false
    }

    /// Read `f_fstypename` from `statfs(2)`. Returns `nil` if the
    /// path can't be statfs'd (unmounted, non-existent, permission
    /// error).
    private static func statfsType(at path: String) -> String? {
        var buf = statfs()
        guard statfs(path, &buf) == 0 else { return nil }
        // Hoist the size out of the closure so we don't re-enter
        // exclusive access on `buf` while the pointer is live.
        let capacity = MemoryLayout.size(ofValue: buf.f_fstypename)
        return withUnsafePointer(to: &buf.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: capacity) {
                String(cString: $0)
            }
        }
    }

    func unmount(at mountpoint: String) throws {
        let result = ShellRunner.run("/sbin/umount", [mountpoint])
        guard result.exit == 0 else {
            throw Self.toolError("umount", exit: result.exit, stderr: result.stderr)
        }
    }

    private func sweepUnreferencedImages() {
        let dir = imageDirectory()
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(atPath: dir.path) else { return }
        let attached = attachedImagePaths()
        for name in entries where name.hasPrefix("dummy-") && name.hasSuffix(".img") {
            let path = dir.appendingPathComponent(name).path
            if !attached.contains(path) {
                try? fileManager.removeItem(atPath: path)
            }
        }
    }

    /// Set of image-file paths currently attached, parsed from
    /// `hdiutil info -plist`. The plist form is preferred over the
    /// human-readable text format because the text format's
    /// `image-path` token also appears in unrelated headers in newer
    /// hdiutil versions.
    private func attachedImagePaths() -> Set<String> {
        let result = ShellRunner.run("/usr/bin/hdiutil", ["info", "-plist"])
        guard result.exit == 0, let data = result.stdout.data(using: .utf8) else {
            return []
        }
        guard let info = try? PropertyListDecoder().decode(HdiutilInfo.self, from: data) else {
            return []
        }
        return Set(info.images.compactMap(\.imagePath))
    }
}

/// Top-level, file-private to keep the nesting depth at 1 (SwiftLint's
/// `nesting` rule). Only `MountManager.attachedImagePaths` decodes
/// against this shape.
private struct HdiutilInfo: Decodable {
    let images: [Image]
}

private struct HdiutilInfoImage: Decodable {
    let imagePath: String?
    enum CodingKeys: String, CodingKey { case imagePath = "image-path" }
}

extension HdiutilInfo {
    typealias Image = HdiutilInfoImage
}

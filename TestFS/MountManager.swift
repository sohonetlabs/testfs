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
        /// Token written into the staged sidecar; used by the host's
        /// marker filter so a stale marker from a prior /dev/diskN
        /// attempt can't trigger rollback for this one.
        let attemptToken: String
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
    func prepareMount(treeJSON: Data, options: MountOptions) async throws -> PrepareResult {
        // Pre-flight runs off-actor so a large fixture's parse / build
        // doesn't block concurrent unmounts, sweep, or registry
        // refresh on this actor. parseAndBuild is pure, so a detached
        // task is safe.
        try await Task.detached(priority: .userInitiated) {
            _ = try TreeBuilder.parseAndBuild(treeJSON: treeJSON, options: options)
        }.value

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
            // Per-attempt token: extension writes the same value into
            // any failure marker, host filters markers on token match.
            // Defends against a slow-failing prior loadResource on a
            // reused /dev/diskN (and subsequent BSD) writing a marker
            // after stage-time delete.
            let attemptToken = UUID().uuidString
            sidecarOptions.attemptToken = attemptToken
            let sidecar = try Self.sidecarEncoder.encode(sidecarOptions)
            try sidecar.write(to: paths.sidecar, options: .atomic)

            // Stage-time clear; see failureMarkerURL doc.
            try? FileManager.default.removeItem(at: failureMarkerURL(forBSD: bsd))

            log.info("prepareMount: \(bsd, privacy: .public)")
            return PrepareResult(devNodePath: dev, attemptToken: attemptToken)
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
        try? FileManager.default.removeItem(at: failureMarkerURL(forBSD: bsdName))

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

    /// Per-BSD failure marker. Parallels
    /// `MountOptions.failureMarkerURL(forBSDName:)` on the extension
    /// side — they produce paths to the same physical file via
    /// different mechanisms, the same way `sidecarPaths` parallels
    /// `MountOptions.sidecarURL(forBSDName:)`. The host needs the
    /// hand-built `extensionContainerDir` because `applicationSupportDirectory`
    /// resolves to the host's own home, not the extension's sandbox.
    fileprivate func failureMarkerURL(forBSD bsd: String) -> URL {
        extensionContainerDir().appendingPathComponent("failed-\(bsd).json")
    }

    /// Read the extension-written failure marker. Returns the error
    /// reason only when the marker's `attemptToken` matches the one
    /// staged into the current attempt's sidecar. Mismatches mean the
    /// marker was written by a prior loadResource that was still
    /// unwinding when /dev/diskN got reused — ignoring those prevents
    /// false rollback of a fresh mount.
    fileprivate static func readFailureMarker(at url: URL, expecting token: String) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let marker = try? JSONDecoder().decode(LoadFailureMarker.self, from: data) else {
            return nil
        }
        guard marker.attemptToken == token else { return nil }
        return marker.error
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

    /// Outcome of `confirmMountedOrRollback`. `.failed(reason:)` is
    /// non-nil when the extension's `loadResource` wrote a failure
    /// marker; `nil` means we hit the timeout without either a
    /// statfs success or a marker (genuinely opaque hang).
    enum MountConfirmResult {
        case mounted
        case failed(reason: String?)
    }

    /// Verify the FSKit extension finished bringing up the volume
    /// after `mount(8)` returned. On failure, unmount + detach so
    /// we don't leave a phantom mount or an orphaned dev node.
    /// Returns whatever reason the extension wrote into the failure
    /// marker (if any), so the caller can surface a useful status.
    func confirmMountedOrRollback(
        prep: PrepareResult, mountpoint: String
    ) async -> MountConfirmResult {
        let result = await waitForMount(prep: prep, mountpoint: mountpoint)
        switch result {
        case .mounted:
            return .mounted
        case .failed(let reason):
            try? unmount(at: mountpoint)
            try? detach(bsdName: prep.bsdName)
            return .failed(reason: reason)
        }
    }

    /// Poll for either statfs reporting `f_fstypename == "testfs"`
    /// (mount loaded) or the extension's per-BSD failure marker
    /// (loadResource failed). Whichever fires first wins, so
    /// deterministic failures don't burn the full 15s budget. Uses
    /// `ContinuousClock` so sleep/wake mid-poll doesn't skew the
    /// deadline.
    ///
    /// statfs is the authoritative success signal — NSWorkspace and
    /// DiskArbitration notifications fire on `mount(8)` accept,
    /// before loadResource completes, so they'd false-positive.
    /// The marker is the authoritative failure signal: extension
    /// writes it before calling `replyHandler(nil, error)`. Stage-
    /// time delete in `prepareMount` ensures we never see a stale
    /// marker from a prior mount that reused this BSD name.
    func waitForMount(
        prep: PrepareResult, mountpoint: String,
        timeout: Duration = mountConfirmTimeout
    ) async -> MountConfirmResult {
        let markerURL = failureMarkerURL(forBSD: prep.bsdName)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if Self.statfsType(at: mountpoint) == TestFSConstants.fstype {
                return .mounted
            }
            if let reason = Self.readFailureMarker(at: markerURL, expecting: prep.attemptToken) {
                return .failed(reason: reason)
            }
            try? await Task.sleep(for: Self.mountConfirmPollInterval)
        }
        return .failed(reason: nil)
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

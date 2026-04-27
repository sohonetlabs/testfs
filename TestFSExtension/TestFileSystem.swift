//
//  TestFileSystem.swift
//  TestFSExtension
//

import CryptoKit
import Foundation
import FSKit
import OSLog

/// Local aliases for the values shared with the host via
/// `TestFSConstants` in `MountOptions.swift`. Existing call sites
/// (`Identity.name`, `Identity.subsystem`) keep their shape; the
/// strings are now defined once.
enum Identity {
    static let name = TestFSConstants.fstype
    static let subsystem = TestFSConstants.logSubsystem
}

enum Log {
    static let lifecycle = Logger(subsystem: Identity.subsystem, category: "lifecycle")
    static let mount = Logger(subsystem: Identity.subsystem, category: "mount")
    static let lookup = Logger(subsystem: Identity.subsystem, category: "lookup")
    static let read = Logger(subsystem: Identity.subsystem, category: "read")
    static let stats = Logger(subsystem: Identity.subsystem, category: "stats")
}

final class TestFileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations {
    func probeResource(
        resource: FSResource,
        replyHandler: @escaping (FSProbeResult?, (any Error)?) -> Void
    ) {
        guard let block = resource as? FSBlockDeviceResource else {
            Log.mount.error("probeResource: resource is not FSBlockDeviceResource")
            replyHandler(nil, POSIXError(.ENODEV))
            return
        }
        let bsd = block.bsdName
        let containerID = Self.containerID(forBSDName: bsd)
        let volumeName = Self.volumeName(forBSDName: bsd)
        Log.mount.debug("probeResource: \(bsd, privacy: .public) -> \(volumeName, privacy: .public)")
        replyHandler(FSProbeResult.usable(name: volumeName, containerID: containerID), nil)
    }

    func loadResource(
        resource: FSResource,
        options: FSTaskOptions,
        replyHandler: @escaping (FSVolume?, (any Error)?) -> Void
    ) {
        guard let block = resource as? FSBlockDeviceResource else {
            Log.mount.error("loadResource: resource is not FSBlockDeviceResource")
            replyHandler(nil, POSIXError(.ENODEV))
            return
        }
        let bsd = block.bsdName
        Log.mount.info("loadResource starting for \(bsd, privacy: .public)")
        do {
            let sidecarURL = MountOptions.sidecarURL(forBSDName: bsd)
            let mountOptions = try MountOptions.load(from: sidecarURL)
            let configPath = mountOptions.config!
            let treeData = try Data(contentsOf: URL(fileURLWithPath: configPath), options: .mappedIfSafe)
            let tree = try JSONTree.load(from: treeData)
            let index = try TreeBuilder.build(root: tree, options: mountOptions)
            let volume = TestFSVolume(index: index, options: mountOptions)
            containerStatus = .ready
            let nodeCount = index.nodesByID.count
            Log.mount.info(
                "loadResource: \(nodeCount) nodes from \(configPath, privacy: .public) for \(bsd, privacy: .public)")
            replyHandler(volume, nil)
        } catch {
            Log.mount.error("loadResource failed: \(error.localizedDescription, privacy: .public)")
            replyHandler(nil, error)
        }
    }

    /// Deterministic container ID from the BSD name, so a re-probe of the
    /// same /dev/diskN produces the same UUID — while different devices
    /// (concurrent mounts) get distinct IDs.
    private static func containerID(forBSDName bsd: String) -> FSContainerIdentifier {
        let hash = SHA256.hash(data: Data(bsd.utf8))
        let bytes = Array(hash.prefix(16))
        let uuid = uuid_t(
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15])
        return FSContainerIdentifier(uuid: UUID(uuid: uuid))
    }

    /// Volume name from the per-device sidecar's optional `volume_name`
    /// field, falling back to our extension's `testfs` identity.
    private static func volumeName(forBSDName bsd: String) -> String {
        let sidecarURL = MountOptions.sidecarURL(forBSDName: bsd)
        if let opts = try? MountOptions.load(from: sidecarURL),
           let name = opts.volumeName, !name.isEmpty {
            return name
        }
        return Identity.name
    }

    func unloadResource(
        resource: FSResource,
        options: FSTaskOptions,
        replyHandler reply: @escaping ((any Error)?) -> Void
    ) {
        Log.mount.debug("unloadResource")
        reply(nil)
    }

    func didFinishLoading() {
        Log.lifecycle.debug("didFinishLoading")
    }
}

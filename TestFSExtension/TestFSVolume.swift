//
//  TestFSVolume.swift
//  TestFSExtension
//

import Foundation
import FSKit
import Darwin

final class TestFSVolume: FSVolume {
    let index: TreeIndex
    let itemsByID: [TreeNodeID: TestFSItem]
    let totalFileBytes: UInt64
    let totalFileCount: UInt64
    /// Byte written to read buffers in fill-char mode.
    let fillByte: UInt8
    /// Pre-generated semi-random block cache. Nil in fill-char mode.
    let blockCache: BlockCache?
    let throttle: Throttle
    /// Source options. Kept around so later lookups of behaviour-shaping
    /// flags (ignoreAppledouble, etc.) read from one source of truth
    /// rather than proliferating mirrored stored fields.
    let options: MountOptions
    /// 1Hz background task that polls `throttle.snapshot()` and emits a
    /// single line via `Log.stats` per second when there's been activity.
    /// Started in init, cancelled by `stopStatsLogger()` from deactivate.
    private var statsLoggerTask: Task<Void, Never>?

    func stopStatsLogger() {
        statsLoggerTask?.cancel()
        statsLoggerTask = nil
    }

    var rootItem: TestFSItem {
        // TreeBuilder assigns IDs depth-first starting at 1; rootID is
        // always present in itemsByID. See TreeBuilder.build.
        itemsByID[index.rootID]!
    }

    init(index: TreeIndex, options: MountOptions) {
        self.index = index
        // Fallback covers test-constructed options that skip MountOptions.load validation.
        self.fillByte = options.fillChar.utf8.first ?? 0

        let uid = options.uid ?? getuid()
        let gid = options.gid ?? getgid()
        let mtimeDate = MountOptions.parseMtime(options.mtime) ?? Date(timeIntervalSince1970: 0)
        let mtime = timespec(tv_sec: Int(mtimeDate.timeIntervalSince1970), tv_nsec: 0)
        let dirMode = UInt32(S_IFDIR | 0o555)
        let fileMode = UInt32(S_IFREG | 0o444)

        let paths = TestFSVolume.buildPaths(index: index)
        var items: [TreeNodeID: TestFSItem] = [:]
        items.reserveCapacity(index.nodesByID.count)
        var totalSize: UInt64 = 0
        var fileCount: UInt64 = 0
        let shape = AttributeShape(
            uid: uid, gid: gid, mtime: mtime, dirMode: dirMode, fileMode: fileMode)
        for (id, node) in index.nodesByID {
            let attrs = TestFSVolume.buildAttributes(node: node, shape: shape)
            items[id] = TestFSItem(node: node, attributes: attrs, path: paths[id]!)
            if node.kind == .file {
                totalSize += node.size
                fileCount += 1
            }
        }
        self.itemsByID = items
        self.totalFileBytes = totalSize
        self.totalFileCount = fileCount
        self.blockCache = TestFSVolume.makeBlockCache(options: options)
        self.throttle = Throttle(rateLimit: .seconds(options.rateLimit), iopLimit: options.iopLimit)
        self.options = options

        // Priority: explicit volumeName from sidecar → tree-JSON
        // filename → extension's identity name. The probe path in
        // TestFileSystem.volumeName(forBSDName:) follows the same
        // priority for the Finder-facing name; this keeps both
        // call sites consistent.
        let volumeName: String
        if let name = options.volumeName, !name.isEmpty {
            volumeName = name
        } else if let cfg = options.config {
            volumeName = (cfg as NSString).lastPathComponent
        } else {
            volumeName = Identity.name
        }
        super.init(
            volumeID: FSVolume.Identifier(uuid: UUID()),
            volumeName: FSFileName(string: volumeName)
        )

        let cfg = options.config ?? "<no config>"
        Log.lifecycle.info("init: \(items.count) items from \(cfg, privacy: .public)")

        if options.reportStats {
            startStatsLogger()
        }
    }

    private func startStatsLogger() {
        statsLoggerTask = Task { [throttle] in
            var lastOps: UInt64 = 0
            var lastBytes: UInt64 = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                let snap = await throttle.snapshot()
                let dOps = snap.ops - lastOps
                let dBytes = snap.bytes - lastBytes
                if dOps > 0 || dBytes > 0 {
                    Log.stats.info(
                        "ops/s=\(dOps) bytes/s=\(dBytes) total_ops=\(snap.ops) total_bytes=\(snap.bytes)"
                    )
                }
                lastOps = snap.ops
                lastBytes = snap.bytes
            }
        }
    }

    /// Unwrap an incoming FSItem as our own subclass. fskitd hands back
    /// what we gave it; a foreign class here is a genuine bug (kernel
    /// cache mismatch), so fail with EIO rather than masking as ENOENT.
    func requireTestItem(_ item: FSItem) throws -> TestFSItem {
        guard let testItem = item as? TestFSItem else {
            Log.mount.error("FSItem is not a TestFSItem: \(String(describing: type(of: item)), privacy: .public)")
            throw posixError(.EIO)
        }
        return testItem
    }

    private static func makeBlockCache(options: MountOptions) -> BlockCache? {
        guard options.semiRandom else { return nil }
        return BlockCache(
            count: options.preGeneratedBlocks,
            blockSize: options.blockSizeBytes,
            seed: UInt32(truncatingIfNeeded: options.seed)
        )
    }

    /// Walk the tree from root, accumulating each node's absolute path
    /// (e.g. "/dir/file.txt"). Used as the semi-random block lookup key.
    private static func buildPaths(index: TreeIndex) -> [TreeNodeID: String] {
        var paths: [TreeNodeID: String] = [:]
        paths.reserveCapacity(index.nodesByID.count)
        paths[index.rootID] = "/"
        var stack: [TreeNodeID] = [index.rootID]
        while let parentID = stack.popLast() {
            guard let parent = index.nodesByID[parentID], let parentPath = paths[parentID] else {
                continue
            }
            for childID in parent.childrenIDs {
                guard let child = index.nodesByID[childID] else { continue }
                paths[childID] = parentPath == "/" ? "/\(child.name)" : "\(parentPath)/\(child.name)"
                if child.kind == .directory { stack.append(childID) }
            }
        }
        return paths
    }

    /// Per-volume invariants the per-node attribute builder needs.
    /// Pulled into a struct so the builder stays under SwiftLint's
    /// 5-parameter limit.
    struct AttributeShape {
        let uid: UInt32
        let gid: UInt32
        let mtime: timespec
        let dirMode: UInt32
        let fileMode: UInt32
    }

    private static func buildAttributes(
        node: TreeIndex.Node, shape: AttributeShape
    ) -> FSItem.Attributes {
        let attrs = FSItem.Attributes()
        // Offset by +1 so TreeNodeID 1 (our root) maps to rawValue 2,
        // which is FSItem.Identifier.rootDirectory per the SDK header.
        // Avoids collision with the reserved .parentOfRoot (=1) and
        // .invalid (=0) identifiers.
        attrs.fileID = FSItem.Identifier(rawValue: node.id + 1) ?? .invalid
        attrs.parentID =
            node.parentID
            .map { FSItem.Identifier(rawValue: $0 + 1) ?? .invalid }
            ?? .parentOfRoot
        attrs.uid = shape.uid
        attrs.gid = shape.gid
        switch node.kind {
        case .directory:
            // Unix convention: `.` + parent's `..` + each child subdir's `..`.
            // Clamp because `linkCount` is UInt32 and the index uses Int.
            attrs.linkCount = UInt32(clamping: 2 + node.directoryChildCount)
            attrs.type = .directory
            attrs.mode = shape.dirMode
            attrs.size = 0
            attrs.allocSize = 0
        case .file:
            attrs.linkCount = 1
            attrs.type = .file
            attrs.mode = shape.fileMode
            attrs.size = node.size
            attrs.allocSize = node.size
        }
        attrs.accessTime = shape.mtime
        attrs.changeTime = shape.mtime
        attrs.modifyTime = shape.mtime
        attrs.birthTime = shape.mtime
        return attrs
    }
}

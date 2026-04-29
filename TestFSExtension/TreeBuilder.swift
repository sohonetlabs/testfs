//
//  TreeBuilder.swift
//  TestFSCore / TestFSExtension
//
//  Builds a TreeIndex from a parsed JSONTree node, assigning monotonic
//  IDs, applying Unicode normalization from MountOptions, preserving
//  insertion order for enumeration cookies, and failing loudly on
//  case-insensitive name collisions.
//
//  Pure Swift — do NOT add `import FSKit` here. This file is
//  dual-membership (TestFS host + TestFSExtension); FSKit isn't
//  linked into the host target and an import would silently break
//  the host build only on a clean pbxproj rebuild.
//

import Foundation

enum TreeBuilder {

    /// Empty Spotlight-hint dotfiles appended to the root when
    /// `addMacosCacheFiles` is true. Their presence tells `mds` /
    /// `mdworker` not to index the volume (see Apple TN2172 and the
    /// `.metadata_never_index` family). Order doesn't matter; names do.
    private static let macosCacheControlFiles: [TreeNode] = [
        .file(name: ".metadata_never_index", size: 0),
        .file(name: ".metadata_never_index_unless_rootfs", size: 0),
        .file(name: ".metadata_direct_scope_only", size: 0)
    ]

    enum BuildError: Error, LocalizedError {
        /// Two siblings had the same name after unicode normalization.
        /// Either a literal duplicate in the JSON tree or a pair of
        /// distinct byte sequences that canonicalize to the same form
        /// (e.g. NFC `é` and NFD `é` under `unicode_normalization=nfd`).
        case duplicateName(directory: String, name: String)

        /// Adding this file's size would push past
        /// `maxTotalFileBytes`. See that constant for why.
        case totalSizeOverflow(directory: String, name: String)

        var errorDescription: String? {
            switch self {
            case .duplicateName(let dir, let name):
                return "duplicate filename in '\(dir)': '\(name)' "
                    + "(check for case-fold-or-normalization-equivalent siblings)"
            case .totalSizeOverflow(let dir, let name):
                return "file size overflows volume accounting in '\(dir)': '\(name)'"
            }
        }
    }

    /// Block size `TestFSVolume.volumeStatistics` reports in `statfs`.
    /// Owned here because `maxTotalFileBytes` is derived from it; both
    /// values must stay coupled.
    static let volumeStatBlockSize: Int = 4096

    /// Volume statistics report `(totalFileBytes + blockSize - 1) /
    /// blockSize` blocks; the addition overflows once `totalFileBytes`
    /// passes this cap. Build-time rejection lets the volume layer
    /// rely on the math.
    static let maxTotalFileBytes: UInt64 =
        UInt64.max - UInt64(volumeStatBlockSize - 1)

    /// Mutable state threaded through the recursive walk. Pulled into
    /// a struct so individual visit/visitDirectory steps stay short
    /// enough to satisfy SwiftLint's function_body_length budget.
    fileprivate struct Context {
        var nodesByID: [TreeNodeID: TreeIndex.Node] = [:]
        var nextID: TreeNodeID = 1
        var totalFileBytes: UInt64 = 0
        let options: MountOptions
    }

    /// Walk `root` recursively and construct a TreeIndex. Names are
    /// normalized per `options.unicodeNormalization` before being
    /// stored or folded for lookup.
    static func build(root: TreeNode, options: MountOptions) throws -> TreeIndex {
        var ctx = Context(options: options)
        let (rootID, _) = try visit(root, parentID: nil, ctx: &ctx)
        return TreeIndex(
            nodesByID: ctx.nodesByID, rootID: rootID,
            unicodeNormalization: options.unicodeNormalization
        )
    }

    /// Decode the tree JSON and build the index in one call. Both
    /// the host's `prepareMount` pre-flight and the extension's
    /// `loadResource` go through this so the two sites can't drift
    /// on the validation contract.
    static func parseAndBuild(treeJSON: Data, options: MountOptions) throws -> TreeIndex {
        let root = try JSONTree.load(from: treeJSON)
        return try build(root: root, options: options)
    }

    /// Returns (id, normalized-name) so the caller doesn't have to
    /// re-look-up the just-inserted node when checking for collisions.
    private static func visit(
        _ node: TreeNode, parentID: TreeNodeID?, ctx: inout Context
    ) throws -> (TreeNodeID, String) {
        let id = ctx.nextID
        ctx.nextID += 1
        switch node {
        case .file(let rawName, let size):
            let name = ctx.options.unicodeNormalization.apply(to: rawName)
            let (newTotal, overflow) = ctx.totalFileBytes.addingReportingOverflow(size)
            guard !overflow, newTotal <= Self.maxTotalFileBytes else {
                let dir = parentID.map { displayPath(of: $0, nodesByID: ctx.nodesByID) } ?? "<root>"
                throw BuildError.totalSizeOverflow(directory: dir, name: rawName)
            }
            ctx.totalFileBytes = newTotal
            ctx.nodesByID[id] = TreeIndex.Node(
                id: id, parentID: parentID, name: name,
                kind: .file, size: size,
                childrenIDs: [], childrenByName: [:],
                directoryChildCount: 0
            )
            return (id, name)
        case .directory(let rawName, let contents):
            return try visitDirectory(
                id: id, parentID: parentID, rawName: rawName,
                contents: contents, ctx: &ctx)
        }
    }

    private static func visitDirectory(
        id: TreeNodeID, parentID: TreeNodeID?, rawName: String,
        contents: [TreeNode], ctx: inout Context
    ) throws -> (TreeNodeID, String) {
        let name = ctx.options.unicodeNormalization.apply(to: rawName)
        // Insert a placeholder up front so collision errors in
        // descendants can walk back through us via parentID.
        ctx.nodesByID[id] = TreeIndex.Node(
            id: id, parentID: parentID, name: name,
            kind: .directory, size: 0,
            childrenIDs: [], childrenByName: [:],
            directoryChildCount: 0
        )

        let capacity = contents.count + Self.macosCacheControlFiles.count
        var childIDs: [TreeNodeID] = []
        childIDs.reserveCapacity(capacity)
        // Byte-keyed map (see TreeIndex.Node.childrenByName for why
        // not String) so NFC and NFD distinct byte sequences don't
        // collide as keys.
        var byName: [Data: TreeNodeID] = [:]
        byName.reserveCapacity(capacity)

        for child in contents {
            let (childID, childName) = try visit(child, parentID: id, ctx: &ctx)
            let key = Data(childName.utf8)
            if byName[key] != nil {
                throw BuildError.duplicateName(
                    directory: displayPath(of: id, nodesByID: ctx.nodesByID),
                    name: childName
                )
            }
            childIDs.append(childID)
            byName[key] = childID
        }

        // Only the root gets the Spotlight-hint dotfiles: they're a
        // volume-level signal. Skip any extra the JSON tree already
        // staged itself (e.g. archive-torture fixtures include
        // `.metadata_never_index`) so we don't double-add.
        if parentID == nil && ctx.options.addMacosCacheFiles {
            for extra in Self.macosCacheControlFiles {
                let extraName = ctx.options.unicodeNormalization.apply(to: extra.name)
                let extraKey = Data(extraName.utf8)
                guard byName[extraKey] == nil else { continue }
                let (extraID, _) = try visit(extra, parentID: id, ctx: &ctx)
                childIDs.append(extraID)
                byName[extraKey] = extraID
            }
        }

        let subdirCount = childIDs.count { ctx.nodesByID[$0]?.kind == .directory }
        ctx.nodesByID[id] = TreeIndex.Node(
            id: id, parentID: parentID, name: name,
            kind: .directory, size: 0,
            childrenIDs: childIDs, childrenByName: byName,
            directoryChildCount: subdirCount
        )
        return (id, name)
    }

    /// Reconstruct a display path from root to the given directory id
    /// by walking the parent chain. The id itself plus all ancestors
    /// must already be in `nodesByID` — `visit` inserts a placeholder
    /// before recursing to guarantee this. Falls back to `<root>` so
    /// error messages don't render a bare empty path.
    private static func displayPath(
        of id: TreeNodeID,
        nodesByID: [TreeNodeID: TreeIndex.Node]
    ) -> String {
        var components: [String] = []
        var cursor: TreeNodeID? = id
        while let cur = cursor, let node = nodesByID[cur] {
            components.append(node.name)
            cursor = node.parentID
        }
        let path = components.reversed().joined(separator: "/")
        return path.isEmpty ? "<root>" : path
    }

}

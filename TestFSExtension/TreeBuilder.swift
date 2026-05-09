//
//  TreeBuilder.swift
//  TestFSCore / TestFSExtension
//
//  Builds a TreeIndex from a parsed JSONTree node, assigning monotonic
//  IDs, applying Unicode normalization from MountOptions, and preserving
//  insertion order for enumeration cookies. Collision handling is
//  Python-faithful (last-wins on lookup, both raw names retained for
//  readdir) — see `appendChild` for the contract.
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
        /// No current emit site — kept so a future opt-in strict mode
        /// has a typed error to throw without a source change.
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

    /// Mutable state threaded through the iterative walk. Held in a
    /// struct purely to keep the per-step closures in `build(...)`
    /// short enough to satisfy SwiftLint's function-body budget.
    fileprivate struct Context {
        var nodesByID: [TreeNodeID: TreeIndex.Node] = [:]
        var nextID: TreeNodeID = 1
        var totalFileBytes: UInt64 = 0
        let options: MountOptions
    }

    /// One in-progress directory on the iterative build stack. Carries
    /// the source-order children, the index of the next child to
    /// process, and the accumulators that become the finalized
    /// `TreeIndex.Node` on exit. See `build(...)` for the lifecycle.
    private struct DirectoryFrame {
        let id: TreeNodeID
        let parentID: TreeNodeID?
        let rawName: String
        let name: String
        let contents: [TreeNode]
        var nextChildIndex: Int
        var childIDs: [TreeNodeID]
        var byName: [Data: TreeNodeID]
        /// Bumped as `.directory` children are appended so the exit
        /// phase can drop the per-pop `O(children)` dict lookup that
        /// the recursive walk used. Files don't bump it.
        var directoryChildCount: Int
    }

    /// Walk `root` and construct a TreeIndex. Iterative (explicit
    /// stack of `DirectoryFrame`) rather than recursive — `loadResource`
    /// runs on a dispatch-queue thread whose stack tops out around
    /// ~256 KB, much smaller than the main thread's 8 MB, so a
    /// recursive `visit` ↔ `visitDirectory` blew up at ~243 frames
    /// on archive_torture_path_lengths.json (196 levels). Names are
    /// normalized per `options.unicodeNormalization` before being
    /// stored or folded for lookup.
    static func build(root: TreeNode, options: MountOptions) throws -> TreeIndex {
        var ctx = Context(options: options)
        let rootID = try buildIteratively(root: root, ctx: &ctx)
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

    private static func buildIteratively(root: TreeNode, ctx: inout Context) throws -> TreeNodeID {
        switch root {
        case .file:
            let (id, _) = try makeFileNode(root, parentID: nil, ctx: &ctx)
            return id
        case .directory(let rawName, let userContents):
            // Cache-control dotfiles are appended onto the root frame
            // before the loop starts; nextChildIndex iterates through
            // user content first, then the dotfiles, matching the
            // recursive walk's ordering. Collision against a same-
            // named user entry follows shared `appendChild` semantics
            // (last-wins on lookup, both retained in childrenIDs).
            let rootContents: [TreeNode] = ctx.options.addMacosCacheFiles
                ? userContents + Self.macosCacheControlFiles
                : userContents
            var stack: [DirectoryFrame] = []
            let rootID = pushDirectory(
                rawName: rawName, contents: rootContents,
                parentID: nil, ctx: &ctx, stack: &stack)
            try runBuildLoop(stack: &stack, ctx: &ctx)
            return rootID
        }
    }

    private static func runBuildLoop(stack: inout [DirectoryFrame], ctx: inout Context) throws {
        while !stack.isEmpty {
            let top = stack.count - 1
            if stack[top].nextChildIndex == stack[top].contents.count {
                let frame = stack.removeLast()
                ctx.nodesByID[frame.id] = TreeIndex.Node(
                    id: frame.id, parentID: frame.parentID,
                    rawName: frame.rawName, name: frame.name,
                    kind: .directory, size: 0,
                    childrenIDs: frame.childIDs, childrenByName: frame.byName,
                    directoryChildCount: frame.directoryChildCount
                )
                if !stack.isEmpty {
                    let parent = stack.count - 1
                    appendChild(id: frame.id, normalizedName: frame.name,
                                to: &stack[parent])
                    stack[parent].directoryChildCount += 1
                }
                continue
            }

            let child = stack[top].contents[stack[top].nextChildIndex]
            stack[top].nextChildIndex += 1

            switch child {
            case .file:
                let (childID, childName) = try makeFileNode(child, parentID: stack[top].id, ctx: &ctx)
                appendChild(id: childID, normalizedName: childName, to: &stack[top])
            case .directory(let rawName, let contents):
                pushDirectory(
                    rawName: rawName, contents: contents,
                    parentID: stack[top].id, ctx: &ctx, stack: &stack)
            }
        }
    }

    /// Allocate the directory's id, insert a placeholder Node so
    /// descendants' `displayPath` walks resolve through us, and
    /// push a fresh `DirectoryFrame` onto the loop's stack.
    @discardableResult
    private static func pushDirectory(
        rawName: String, contents: [TreeNode], parentID: TreeNodeID?,
        ctx: inout Context, stack: inout [DirectoryFrame]
    ) -> TreeNodeID {
        let id = ctx.nextID
        ctx.nextID += 1
        let name = ctx.options.unicodeNormalization.apply(to: rawName)
        ctx.nodesByID[id] = TreeIndex.Node(
            id: id, parentID: parentID, rawName: rawName, name: name,
            kind: .directory, size: 0,
            childrenIDs: [], childrenByName: [:],
            directoryChildCount: 0
        )
        var childIDs: [TreeNodeID] = []
        childIDs.reserveCapacity(contents.count)
        var byName: [Data: TreeNodeID] = [:]
        byName.reserveCapacity(contents.count)
        stack.append(DirectoryFrame(
            id: id, parentID: parentID,
            rawName: rawName, name: name,
            contents: contents, nextChildIndex: 0,
            childIDs: childIDs, byName: byName,
            directoryChildCount: 0
        ))
        return id
    }

    /// Build a leaf `.file` Node, insert it, and return its (id,
    /// normalized name) so the caller can append it to the parent
    /// frame's accumulators.
    private static func makeFileNode(
        _ node: TreeNode, parentID: TreeNodeID?, ctx: inout Context
    ) throws -> (TreeNodeID, String) {
        guard case .file(let rawName, let size) = node else {
            preconditionFailure("makeFileNode called with non-file: \(node)")
        }
        let id = ctx.nextID
        ctx.nextID += 1
        let name = ctx.options.unicodeNormalization.apply(to: rawName)
        let (newTotal, overflow) = ctx.totalFileBytes.addingReportingOverflow(size)
        guard !overflow, newTotal <= Self.maxTotalFileBytes else {
            let dir = parentID.map { displayPath(of: $0, nodesByID: ctx.nodesByID) } ?? "<root>"
            throw BuildError.totalSizeOverflow(directory: dir, name: rawName)
        }
        ctx.totalFileBytes = newTotal
        ctx.nodesByID[id] = TreeIndex.Node(
            id: id, parentID: parentID, rawName: rawName, name: name,
            kind: .file, size: size,
            childrenIDs: [], childrenByName: [:],
            directoryChildCount: 0
        )
        return (id, name)
    }

    /// Add a child to a directory frame's accumulators with Python-
    /// faithful collision semantics: both childIDs are kept in
    /// `childIDs` (so `enumerate`/readdir yields both raw names),
    /// and `byName[key]` is last-wins so a normalized lookup resolves
    /// to the most recent insertion. Matches `_build_path_map` in
    /// jsonfs.py:464. Takes the whole frame inout because Swift's
    /// exclusive-access check rejects two simultaneous `inout`
    /// subscripts into the same `[DirectoryFrame]`.
    private static func appendChild(
        id childID: TreeNodeID,
        normalizedName: String,
        to frame: inout DirectoryFrame
    ) {
        frame.childIDs.append(childID)
        frame.byName[Data(normalizedName.utf8)] = childID
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

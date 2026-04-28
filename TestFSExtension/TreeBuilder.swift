//
//  TreeBuilder.swift
//  TestFSCore / TestFSExtension
//
//  Builds a TreeIndex from a parsed JSONTree node, assigning monotonic
//  IDs, applying Unicode normalization from MountOptions, preserving
//  insertion order for enumeration cookies, and failing loudly on
//  case-insensitive name collisions. Pure Swift, no FSKit.
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
        case caseFoldCollision(directory: String, folded: String, existing: String, incoming: String)

        var errorDescription: String? {
            switch self {
            case .caseFoldCollision(let dir, let folded, let existing, let incoming):
                return "case-insensitive filename collision in '\(dir)': "
                    + "'\(existing)' and '\(incoming)' "
                    + "both fold to '\(folded)'"
            }
        }
    }

    /// Mutable state threaded through the recursive walk. Pulled into
    /// a struct so individual visit/visitDirectory steps stay short
    /// enough to satisfy SwiftLint's function_body_length budget.
    fileprivate struct Context {
        var nodesByID: [TreeNodeID: TreeIndex.Node] = [:]
        var nextID: TreeNodeID = 1
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
            ctx.nodesByID[id] = TreeIndex.Node(
                id: id, parentID: parentID, name: name,
                kind: .file, size: size,
                childrenIDs: [], childrenByFoldedName: [:]
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
            childrenIDs: [], childrenByFoldedName: [:]
        )

        let capacity = contents.count + Self.macosCacheControlFiles.count
        var childIDs: [TreeNodeID] = []
        childIDs.reserveCapacity(capacity)
        var foldedLookup: [String: TreeNodeID] = [:]
        foldedLookup.reserveCapacity(capacity)

        for child in contents {
            let (childID, childName) = try visit(child, parentID: id, ctx: &ctx)
            let folded = TreeIndex.fold(childName)
            if let existingID = foldedLookup[folded],
               let existingName = ctx.nodesByID[existingID]?.name {
                throw BuildError.caseFoldCollision(
                    directory: displayPath(of: id, nodesByID: ctx.nodesByID),
                    folded: folded,
                    existing: existingName,
                    incoming: childName
                )
            }
            childIDs.append(childID)
            foldedLookup[folded] = childID
        }

        // Only the root gets the Spotlight-hint dotfiles: they're a
        // volume-level signal. Skip any extra the JSON tree already
        // staged itself (e.g. archive-torture fixtures include
        // `.metadata_never_index`) so adding ours doesn't fold-collide.
        if parentID == nil && ctx.options.addMacosCacheFiles {
            for extra in Self.macosCacheControlFiles {
                let extraName = ctx.options.unicodeNormalization.apply(to: extra.name)
                let folded = TreeIndex.fold(extraName)
                guard foldedLookup[folded] == nil else { continue }
                let (extraID, _) = try visit(extra, parentID: id, ctx: &ctx)
                childIDs.append(extraID)
                foldedLookup[folded] = extraID
            }
        }

        ctx.nodesByID[id] = TreeIndex.Node(
            id: id, parentID: parentID, name: name,
            kind: .directory, size: 0,
            childrenIDs: childIDs, childrenByFoldedName: foldedLookup
        )
        return (id, name)
    }

    /// Reconstruct a display path from root to the given directory id
    /// by walking the parent chain. The id itself plus all ancestors
    /// must already be in `nodesByID` — `visit` inserts a placeholder
    /// before recursing to guarantee this.
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
        return components.reversed().joined(separator: "/")
    }

}

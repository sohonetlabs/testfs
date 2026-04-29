//
//  TreeIndex.swift
//  TestFSCore / TestFSExtension
//
//  Parsed `tree -J -s` tree with stable monotonic IDs, preserved
//  insertion order, and case-sensitive name lookup (matching the
//  Python `jsonfs.py` upstream).
//
//  Pure Swift — do NOT add `import FSKit` here. This file is
//  dual-membership (TestFS host + TestFSExtension via pbxproj);
//  FSKit isn't linked into the host target and an import would
//  silently break the host build only on a clean rebuild.
//

import Foundation

/// Monotonic node ID assigned at build time. Stable for the lifetime
/// of a mount. Starts at 1 (root) and increments depth-first pre-order.
typealias TreeNodeID = UInt64

/// Immutable index of every node in a parsed filesystem tree.
struct TreeIndex: Sendable, Equatable {

    enum NodeKind: Sendable, Equatable {
        case directory
        case file
    }

    /// A single node in the index. Structs are copied on lookup, so
    /// value-identity is all we need here; the FSKit layer adds class
    /// identity for the kernel cache.
    struct Node: Sendable, Equatable {
        let id: TreeNodeID
        let parentID: TreeNodeID?  // nil for root
        let name: String  // already unicode-normalized
        let kind: NodeKind
        let size: UInt64  // 0 for directories
        let childrenIDs: [TreeNodeID]
        /// Children keyed by raw UTF-8 bytes of the unicode-normalized
        /// name. Bytes (not String) is deliberate: Swift's String
        /// dict-key hashing uses canonical equivalence, so NFC `é`
        /// (U+00E9) and NFD `é` (U+0065 U+0301) collide as String
        /// keys even though they're distinct byte sequences. Python
        /// upstream's path_map is byte-distinct; this matches that.
        let childrenByName: [Data: TreeNodeID]
        /// Number of immediate child directories. Always 0 for files.
        let directoryChildCount: Int
    }

    let nodesByID: [TreeNodeID: Node]
    let rootID: TreeNodeID
    /// Normalization applied to both stored names and incoming lookup
    /// keys so a kernel callback arriving in one Unicode form resolves
    /// against a tree built from a different form.
    let unicodeNormalization: UnicodeNormalization

    var root: Node {
        // rootID is always present by construction; force-unwrap is
        // a deliberate invariant check.
        nodesByID[rootID]!
    }

    func node(for id: TreeNodeID) -> Node? {
        nodesByID[id]
    }

    /// Lookup a child by name in the given directory. The lookup is
    /// case-sensitive (matching `FSfileObjectsAreCaseSensitive=true`
    /// in the extension's Info.plist and the Python `jsonfs.py`
    /// upstream) and applies `unicodeNormalization` to the incoming
    /// name so NFC/NFD variants both resolve when normalization is on.
    func lookup(name: String, in directoryID: TreeNodeID) -> Node? {
        guard let parent = nodesByID[directoryID] else { return nil }
        let key = Data(unicodeNormalization.apply(to: name).utf8)
        guard let childID = parent.childrenByName[key] else { return nil }
        return nodesByID[childID]
    }
}

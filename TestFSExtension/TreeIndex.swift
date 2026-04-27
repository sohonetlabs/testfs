//
//  TreeIndex.swift
//  TestFSCore / TestFSExtension
//
//  Pure-Swift representation of a parsed `tree -J -s` tree with stable
//  monotonic IDs, preserved insertion order, and case-folded name
//  lookup. TestFSVolume / TestFSItem (FSKit) wrap this at the next
//  layer; TreeIndex itself has no FSKit dependency so it can be unit
//  tested via `swift test`.
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
        let childrenByFoldedName: [String: TreeNodeID]
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
    /// case-insensitive (matching `FSfileObjectsAreCaseSensitive=false`
    /// in the extension's Info.plist) and applies `unicodeNormalization`
    /// to the incoming name so NFC/NFD variants both resolve.
    func lookup(name: String, in directoryID: TreeNodeID) -> Node? {
        guard let parent = nodesByID[directoryID] else { return nil }
        let folded = TreeIndex.fold(unicodeNormalization.apply(to: name))
        guard let childID = parent.childrenByFoldedName[folded] else { return nil }
        return nodesByID[childID]
    }

    /// Case-folding used for childrenByFoldedName and lookup. Uses
    /// root-locale lowercasing so Turkish I / German ß do not produce
    /// surprising results.
    static func fold(_ name: String) -> String {
        name.lowercased()
    }
}

//
//  TestFSItem.swift
//  TestFSExtension
//
//  FSItem subclass wrapping a single TreeIndex.Node. Built once per
//  node at volume init time and cached in TestFSVolume.itemsByID; every
//  lookupItem / enumerateDirectory callback returns the same instance
//  so the kernel dcache stays consistent — returning a fresh FSItem
//  for the same node confuses the cache and produces stale lookups.
//

import Foundation
import FSKit

final class TestFSItem: FSItem {
    let node: TreeIndex.Node
    let cachedAttributes: FSItem.Attributes
    /// Pre-wrapped FSFileName of `node.rawName`, cached so enumerate
    /// and lookup don't allocate a new one per call.
    let fsName: FSFileName
    /// Absolute path within the volume (e.g., "/dir/file.txt"). Used as
    /// the lookup key for semi-random block selection.
    let path: String

    init(node: TreeIndex.Node, attributes: FSItem.Attributes, path: String) {
        self.node = node
        self.cachedAttributes = attributes
        // `FSFileName(data:)`, not `(string:)`: empirically, a name
        // like "\u{FEFF}file.txt" was losing the leading BOM somewhere
        // through the NSString-bridged init, so the entry round-tripped
        // out to the kernel as "file.txt" and became unfindable on
        // lookup (parity matrix evidence on
        // archive_torture_mojibake_traps.json). The byte init copies
        // the UTF-8 sequence verbatim. The matching inbound decode
        // lives in TestFSVolume+Ops.swift lookupItem(named:inDirectory:).
        self.fsName = FSFileName(data: Data(node.rawName.utf8))
        self.path = path
        super.init()
    }
}

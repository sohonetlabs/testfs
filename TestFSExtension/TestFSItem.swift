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
    /// Pre-wrapped FSFileName of `node.name`, cached so enumerate and
    /// lookup don't allocate a new one per call.
    let fsName: FSFileName
    /// Absolute path within the volume (e.g., "/dir/file.txt"). Used as
    /// the lookup key for semi-random block selection.
    let path: String

    init(node: TreeIndex.Node, attributes: FSItem.Attributes, path: String) {
        self.node = node
        self.cachedAttributes = attributes
        self.fsName = FSFileName(string: node.name)
        self.path = path
        super.init()
    }
}

//
//  TreeBuilderCollisionTests.swift
//
//  Sibling-name collision parity with the Python `jsonfs.py` upstream:
//  literal duplicates, normalization-induced duplicates (NFC vs NFD),
//  and collisions in non-root directories. The contract: BOTH childIDs
//  remain in `childrenIDs` (so readdir/enumerate yields both raw names),
//  and `byName` is last-wins so a normalized lookup resolves to the
//  most-recently-inserted child. See `TreeBuilder.appendChild`.
//

import XCTest
@testable import TestFSCore

final class TreeBuilderCollisionTests: XCTestCase {

    private func defaultOptions() -> MountOptions {
        var opts = MountOptions(config: "/tmp/ignored.json")
        opts.addMacosCacheFiles = false
        return opts
    }

    func testLiteralDuplicateKeepsBothLastWinsLookup() throws {
        // Literal duplicate of the same byte-identical name in the
        // JSON tree. Python's `_build_path_map` (jsonfs.py:464) overwrites
        // last-wins; readdir yields both. Match.
        let root: TreeNode = .directory(
            name: "r",
            contents: [
                .file(name: "foo.txt", size: 1),
                .file(name: "foo.txt", size: 2)
            ])
        let index = try TreeBuilder.build(root: root, options: defaultOptions())
        XCTAssertEqual(index.root.childrenIDs.count, 2)
        let children = index.root.childrenIDs.compactMap { index.node(for: $0) }
        XCTAssertEqual(children.map(\.size), [1, 2], "insertion order preserved")
        XCTAssertEqual(index.lookup(name: "foo.txt", in: index.rootID)?.size, 2,
            "lookup returns the second-inserted child")
    }

    func testDeepCollisionKeepsBothInLeafDirectory() throws {
        // Same collision contract holds at any depth — the appendChild
        // helper runs in every visitDirectory frame, not just root.
        let root: TreeNode = .directory(
            name: "top",
            contents: [
                .directory(
                    name: "sub",
                    contents: [
                        .directory(
                            name: "deep",
                            contents: [
                                .file(name: "a", size: 1),
                                .file(name: "a", size: 2)
                            ])
                    ])
            ])
        let index = try TreeBuilder.build(root: root, options: defaultOptions())
        guard let sub = index.lookup(name: "sub", in: index.rootID),
              let deep = index.lookup(name: "deep", in: sub.id)
        else { return XCTFail("path top/sub/deep missing") }
        XCTAssertEqual(deep.childrenIDs.count, 2,
            "non-root collisions also retain both childIDs")
        XCTAssertEqual(index.lookup(name: "a", in: deep.id)?.size, 2)
    }

    func testNFDCollidingSiblingsBothPreservedLastWinsLookup() throws {
        // NFC `é` and NFD `é` are byte-distinct but collapse under
        // .nfd normalization. Python `_build_path_map` (jsonfs.py:464)
        // overwrites the dict entry on collision while leaving both
        // raw names in `contents` for readdir; we match that.
        let nfc = "caf\u{00E9}"
        let nfd = "caf\u{0065}\u{0301}"
        XCTAssertNotEqual(
            Data(nfc.utf8), Data(nfd.utf8),
            "test premise: NFC and NFD must have distinct UTF-8 bytes")

        let root: TreeNode = .directory(
            name: "r",
            contents: [
                .file(name: nfc, size: 1),
                .file(name: nfd, size: 2)
            ])
        var options = defaultOptions()
        options.unicodeNormalization = .nfd

        let index = try TreeBuilder.build(root: root, options: options)

        // Both childIDs preserved in childrenIDs (so enumerate yields
        // both names — duplicate-dirent behavior matching Python readdir).
        XCTAssertEqual(index.root.childrenIDs.count, 2)

        // The two child nodes carry distinct rawName but the same
        // normalized name.
        let children = index.root.childrenIDs.compactMap { index.node(for: $0) }
        XCTAssertEqual(children.count, 2)
        XCTAssertEqual(Data(children[0].rawName.utf8), Data(nfc.utf8))
        XCTAssertEqual(Data(children[1].rawName.utf8), Data(nfd.utf8))
        XCTAssertEqual(children[0].name, children[1].name,
            "after .nfd normalization, both must share the same name (lookup key)")

        // Lookup of the colliding name resolves to the SECOND child
        // (last-wins, matching Python's path_map dict assignment).
        // Both spellings normalize to the same key, so either form
        // resolves the same child.
        XCTAssertEqual(index.lookup(name: nfd, in: index.rootID)?.size, 2,
            "NFD lookup hits the second-inserted child")
        XCTAssertEqual(index.lookup(name: nfc, in: index.rootID)?.size, 2,
            "NFC lookup normalizes to the same key as NFD and hits the same child")
    }

}

//
//  TreeBuilderTests.swift
//

import XCTest
@testable import TestFSCore

final class TreeBuilderTests: XCTestCase {

    /// Tests here focus on tree structure; cache-control dotfiles would
    /// just pad every root assertion by +3, so default to disabling them.
    /// Phase 10 tests opt back in explicitly.
    private func defaultOptions() -> MountOptions {
        var opts = MountOptions(config: "/tmp/ignored.json")
        opts.addMacosCacheFiles = false
        return opts
    }

    // MARK: - identity + shape

    func testBuildsWithStableIDs() throws {
        let root: TreeNode = .directory(
            name: "root",
            contents: [
                .file(name: "a.txt", size: 10),
                .file(name: "b.txt", size: 20)
            ])
        let index = try TreeBuilder.build(root: root, options: defaultOptions())
        XCTAssertEqual(index.nodesByID.count, 3)

        let ids = Set(index.nodesByID.keys)
        XCTAssertEqual(ids.count, 3, "IDs must be unique")

        let rootNode = index.root
        XCTAssertNil(rootNode.parentID)
        XCTAssertEqual(rootNode.childrenIDs.count, 2)
        for childID in rootNode.childrenIDs {
            XCTAssertEqual(index.node(for: childID)?.parentID, rootNode.id)
        }
    }

    func testRootIDIsOne() throws {
        let index = try TreeBuilder.build(
            root: .directory(name: "r", contents: []),
            options: defaultOptions()
        )
        // TreeBuilder's internal ID space starts at 1 and is mapped to
        // FSItem.Identifier space by TestFSVolume (adds +1 so root
        // arrives at rootDirectory.rawValue = 2, avoiding the reserved
        // .parentOfRoot = 1 and .invalid = 0).
        XCTAssertEqual(index.rootID, 1)
    }

    func testChildrenOrderedByJsonOrder() throws {
        let root: TreeNode = .directory(
            name: "r",
            contents: [
                .file(name: "zebra.txt", size: 1),
                .file(name: "alpha.txt", size: 2),
                .file(name: "mike.txt", size: 3)
            ])
        let index = try TreeBuilder.build(root: root, options: defaultOptions())
        let childNames = index.root.childrenIDs.compactMap { index.node(for: $0)?.name }
        XCTAssertEqual(childNames, ["zebra.txt", "alpha.txt", "mike.txt"])
    }

    // MARK: - lookup

    func testLookupReturnsSameNodeAcrossCalls() throws {
        let root: TreeNode = .directory(
            name: "r",
            contents: [
                .file(name: "foo.txt", size: 100)
            ])
        let index = try TreeBuilder.build(root: root, options: defaultOptions())
        let first = index.lookup(name: "foo.txt", in: index.rootID)
        let second = index.lookup(name: "foo.txt", in: index.rootID)
        XCTAssertNotNil(first)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first?.size, 100)
    }

    func testExactCaseLookupMatches() throws {
        // Lookup is case-sensitive (matches Python upstream and the
        // FSPersonality flag). The exact-case name resolves; other
        // cases are covered by testCaseSensitiveLookupMissesWrongCase
        // below.
        let root: TreeNode = .directory(
            name: "r",
            contents: [
                .file(name: "Foo.txt", size: 1)
            ])
        let index = try TreeBuilder.build(root: root, options: defaultOptions())
        XCTAssertNotNil(index.lookup(name: "Foo.txt", in: index.rootID))
    }

    func testLookupMissReturnsNil() throws {
        let index = try TreeBuilder.build(
            root: .directory(name: "r", contents: [.file(name: "a", size: 1)]),
            options: defaultOptions()
        )
        XCTAssertNil(index.lookup(name: "b", in: index.rootID))
    }

    // MARK: - collision handling

    func testDuplicateNameFailsBuild() {
        // Literal duplicate of the same name in the JSON tree.
        let root: TreeNode = .directory(
            name: "r",
            contents: [
                .file(name: "foo.txt", size: 1),
                .file(name: "foo.txt", size: 2)
            ])
        XCTAssertThrowsError(try TreeBuilder.build(root: root, options: defaultOptions())) { error in
            guard let err = error as? TreeBuilder.BuildError,
                case .duplicateName(_, let name) = err
            else {
                return XCTFail("expected duplicateName, got \(error)")
            }
            XCTAssertEqual(name, "foo.txt")
        }
    }

    func testDuplicateNameErrorIncludesFullPath() {
        // Regression: earlier displayPath implementation walked from the
        // not-yet-inserted self node and always produced bare dirname.
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
        XCTAssertThrowsError(try TreeBuilder.build(root: root, options: defaultOptions())) { error in
            guard let err = error as? TreeBuilder.BuildError,
                case .duplicateName(let directory, _) = err
            else {
                return XCTFail("expected duplicateName, got \(error)")
            }
            XCTAssertEqual(
                directory, "top/sub/deep",
                "displayPath should walk the parent chain, not just emit the dir name")
        }
    }

    // MARK: - unicode normalization

    func testNFDNormalizationMergesCanonicallyEqualNames() throws {
        // NFC: precomposed é (U+00E9) -> 5 UTF-8 bytes
        // NFD: decomposed e + combining acute (U+0065 U+0301) -> 6 UTF-8 bytes
        let nfc = "caf\u{00E9}"
        let nfd = "caf\u{0065}\u{0301}"
        // Swift's String.== compares canonically, so nfc == nfd is true
        // even though their byte encodings differ. Verify the byte-level
        // divergence directly to prove this test is meaningful.
        XCTAssertNotEqual(
            Data(nfc.utf8), Data(nfd.utf8),
            "NFC and NFD must have distinct UTF-8 byte representations")

        let root: TreeNode = .directory(
            name: "r",
            contents: [
                .file(name: nfc, size: 42)
            ])
        var options = defaultOptions()
        options.unicodeNormalization = .nfd
        let index = try TreeBuilder.build(root: root, options: options)

        // Both byte-different but canonically-equal inputs must find the same node.
        XCTAssertNotNil(index.lookup(name: nfc, in: index.rootID))
        XCTAssertNotNil(index.lookup(name: nfd, in: index.rootID))
        XCTAssertEqual(index.lookup(name: nfc, in: index.rootID)?.size, 42)
    }

    // MARK: - nested structure

    func testNestedHierarchy() throws {
        let root: TreeNode = .directory(
            name: "top",
            contents: [
                .directory(
                    name: "sub",
                    contents: [
                        .file(name: "deep.txt", size: 5)
                    ]),
                .file(name: "shallow.txt", size: 1)
            ])
        let index = try TreeBuilder.build(root: root, options: defaultOptions())
        XCTAssertEqual(index.nodesByID.count, 4)

        guard let sub = index.lookup(name: "sub", in: index.rootID), sub.kind == .directory else {
            return XCTFail("sub not found or wrong kind")
        }
        guard let deep = index.lookup(name: "deep.txt", in: sub.id), deep.kind == .file else {
            return XCTFail("deep.txt not found")
        }
        XCTAssertEqual(deep.size, 5)
        XCTAssertEqual(deep.parentID, sub.id)
    }

    func testFileSizesPreserved() throws {
        let root: TreeNode = .directory(
            name: "r",
            contents: [
                .file(name: "tiny", size: 0),
                .file(name: "small", size: 1024),
                .file(name: "gig", size: UInt64(1_073_741_824))
            ])
        let index = try TreeBuilder.build(root: root, options: defaultOptions())
        XCTAssertEqual(index.lookup(name: "tiny", in: index.rootID)?.size, 0)
        XCTAssertEqual(index.lookup(name: "small", in: index.rootID)?.size, 1024)
        XCTAssertEqual(index.lookup(name: "gig", in: index.rootID)?.size, 1_073_741_824)
    }

    // MARK: - directory link count

    func testDirectoryChildCountReflectsImmediateSubdirs() throws {
        // Files among siblings must not count toward the directory's
        // subdirectory count — that's what produces the right st_nlink.
        let root: TreeNode = .directory(
            name: "r",
            contents: [
                .directory(name: "sub1", contents: [
                    .directory(name: "deep", contents: [])
                ]),
                .directory(name: "sub2", contents: []),
                .file(name: "a.txt", size: 1)
            ])
        let index = try TreeBuilder.build(root: root, options: defaultOptions())
        XCTAssertEqual(index.root.directoryChildCount, 2)
        XCTAssertEqual(index.lookup(name: "sub1", in: index.rootID)?.directoryChildCount, 1)
        XCTAssertEqual(index.lookup(name: "sub2", in: index.rootID)?.directoryChildCount, 0)
    }

    // MARK: - macOS cache-control dotfiles

    func testAddsMacosCacheControlFiles() throws {
        var opts = defaultOptions()
        opts.addMacosCacheFiles = true
        let root: TreeNode = .directory(name: "root", contents: [.file(name: "a.txt", size: 1)])
        let index = try TreeBuilder.build(root: root, options: opts)

        for name in [".metadata_never_index", ".metadata_never_index_unless_rootfs", ".metadata_direct_scope_only"] {
            guard let file = index.lookup(name: name, in: index.rootID) else {
                return XCTFail("missing cache-control entry: \(name)")
            }
            XCTAssertEqual(file.kind, .file)
            XCTAssertEqual(file.size, 0)
        }
    }

    func testDoesNotAddCacheControlFilesWhenDisabled() throws {
        // defaultOptions() already disables; assert the opt-out actually omits them.
        let root: TreeNode = .directory(name: "root", contents: [.file(name: "a.txt", size: 1)])
        let index = try TreeBuilder.build(root: root, options: defaultOptions())

        XCTAssertNil(index.lookup(name: ".metadata_never_index", in: index.rootID))
        XCTAssertEqual(index.root.childrenIDs.count, 1)
    }

    func testCacheControlFilesOnlyAddedToRoot() throws {
        // A nested dir must NOT receive the dotfiles — they're a volume-level hint.
        var opts = defaultOptions()
        opts.addMacosCacheFiles = true
        let root: TreeNode = .directory(
            name: "root",
            contents: [
                .directory(name: "sub", contents: [.file(name: "x.txt", size: 1)])
            ])
        let index = try TreeBuilder.build(root: root, options: opts)
        let sub = index.lookup(name: "sub", in: index.rootID)
        XCTAssertNotNil(sub)
        XCTAssertNil(index.lookup(name: ".metadata_never_index", in: sub!.id))
    }

    func testCacheControlFilesDedupAgainstTreeContents() throws {
        // archive_torture_format_sentinels.json (and similar fixtures)
        // include `.metadata_never_index` in the JSON tree itself. Adding
        // ours on top would case-fold-collide and the whole mount would
        // fail. We should silently dedup and let the tree's own copy win.
        var opts = defaultOptions()
        opts.addMacosCacheFiles = true
        let root: TreeNode = .directory(
            name: "root",
            contents: [
                .file(name: ".metadata_never_index", size: 42),
                .file(name: "a.txt", size: 1)
            ])
        let index = try TreeBuilder.build(root: root, options: opts)

        // Tree's own copy preserved (size 42, not the empty 0-byte one
        // we'd have added).
        let tree = index.lookup(name: ".metadata_never_index", in: index.rootID)
        XCTAssertEqual(tree?.size, 42)

        // The other two cache-control extras still get added.
        XCTAssertNotNil(index.lookup(name: ".metadata_never_index_unless_rootfs", in: index.rootID))
        XCTAssertNotNil(index.lookup(name: ".metadata_direct_scope_only", in: index.rootID))

        // Total root children: tree's 2 + 2 of our extras (3rd was dedup'd).
        XCTAssertEqual(index.root.childrenIDs.count, 4)
    }

    // MARK: - integration with real fixture

    func testBuildsFromVendoredTestJson() throws {
        let data = try FixtureLoader.data("test")
        let tree = try JSONTree.load(from: data)
        let index = try TreeBuilder.build(root: tree, options: defaultOptions())

        XCTAssertEqual(index.root.childrenIDs.count, 10)
        for idx in 0..<10 {
            let name = "filename00000000\(idx).txt"
            guard let file = index.lookup(name: name, in: index.rootID) else {
                return XCTFail("missing fixture entry: \(name)")
            }
            XCTAssertEqual(file.size, 1024)
            XCTAssertEqual(file.kind, .file)
        }
    }

    // MARK: - constants

    func testVolumeStatBlockSizePinnedAt4096() {
        // Pinned because TestFSVolume.buildAttributes uses this value as
        // directories' st_size to match Python jsonfs.py. If the volume
        // block size ever changes, the directory st_size flips with it
        // and the parity contract has to be revisited.
        XCTAssertEqual(TreeBuilder.volumeStatBlockSize, 4096)
    }

}

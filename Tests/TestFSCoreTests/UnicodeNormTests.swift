//
//  UnicodeNormTests.swift
//

import XCTest

@testable import TestFSCore

final class UnicodeNormTests: XCTestCase {

    // MARK: - default

    func testDefaultIsNFD() {
        XCTAssertEqual(MountOptions.default.unicodeNormalization, .nfd)
    }

    // MARK: - apply

    /// "café" as NFC is 4 Unicode scalars (c, a, f, é); as NFD it's 5
    /// (c, a, f, e, combining acute). We assert on UTF-8 byte length so
    /// Swift's canonical-equivalence String == doesn't mask byte differences.
    func testApplyNFC() {
        let nfd = "cafe\u{0301}"  // e + combining acute
        let nfc = UnicodeNormalization.nfc.apply(to: nfd)
        XCTAssertEqual(Data(nfc.utf8), Data("café".utf8))
    }

    func testApplyNFD() {
        let nfc = "café"  // precomposed é
        let nfd = UnicodeNormalization.nfd.apply(to: nfc)
        XCTAssertEqual(Data(nfd.utf8), Data("cafe\u{0301}".utf8))
    }

    func testApplyNoneIsIdentity() {
        let nfd = "cafe\u{0301}"
        XCTAssertEqual(UnicodeNormalization.none.apply(to: nfd), nfd)
    }

    // MARK: - lookup round-trips across forms

    func testNFDStoresAndLooksUpCrossForm() throws {
        // Tree contains a file whose name is stored in NFD form. A kernel
        // callback arriving with the same name in NFC form must still resolve.
        let nfdRoot = TreeNode.directory(
            name: "root",
            contents: [
                .file(name: "cafe\u{0301}.txt", size: 10)  // NFD
            ])
        var opts = MountOptions.default
        opts.unicodeNormalization = .nfd
        let index = try TreeBuilder.build(root: nfdRoot, options: opts)

        let nfc = "café.txt"  // precomposed, 2 bytes shorter than NFD
        XCTAssertNotNil(index.lookup(name: nfc, in: index.rootID))
    }

    func testNoneNormalizationPreservesRawBytes() throws {
        // With normalization=none, names pass through unchanged. Swift's
        // `==` on String is canonical-equivalence, so we check the raw
        // UTF-8 bytes to prove no normalization was applied.
        let nfdRoot = TreeNode.directory(
            name: "root",
            contents: [
                .file(name: "cafe\u{0301}.txt", size: 10)
            ])
        var opts = MountOptions.default
        opts.unicodeNormalization = UnicodeNormalization.none
        let index = try TreeBuilder.build(root: nfdRoot, options: opts)

        let stored = index.nodesByID[index.rootID]!.childrenIDs
            .compactMap { index.nodesByID[$0]?.name }
            .first!
        XCTAssertEqual(Data(stored.utf8), Data("cafe\u{0301}.txt".utf8))
    }
}

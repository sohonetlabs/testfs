//
//  CaseSensitivityTests.swift
//
//  TestFS is case-sensitive (matches Python `jsonfs.py` upstream and
//  the FSPersonality flag in TestFSExtension/Info.plist). These tests
//  pin the contract: case is preserved, never folded; NFC and NFD
//  byte sequences are distinct unless the user opts into a
//  canonicalising unicode_normalization mode. Issue #14.
//

import Foundation
import XCTest

@testable import TestFSCore

final class CaseSensitivityTests: XCTestCase {

    private func defaultOptions() -> MountOptions {
        var opts = MountOptions.default
        opts.config = "/tmp/test.json"
        opts.addMacosCacheFiles = false
        return opts
    }

    /// archive_torture_evil_filenames.json contains visually-identical
    /// `é`s with distinct byte sequences (NFC U+00E9 vs NFD U+0065+U+0301).
    /// With unicode_normalization=none, neither sequence is rewritten
    /// and the two files must be treated as distinct entries — same as
    /// the Python upstream, which never folds case and only normalizes
    /// when the user opts in.
    func testNFCAndNFDDistinctUnderNoneNormalization() throws {
        var opts = defaultOptions()
        opts.unicodeNormalization = .none
        let nfc = "\u{00E9}.txt"
        let nfd = "\u{0065}\u{0301}.txt"
        XCTAssertNotEqual(
            Data(nfc.utf8), Data(nfd.utf8),
            "NFC and NFD must have distinct UTF-8 byte representations")

        let root: TreeNode = .directory(name: "root", contents: [
            .file(name: nfc, size: 10),
            .file(name: nfd, size: 20)
        ])
        let index = try TreeBuilder.build(root: root, options: opts)
        XCTAssertEqual(index.root.childrenIDs.count, 2)
        XCTAssertEqual(index.lookup(name: nfc, in: index.rootID)?.size, 10)
        XCTAssertEqual(index.lookup(name: nfd, in: index.rootID)?.size, 20)
    }

    /// Lower- and upper-case siblings are independent files (matches
    /// Python's path_map keying — case is preserved, never folded).
    func testCaseDistinctSiblings() throws {
        let root: TreeNode = .directory(name: "root", contents: [
            .file(name: "Foo.txt", size: 100),
            .file(name: "foo.txt", size: 200)
        ])
        let index = try TreeBuilder.build(root: root, options: defaultOptions())
        XCTAssertEqual(index.root.childrenIDs.count, 2)
        XCTAssertEqual(index.lookup(name: "Foo.txt", in: index.rootID)?.size, 100)
        XCTAssertEqual(index.lookup(name: "foo.txt", in: index.rootID)?.size, 200)
    }

    /// Lookup is byte-exact after normalization. The wrong case must
    /// not resolve.
    func testCaseSensitiveLookupMissesWrongCase() throws {
        let root: TreeNode = .directory(name: "root", contents: [
            .file(name: "foo.txt", size: 1)
        ])
        let index = try TreeBuilder.build(root: root, options: defaultOptions())
        XCTAssertNotNil(index.lookup(name: "foo.txt", in: index.rootID))
        XCTAssertNil(index.lookup(name: "FOO.TXT", in: index.rootID))
        XCTAssertNil(index.lookup(name: "Foo.txt", in: index.rootID))
    }

    /// Normalization can still cause merges (NFC and NFD canonicalize
    /// to the same form under `.nfd`) and the duplicate must be flagged
    /// at build time. Pins the contract that normalization-induced
    /// duplicates still error, separately from the no-case-fold rule.
    func testNormalizationInducedDuplicateStillErrors() {
        var opts = defaultOptions()
        opts.unicodeNormalization = .nfd
        let root: TreeNode = .directory(name: "root", contents: [
            .file(name: "R\u{00E9}port.pdf", size: 1),
            .file(name: "Re\u{0301}port.pdf", size: 2)
        ])
        XCTAssertThrowsError(try TreeBuilder.build(root: root, options: opts))
    }
}

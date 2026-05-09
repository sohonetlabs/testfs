//
//  BOMNameTests.swift
//
//  Regression coverage for U+FEFF (zero-width no-break space / BOM)
//  in filenames. The fixture archive_torture_mojibake_traps.json
//  contains "\u{FEFF}file.txt"; under jsonfs.py upstream the BOM-
//  prefixed entry shows up in readdir output, but the Swift port
//  was previously losing it through the FSFileName Cocoa bridge
//  (NSString ingestion of a BOM-prefixed UTF-8 byte sequence
//  silently strips the BOM at construction time).
//
//  These tests pin the in-memory layer (TreeBuilder + TreeIndex):
//  the BOM byte sequence must reach the index intact and the
//  index must be findable both by the BOM-prefixed name and by
//  matching against `rawName` for enumerate. The FSKit-boundary
//  byte fidelity itself is exercised end-to-end by the parity
//  matrix (BOM is not introspectable from the SPM test target,
//  which doesn't link FSKit).
//

import Foundation
import XCTest

@testable import TestFSCore

final class BOMNameTests: XCTestCase {

    private func defaultOptions() -> MountOptions {
        var opts = MountOptions(config: "/tmp/ignored.json")
        opts.addMacosCacheFiles = false
        return opts
    }

    func testBOMPrefixedNameSurvivesBuild() throws {
        let bomName = "\u{FEFF}file.txt"
        let utf8 = Data(bomName.utf8)
        XCTAssertEqual(utf8.prefix(3), Data([0xEF, 0xBB, 0xBF]),
            "test premise: BOM-prefixed UTF-8 starts with 0xEF 0xBB 0xBF")

        let root: TreeNode = .directory(
            name: "r",
            contents: [.file(name: bomName, size: 7)]
        )
        let index = try TreeBuilder.build(root: root, options: defaultOptions())

        guard let child = index.lookup(name: bomName, in: index.rootID) else {
            return XCTFail("lookup with BOM-prefixed input must resolve")
        }
        XCTAssertEqual(child.size, 7)
        XCTAssertEqual(Data(child.rawName.utf8), utf8,
            "rawName must round-trip the original UTF-8 byte sequence (BOM included)")
    }

    func testBOMNameDistinctFromBareName() throws {
        // "\u{FEFF}file.txt" and "file.txt" are byte-distinct names;
        // the volume must treat them as siblings, not collapse them.
        let bom = "\u{FEFF}file.txt"
        let bare = "file.txt"
        let root: TreeNode = .directory(
            name: "r",
            contents: [
                .file(name: bom, size: 1),
                .file(name: bare, size: 2)
            ]
        )
        let index = try TreeBuilder.build(root: root, options: defaultOptions())

        XCTAssertEqual(index.root.childrenIDs.count, 2)
        XCTAssertEqual(index.lookup(name: bom, in: index.rootID)?.size, 1)
        XCTAssertEqual(index.lookup(name: bare, in: index.rootID)?.size, 2)
    }
}

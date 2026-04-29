//
//  SizeOverflowTests.swift
//
//  TestFS volume statistics report `(totalFileBytes + 4095) / 4096`
//  blocks (see `TestFSVolume.volumeStatistics`); the addition overflows
//  once `totalFileBytes` passes `UInt64.max - 4095`. TreeBuilder
//  rejects oversized inputs at build time so the volume layer can
//  rely on the math. Issue #18.
//

import XCTest

@testable import TestFSCore

final class SizeOverflowTests: XCTestCase {

    private func defaultOptions() -> MountOptions {
        var opts = MountOptions(config: "/tmp/ignored.json")
        opts.addMacosCacheFiles = false
        return opts
    }

    func testMaxAcceptedFileSizePreserved() throws {
        let max = TreeBuilder.maxTotalFileBytes
        let root: TreeNode = .directory(
            name: "r",
            contents: [.file(name: "huge", size: max)])
        let index = try TreeBuilder.build(root: root, options: defaultOptions())
        XCTAssertEqual(index.lookup(name: "huge", in: index.rootID)?.size, max)
    }

    func testBuildRejectsUInt64MaxFile() {
        let root: TreeNode = .directory(
            name: "r",
            contents: [.file(name: "huge", size: UInt64.max)])
        XCTAssertThrowsError(try TreeBuilder.build(root: root, options: defaultOptions())) { error in
            guard let err = error as? TreeBuilder.BuildError,
                case .totalSizeOverflow = err
            else {
                return XCTFail("expected .totalSizeOverflow, got \(error)")
            }
        }
    }

    func testBuildRejectsAccumulatedSizeOverflow() {
        let half = UInt64.max / 2 + 1
        let root: TreeNode = .directory(
            name: "r",
            contents: [
                .file(name: "a", size: half),
                .file(name: "b", size: half)
            ])
        XCTAssertThrowsError(try TreeBuilder.build(root: root, options: defaultOptions())) { error in
            guard let err = error as? TreeBuilder.BuildError,
                case .totalSizeOverflow = err
            else {
                return XCTFail("expected .totalSizeOverflow, got \(error)")
            }
        }
    }
}

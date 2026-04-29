//
//  SizeOverflowTests.swift
//
//  TestFS volume statistics report `(totalFileBytes + 4095) / 4096`
//  blocks (see `TestFSVolume.volumeStatistics`); the addition overflows
//  once `totalFileBytes` passes `UInt64.max - 4095`. TreeBuilder
//  rejects oversized inputs at build time so the volume layer can
//  rely on the math.
//

import XCTest

@testable import TestFSCore

final class SizeOverflowTests: XCTestCase {

    private func defaultOptions() -> MountOptions {
        var opts = MountOptions(config: "/tmp/ignored.json")
        opts.addMacosCacheFiles = false
        return opts
    }

    private func assertThrowsTotalSizeOverflow(
        _ root: TreeNode, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try TreeBuilder.build(root: root, options: defaultOptions()),
            file: file, line: line
        ) { error in
            guard let err = error as? TreeBuilder.BuildError,
                case .totalSizeOverflow = err
            else {
                return XCTFail("expected .totalSizeOverflow, got \(error)", file: file, line: line)
            }
        }
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
        assertThrowsTotalSizeOverflow(.directory(
            name: "r",
            contents: [.file(name: "huge", size: UInt64.max)]))
    }

    func testBuildRejectsAccumulatedSizeOverflow() {
        let half = UInt64.max / 2 + 1
        assertThrowsTotalSizeOverflow(.directory(
            name: "r",
            contents: [
                .file(name: "a", size: half),
                .file(name: "b", size: half)
            ]))
    }
}

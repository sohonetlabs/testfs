//
//  BlockCacheTests.swift
//

import XCTest
@testable import TestFSCore

final class BlockCacheTests: XCTestCase {

    func testReadWithinBounds() {
        XCTAssertEqual(BlockCache.effectiveReadLength(fileSize: 1024, offset: 0, requestedLength: 100), 100)
    }

    func testReadClippedAtEOF() {
        // offset near end of file: return only what's left
        XCTAssertEqual(BlockCache.effectiveReadLength(fileSize: 1024, offset: 900, requestedLength: 200), 124)
        XCTAssertEqual(BlockCache.effectiveReadLength(fileSize: 1024, offset: 1023, requestedLength: 10), 1)
    }

    func testReadAtEOFReturnsZero() {
        XCTAssertEqual(BlockCache.effectiveReadLength(fileSize: 1024, offset: 1024, requestedLength: 100), 0)
    }

    func testReadPastEOFReturnsZero() {
        XCTAssertEqual(BlockCache.effectiveReadLength(fileSize: 1024, offset: 2000, requestedLength: 100), 0)
    }

    func testReadFromEmptyFileReturnsZero() {
        XCTAssertEqual(BlockCache.effectiveReadLength(fileSize: 0, offset: 0, requestedLength: 100), 0)
    }

    func testNegativeRequestedLengthNormalizesToZero() {
        // Defensive: if the kernel ever hands us a negative length we
        // should not read anything, not panic on an unsigned conversion.
        XCTAssertEqual(BlockCache.effectiveReadLength(fileSize: 1024, offset: 0, requestedLength: -1), 0)
    }

    // MARK: - semi-random generation

    func testGenerateProducesRequestedCountAndSize() {
        let cache = BlockCache(count: 8, blockSize: 256, seed: 4)
        XCTAssertEqual(cache.blocks.count, 8)
        XCTAssertEqual(cache.blockSize, 256)
        for block in cache.blocks {
            XCTAssertEqual(block.count, 256)
        }
    }

    func testGenerationIsDeterministicForSameSeed() {
        let lhs = BlockCache(count: 4, blockSize: 128, seed: 4)
        let rhs = BlockCache(count: 4, blockSize: 128, seed: 4)
        XCTAssertEqual(lhs.blocks, rhs.blocks)
    }

    func testDifferentSeedsProduceDifferentCaches() {
        let lhs = BlockCache(count: 4, blockSize: 128, seed: 4)
        let rhs = BlockCache(count: 4, blockSize: 128, seed: 5)
        XCTAssertNotEqual(lhs.blocks, rhs.blocks)
    }

    func testEachGeneratedBlockIsDistinct() {
        // 1024 is a multiple of 256, the period of `s & 0xFF` on the
        // LCG — so a single LCG stream would produce identical blocks.
        let cache = BlockCache(count: 8, blockSize: 1024, seed: 4)
        XCTAssertEqual(Set(cache.blocks).count, 8)
    }

    func testGeneratedBytesSpanARange() {
        // A single 4 KiB block of LCG output should hit most byte values.
        let cache = BlockCache(count: 1, blockSize: 4096, seed: 4)
        let unique = Set(cache.blocks[0])
        XCTAssertGreaterThan(unique.count, 200, "LCG should produce reasonably distributed bytes")
    }

    // MARK: - block lookup

    func testBlockDataIsDeterministicForSamePathAndBlock() {
        let cache = BlockCache(count: 32, blockSize: 64, seed: 4)
        let lhs = cache.blockData(path: "/foo.txt", block: 0)
        let rhs = cache.blockData(path: "/foo.txt", block: 0)
        XCTAssertEqual(lhs, rhs)
    }

    func testBlockDataDiffersAcrossDifferentPaths() {
        // With 32 buckets the chance of collision for two random paths is
        // 1/32 — running across three pairs makes a false positive vanishingly rare.
        let cache = BlockCache(count: 32, blockSize: 64, seed: 4)
        let pairs: [(String, String)] = [
            ("/a.txt", "/b.txt"),
            ("/dir/file1", "/dir/file2"),
            ("/x", "/y")
        ]
        let differing = pairs.filter { cache.blockData(path: $0.0, block: 0) != cache.blockData(path: $0.1, block: 0) }
        XCTAssertGreaterThan(differing.count, 0, "different paths should map to different blocks for at least one pair")
    }

    func testBlockDataDiffersAcrossBlockIndices() {
        let cache = BlockCache(count: 32, blockSize: 64, seed: 4)
        let differing = (0..<5).filter {
            cache.blockData(path: "/foo.txt", block: 0) != cache.blockData(path: "/foo.txt", block: UInt64($0 + 1))
        }
        XCTAssertGreaterThan(differing.count, 0, "different block indices should not all collide on the same bucket")
    }

    // MARK: - read splicing

    /// Test helper: allocate a Data of `length` bytes and let the cache fill it.
    private func read(_ cache: BlockCache, path: String, offset: UInt64, length: Int, fileSize: UInt64) -> Data {
        var buf = Data(count: length)
        let written = buf.withUnsafeMutableBytes { raw in
            cache.read(path: path, offset: offset, length: length, fileSize: fileSize, into: raw.baseAddress!)
        }
        return buf.prefix(written)
    }

    func testReadFromCacheReturnsRequestedBytes() {
        let cache = BlockCache(count: 8, blockSize: 16, seed: 4)
        XCTAssertEqual(read(cache, path: "/foo", offset: 0, length: 10, fileSize: 100).count, 10)
    }

    func testReadFromCacheClipsAtEOF() {
        let cache = BlockCache(count: 8, blockSize: 16, seed: 4)
        XCTAssertEqual(read(cache, path: "/foo", offset: 90, length: 50, fileSize: 100).count, 10)
    }

    func testReadFromCachePastEOFReturnsEmpty() {
        let cache = BlockCache(count: 8, blockSize: 16, seed: 4)
        XCTAssertTrue(read(cache, path: "/foo", offset: 100, length: 10, fileSize: 100).isEmpty)
    }

    func testReadFromCacheSpansBlockBoundary() {
        // blockSize=16, read 20 bytes starting at offset 8: needs the last
        // 8 bytes of block 0 and the first 12 of block 1.
        let cache = BlockCache(count: 8, blockSize: 16, seed: 4)
        let data = read(cache, path: "/foo", offset: 8, length: 20, fileSize: 100)
        XCTAssertEqual(data.count, 20)
        let block0 = cache.blockData(path: "/foo", block: 0)
        let block1 = cache.blockData(path: "/foo", block: 1)
        XCTAssertEqual(Data(data.prefix(8)), block0.suffix(8))
        XCTAssertEqual(Data(data.suffix(12)), block1.prefix(12))
    }

    func testReadFromCacheIsRepeatable() {
        let cache = BlockCache(count: 8, blockSize: 16, seed: 4)
        let lhs = read(cache, path: "/foo", offset: 5, length: 30, fileSize: 100)
        let rhs = read(cache, path: "/foo", offset: 5, length: 30, fileSize: 100)
        XCTAssertEqual(lhs, rhs)
    }
}

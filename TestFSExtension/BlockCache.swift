//
//  BlockCache.swift
//  TestFSCore / TestFSExtension
//

import Foundation
import CryptoKit

/// Pre-generated pseudo-random byte blocks served in semi-random read mode.
/// Same `seed` reproduces the same blocks; same `path`+`block` index always
/// returns the same block so `cat` is deterministic across mounts.
struct BlockCache: Sendable {
    let blocks: [Data]
    let blockSize: Int

    /// Build a cache by running the LCG
    /// `s = (s * 1103515245 + 12345) & 0x7FFFFFFF` and taking `s & 0xFF` for
    /// each byte. Each block gets its own starting state derived from
    /// `(seed, blockIdx)` — `s & 0xFF` has period 256, so threading state
    /// across blocks would make every block of size N*256 byte-identical
    /// (Python sidesteps this by re-seeding each block from MT). Bytes do
    /// NOT match Python; we only guarantee Swift↔Swift determinism.
    ///
    /// `path` inputs to `blockData` / `read` are treated as opaque keys.
    /// Unicode normalization is the caller's responsibility: in practice
    /// TestFSVolume hands us `TestFSItem.path`, which is built from
    /// names that TreeBuilder has already normalized, so NFC and NFD
    /// variants of the same name resolve to the same vnode (and hence
    /// the same path) long before they reach this layer.
    init(count: Int, blockSize: Int, seed: UInt32) {
        precondition(count > 0, "count must be > 0")
        precondition(blockSize > 0, "blockSize must be > 0")
        var buf = [UInt8](repeating: 0, count: blockSize)
        var generated: [Data] = []
        generated.reserveCapacity(count)
        for blockIdx in 0..<count {
            // Knuth multiplier 2654435761 spreads adjacent block indices
            // across the 32-bit space so neighbouring blocks aren't correlated.
            var state: UInt32 = seed &+ UInt32(truncatingIfNeeded: blockIdx) &* 2654435761
            for byteIdx in 0..<blockSize {
                state = (state &* 1103515245 &+ 12345) & 0x7FFFFFFF
                buf[byteIdx] = UInt8(state & 0xFF)
            }
            generated.append(Data(buf))
        }
        self.blocks = generated
        self.blockSize = blockSize
    }

    /// Pre-generated block for `(path, block)`. Different paths or block
    /// indices land on different buckets uniformly mod `blocks.count`.
    func blockData(path: String, block: UInt64) -> Data {
        blocks[bucket(path: path, block: block)]
    }

    private func bucket(path: String, block: UInt64) -> Int {
        let key = "\(path)\u{01}\(block)"
        let digest = Insecure.MD5.hash(data: Data(key.utf8))
        let idx: UInt64 = digest.withUnsafeBytes { $0.load(as: UInt64.self).bigEndian }
        return Int(idx % UInt64(blocks.count))
    }

    /// Write `length` bytes starting at `offset` for `path` into `dest`,
    /// stitched across block boundaries. Returns the number of bytes
    /// written (clipped at EOF; 0 when offset is at or past EOF). The
    /// caller is responsible for ensuring `dest` has room for `length`.
    @discardableResult
    func read(
        path: String,
        offset: UInt64,
        length: Int,
        fileSize: UInt64,
        into dest: UnsafeMutableRawPointer
    ) -> Int {
        let effective = BlockCache.effectiveReadLength(
            fileSize: fileSize, offset: offset, requestedLength: length
        )
        guard effective > 0 else { return 0 }
        let blockBytes = UInt64(blockSize)
        var off = offset
        var written = 0
        while written < effective {
            let blockIdx = off / blockBytes
            let inBlock = Int(off % blockBytes)
            let take = min(blockSize - inBlock, effective - written)
            blocks[bucket(path: path, block: blockIdx)].withUnsafeBytes { src in
                memcpy(dest.advanced(by: written), src.baseAddress! + inBlock, take)
            }
            off &+= UInt64(take)
            written += take
        }
        return written
    }

    /// Bytes served for a read at `offset` requesting `requestedLength`
    /// from a file of `fileSize` bytes. Returns 0 past EOF; clips the
    /// tail read at EOF. `requestedLength` must be non-negative — the
    /// caller is responsible for rejecting negative lengths.
    static func effectiveReadLength(
        fileSize: UInt64,
        offset: UInt64,
        requestedLength: Int
    ) -> Int {
        guard offset < fileSize, requestedLength > 0 else { return 0 }
        let remaining = fileSize - offset
        return Int(min(UInt64(requestedLength), remaining))
    }
}

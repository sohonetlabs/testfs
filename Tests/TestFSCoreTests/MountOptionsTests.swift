//
//  MountOptionsTests.swift
//

import XCTest
@testable import TestFSCore

final class MountOptionsTests: XCTestCase {

    // MARK: - default values

    func testDefaultsMatchPythonCLI() {
        let defaults = MountOptions.default
        XCTAssertEqual(defaults.fillChar, "\u{0000}", "Python --fill-char default is null byte")
        XCTAssertFalse(defaults.semiRandom)
        XCTAssertEqual(defaults.blockSize, "128K", "Python --block-size CLI default")
        XCTAssertEqual(defaults.preGeneratedBlocks, 100, "Python --pre-generated-blocks CLI default")
        XCTAssertEqual(defaults.seed, 4, "Python --seed CLI default")
        XCTAssertEqual(defaults.rateLimit, 0)
        XCTAssertEqual(defaults.iopLimit, 0)
        XCTAssertEqual(defaults.unicodeNormalization, .nfd, "Python default is NFD")
        XCTAssertNil(defaults.uid, "unset -> getuid() at apply time")
        XCTAssertNil(defaults.gid, "unset -> getgid() at apply time")
        XCTAssertEqual(defaults.mtime, "2017-10-17")
        XCTAssertFalse(defaults.ignoreAppledouble)
        XCTAssertTrue(defaults.addMacosCacheFiles)
    }

    // MARK: - full decode

    func testDecodesFullSidecarJson() throws {
        let json = Data(
            """
            {
              "config": "/tmp/tree.json",
              "fill_char": "A",
              "semi_random": true,
              "block_size": "1M",
              "pre_generated_blocks": 50,
              "seed": 12345,
              "rate_limit": 0.1,
              "iop_limit": 100,
              "unicode_normalization": "NFC",
              "uid": 501,
              "gid": 20,
              "mtime": "2020-01-01",
              "ignore_appledouble": true,
              "add_macos_cache_files": false
            }
            """.utf8)
        let opts = try MountOptions.load(from: json)
        XCTAssertEqual(opts.config, "/tmp/tree.json")
        XCTAssertEqual(opts.fillChar, "A")
        XCTAssertTrue(opts.semiRandom)
        XCTAssertEqual(opts.blockSize, "1M")
        XCTAssertEqual(opts.preGeneratedBlocks, 50)
        XCTAssertEqual(opts.seed, 12345)
        XCTAssertEqual(opts.rateLimit, 0.1, accuracy: 1e-9)
        XCTAssertEqual(opts.iopLimit, 100)
        XCTAssertEqual(opts.unicodeNormalization, .nfc)
        XCTAssertEqual(opts.uid, 501)
        XCTAssertEqual(opts.gid, 20)
        XCTAssertEqual(opts.mtime, "2020-01-01")
        XCTAssertTrue(opts.ignoreAppledouble)
        XCTAssertFalse(opts.addMacosCacheFiles)
    }

    // MARK: - minimal decode with defaults

    func testDecodesMinimalSidecarJson() throws {
        let json = Data(#"{"config": "/tmp/tree.json"}"#.utf8)
        let opts = try MountOptions.load(from: json)
        XCTAssertEqual(opts.config, "/tmp/tree.json")
        // Every other field must match the defaults exactly.
        let defaults = MountOptions.default
        XCTAssertEqual(opts.fillChar, defaults.fillChar)
        XCTAssertEqual(opts.semiRandom, defaults.semiRandom)
        XCTAssertEqual(opts.blockSize, defaults.blockSize)
        XCTAssertEqual(opts.preGeneratedBlocks, defaults.preGeneratedBlocks)
        XCTAssertEqual(opts.seed, defaults.seed)
        XCTAssertEqual(opts.rateLimit, defaults.rateLimit)
        XCTAssertEqual(opts.iopLimit, defaults.iopLimit)
        XCTAssertEqual(opts.unicodeNormalization, defaults.unicodeNormalization)
        XCTAssertEqual(opts.uid, defaults.uid)
        XCTAssertEqual(opts.gid, defaults.gid)
        XCTAssertEqual(opts.mtime, defaults.mtime)
        XCTAssertEqual(opts.ignoreAppledouble, defaults.ignoreAppledouble)
        XCTAssertEqual(opts.addMacosCacheFiles, defaults.addMacosCacheFiles)
    }

    // MARK: - rejection cases

    func testRejectsMissingConfig() {
        let json = Data("{}".utf8)
        XCTAssertThrowsError(try MountOptions.load(from: json)) { error in
            guard let err = error as? MountOptions.LoadError,
                case .missingConfig = err
            else {
                return XCTFail("expected .missingConfig, got \(error)")
            }
        }
    }

    func testRejectsEmptyConfigString() {
        let json = Data(#"{"config": ""}"#.utf8)
        XCTAssertThrowsError(try MountOptions.load(from: json)) { error in
            guard let err = error as? MountOptions.LoadError,
                case .missingConfig = err
            else {
                return XCTFail("expected .missingConfig for empty config string, got \(error)")
            }
        }
    }

    func testRejectsInvalidFillChar() {
        let json = Data(#"{"config":"/t","fill_char":"AB"}"#.utf8)
        XCTAssertThrowsError(try MountOptions.load(from: json)) { error in
            guard let err = error as? MountOptions.LoadError,
                case .invalidFillChar = err
            else {
                return XCTFail("expected .invalidFillChar, got \(error)")
            }
        }
    }

    func testRejectsEmptyFillChar() {
        let json = Data(#"{"config":"/t","fill_char":""}"#.utf8)
        XCTAssertThrowsError(try MountOptions.load(from: json)) { error in
            guard let err = error as? MountOptions.LoadError,
                case .invalidFillChar = err
            else {
                return XCTFail("expected .invalidFillChar for empty string, got \(error)")
            }
        }
    }

    func testRejectsMultiByteFillChar() {
        // "é" is a single grapheme (count=1) but 2 UTF-8 bytes. The
        // read path memsets a single byte, so we reject at load time.
        let json = Data(#"{"config":"/t","fill_char":"é"}"#.utf8)
        XCTAssertThrowsError(try MountOptions.load(from: json)) { error in
            guard let err = error as? MountOptions.LoadError,
                case .invalidFillChar = err
            else {
                return XCTFail("expected .invalidFillChar for multi-byte char, got \(error)")
            }
        }
    }

    func testRejectsMalformedJSON() {
        let json = Data("not json".utf8)
        XCTAssertThrowsError(try MountOptions.load(from: json)) { error in
            guard let err = error as? MountOptions.LoadError,
                case .malformed = err
            else {
                return XCTFail("expected .malformed, got \(error)")
            }
        }
    }

    func testRejectsInvalidBlockSize() {
        let json = Data(#"{"config":"/t","block_size":"128X"}"#.utf8)
        XCTAssertThrowsError(try MountOptions.load(from: json)) { error in
            guard let err = error as? MountOptions.LoadError,
                case .invalidBlockSize = err
            else {
                return XCTFail("expected .invalidBlockSize, got \(error)")
            }
        }
    }

    func testRejectsNegativeIopLimit() {
        let json = Data(#"{"config":"/t","iop_limit":-1}"#.utf8)
        XCTAssertThrowsError(try MountOptions.load(from: json)) { error in
            guard let err = error as? MountOptions.LoadError,
                case .invalidIopLimit = err
            else {
                return XCTFail("expected .invalidIopLimit, got \(error)")
            }
        }
    }

    func testRejectsZeroPreGeneratedBlocks() {
        let json = Data(#"{"config":"/t","pre_generated_blocks":0}"#.utf8)
        XCTAssertThrowsError(try MountOptions.load(from: json)) { error in
            guard let err = error as? MountOptions.LoadError,
                case .invalidPreGeneratedBlocks = err
            else {
                return XCTFail("expected .invalidPreGeneratedBlocks, got \(error)")
            }
        }
    }

    func testRejectsInvalidMtime() {
        // A bad mtime would otherwise mount silently with epoch
        // timestamps for every file (issue #24).
        let json = Data(#"{"config":"/t","mtime":"not-a-date"}"#.utf8)
        XCTAssertThrowsError(try MountOptions.load(from: json)) { error in
            guard let err = error as? MountOptions.LoadError,
                case .invalidMtime = err
            else {
                return XCTFail("expected .invalidMtime, got \(error)")
            }
        }
    }

    func testRejectsUnknownUnicodeNormalization() {
        let json = Data(#"{"config":"/t","unicode_normalization":"NFZ"}"#.utf8)
        XCTAssertThrowsError(try MountOptions.load(from: json)) { error in
            guard let err = error as? MountOptions.LoadError,
                case .malformed = err
            else {
                return XCTFail("expected .malformed for unknown unicode form, got \(error)")
            }
        }
    }

    // MARK: - parseSize

    func testParseSizeAcceptsBareInteger() {
        XCTAssertEqual(parseSize("100"), 100)
        XCTAssertEqual(parseSize("1"), 1)
    }

    func testParseSizeAcceptsKMGSuffixes() {
        XCTAssertEqual(parseSize("1K"), 1024)
        XCTAssertEqual(parseSize("128K"), 128 * 1024)
        XCTAssertEqual(parseSize("1M"), 1024 * 1024)
        XCTAssertEqual(parseSize("1G"), 1024 * 1024 * 1024)
    }

    func testParseSizeIsCaseInsensitive() {
        XCTAssertEqual(parseSize("128k"), 128 * 1024)
        XCTAssertEqual(parseSize("1m"), 1024 * 1024)
    }

    func testParseSizeRejectsGarbage() {
        XCTAssertNil(parseSize(""))
        XCTAssertNil(parseSize("abc"))
        XCTAssertNil(parseSize("128X"))
        XCTAssertNil(parseSize("K"))
        XCTAssertNil(parseSize("-1K"))
    }

    // The `Int(body)` guard above is not enough — multiplying a valid
    // Int body by the K/M/G scalar can still overflow.
    func testParseSizeReturnsNilOnSuffixMultiplyOverflow() {
        let intMax = String(Int.max)
        XCTAssertNil(parseSize("\(intMax)K"))
        XCTAssertNil(parseSize("\(intMax)M"))
        XCTAssertNil(parseSize("\(intMax)G"))
        let firstOverflowingK = (Int.max / 1024) + 1
        XCTAssertNil(parseSize("\(firstOverflowingK)K"))
    }

    func testParseSizeAcceptsLargestRepresentableSuffixedValue() {
        let maxK = Int.max / 1024
        XCTAssertEqual(parseSize("\(maxK)K"), maxK * 1024)
    }

    // MARK: - round-trip

    func testRoundTripEncodesAllFields() throws {
        let original = MountOptions(
            config: "/tmp/tree.json",
            fillChar: "X",
            semiRandom: true,
            blockSize: "2M",
            preGeneratedBlocks: 200,
            seed: 99,
            rateLimit: 0.25,
            iopLimit: 500,
            unicodeNormalization: .nfkc,
            uid: 1000,
            gid: 1000,
            mtime: "2019-06-01",
            ignoreAppledouble: true,
            addMacosCacheFiles: false
        )
        let encoded = try JSONEncoder().encode(original)
        let decoded = try MountOptions.load(from: encoded)
        XCTAssertEqual(decoded, original)
    }
}

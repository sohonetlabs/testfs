//
//  AllFixturesTests.swift
//
//  Parses every fixture in research/test_json_fs/example/ via
//  JSONTree.load and asserts invariants. The small ones ship as direct
//  .json files in the test bundle; imdbfslayout ships as a .zip and is
//  unzipped to a shared temp dir on first access (cached across runs —
//  the unzipped form is ~40 MB so we intentionally do NOT commit it).
//

import XCTest
@testable import TestFSCore

final class AllFixturesTests: XCTestCase {

    private struct Fixture {
        let name: String  // base name without .json extension
        let rootName: String?  // expected root directory name, or nil for "don't care"
        let children: ClosedRange<Int>
        let note: String
    }

    private static let smallFixtures: [Fixture] = [
        Fixture(
            name: "test",
            rootName: "test",
            children: 10...10,
            note: "baseline: 10 × 1024-byte files"),
        Fixture(
            name: "32bit_tests",
            rootName: "./",
            children: 1...10,
            note: "signed/unsigned 32-bit file-size edges"),
        Fixture(
            name: "bad_s3",
            rootName: "s3_illegal_names",
            children: 1...20,
            note: "file names illegal in S3"),
        Fixture(
            name: "bad_windows",
            rootName: "invalid_windows_filenames",
            children: 100...200,
            note: "file names illegal on Windows"),
        Fixture(
            name: "big_list_of_naughty_strings_fs",
            rootName: "./",
            children: 100...400,
            note: "blns.txt filenames — controls, Unicode, shell meta"),
        Fixture(
            name: "tartest_test_one_dir",
            rootName: "tartest_test_one_dir",
            children: 1000...2000,
            note: "tar: many files nested under one parent"),
        Fixture(
            name: "tartest_test_dir_spacing",
            rootName: "tartest_test_dir_spacing",
            children: 1000...2000,
            note: "tar: many files in one directory")
    ]

    // MARK: - dynamic enumeration

    /// Parse every `*.json` shipped in the Fixtures directory and assert
    /// the root is a directory. The named-fixture invariants below add
    /// stricter assertions for the ones we care about specifically; this
    /// test catches the case where a new bundled example file is added
    /// to `Examples/` (and copied into `Fixtures/`) but isn't in a
    /// `tree -J -s`-shaped form.
    func testEveryBundledFixtureParses() throws {
        let urls = Bundle.module.urls(
            forResourcesWithExtension: "json", subdirectory: "Fixtures") ?? []
        XCTAssertFalse(urls.isEmpty, "no fixtures found in test bundle")
        for url in urls {
            let data = try Data(contentsOf: url)
            do {
                let root = try JSONTree.load(from: data)
                guard case .directory = root else {
                    XCTFail("\(url.lastPathComponent) root was not a directory")
                    continue
                }
            } catch {
                XCTFail("\(url.lastPathComponent) failed to parse: \(error)")
            }
        }
    }

    // MARK: - small fixtures

    func testEverySmallFixtureParses() throws {
        for fixture in Self.smallFixtures {
            let data = try FixtureLoader.data(fixture.name)
            let root: TreeNode
            do {
                root = try JSONTree.load(from: data)
            } catch {
                XCTFail("\(fixture.name).json failed to parse: \(error) [\(fixture.note)]")
                continue
            }

            guard case .directory(let name, let contents) = root else {
                XCTFail("\(fixture.name).json root was not a directory: \(root)")
                continue
            }

            if let expected = fixture.rootName {
                XCTAssertEqual(
                    name, expected,
                    "\(fixture.name).json root name mismatch [\(fixture.note)]")
            }

            XCTAssertTrue(
                fixture.children.contains(contents.count),
                "\(fixture.name).json child count \(contents.count) outside \(fixture.children) [\(fixture.note)]")
        }
    }

    /// Assert the naughty-strings fixture preserves every child name through
    /// the decoder untouched — control characters and high-codepoint
    /// Unicode must both survive.
    func testNaughtyStringsPreservedThroughDecoder() throws {
        let data = try FixtureLoader.data("big_list_of_naughty_strings_fs")
        let root = try JSONTree.load(from: data)
        guard case .directory(_, let contents) = root else {
            return XCTFail("naughty-strings root not a directory")
        }

        let controlNames = contents.filter { child in
            child.name.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f }
        }
        XCTAssertGreaterThan(
            controlNames.count, 0,
            "expected at least one control-char filename in naughty-strings fixture")

        let unicodeNames = contents.filter { child in
            child.name.unicodeScalars.contains { $0.value > 0x7f }
        }
        XCTAssertGreaterThan(
            unicodeNames.count, 0,
            "expected non-ASCII filenames in naughty-strings fixture")
    }

    // MARK: - imdbfslayout (large, zipped)

    /// Extracted once per process (or reused across runs if the shared temp
    /// dir already contains the file). Errors are captured in a Result so
    /// test-time failures get a real diagnostic instead of a silent skip.
    private static let unzippedImdb: Result<URL, Error> = Result { try AllFixturesTests.extractImdb() }

    private static func extractImdb() throws -> URL {
        guard
            let zipURL = Bundle.module.url(
                forResource: "imdbfslayout.json",
                withExtension: "zip",
                subdirectory: "Fixtures"
            )
        else {
            throw FixtureLoader.LoadError.missing(name: "imdbfslayout.json.zip")
        }
        // Stable path (no PID) so repeated test runs reuse the extracted
        // JSON without leaking per-run ~40 MB temp dirs.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("testfs-imdbfslayout", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let out = tmp.appendingPathComponent("imdbfslayout.json")
        if FileManager.default.fileExists(atPath: out.path) {
            return out
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments = ["-o", "-q", zipURL.path, "-d", tmp.path]
        try proc.run()
        proc.waitUntilExit()

        guard FileManager.default.fileExists(atPath: out.path) else {
            throw NSError(
                domain: "TestFS", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "unzip reported success but \(out.path) is missing"]
            )
        }
        return out
    }

    func testImdbfsLayoutParses() throws {
        let url: URL
        switch Self.unzippedImdb {
        case .success(let unzipped):
            url = unzipped
        case .failure(let err):
            throw XCTSkip("imdbfslayout unzip failed: \(err)")
        }

        let data = try Data(contentsOf: url)
        let root = try JSONTree.load(from: data)
        guard case .directory(_, let contents) = root else {
            return XCTFail("imdbfslayout root was not a directory")
        }
        XCTAssertGreaterThan(contents.count, 0, "imdbfslayout root should have children")
    }
}

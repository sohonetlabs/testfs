//
//  BundledExamplesTests.swift
//
//  Covers the directory-listing helper that backs the host's
//  Examples ▾ menu. Drives `BundledExamples.sortedJSONURLs(in:)`
//  against synthetic temp directories so the test doesn't depend
//  on the production app bundle.
//

import XCTest
@testable import TestFSCore

final class BundledExamplesTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("BundledExamplesTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func write(_ name: String) throws {
        try Data().write(to: tmp.appendingPathComponent(name))
    }

    func testFiltersToJSONOnly() throws {
        // Two strict-`.json`, plus a `.txt`, a `.json.zip` (pathExtension == "zip"),
        // and a `.JSON` upper-case (case-mismatch — pathExtension matching is
        // case-sensitive, so we expect this to be excluded).
        try write("a.json")
        try write("b.txt")
        try write("c.json.zip")
        try write("d.JSON")
        try write("e.json")

        let urls = BundledExamples.sortedJSONURLs(in: tmp)
        XCTAssertEqual(urls.map { $0.lastPathComponent }, ["a.json", "e.json"])
    }

    func testSortsByBasename() throws {
        try write("zoo.json")
        try write("alpha.json")
        try write("beta.json")

        let urls = BundledExamples.sortedJSONURLs(in: tmp)
        XCTAssertEqual(urls.map { $0.lastPathComponent }, ["alpha.json", "beta.json", "zoo.json"])
    }

    func testReturnsEmptyForMissingDir() {
        let missing = tmp.appendingPathComponent("does-not-exist")
        XCTAssertEqual(BundledExamples.sortedJSONURLs(in: missing), [])
    }

    func testReturnsEmptyForNil() {
        XCTAssertEqual(BundledExamples.sortedJSONURLs(in: nil), [])
    }
}

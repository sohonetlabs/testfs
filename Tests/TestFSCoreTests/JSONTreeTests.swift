//
//  JSONTreeTests.swift
//

import XCTest
@testable import TestFSCore

final class JSONTreeTests: XCTestCase {

    // MARK: - happy path against real fixture

    func testParsesVendoredTestJson() throws {
        let data = try FixtureLoader.data("test")
        let root = try JSONTree.load(from: data)

        guard case .directory(_, let contents) = root else {
            return XCTFail("root should be a directory, got \(root)")
        }
        XCTAssertEqual(contents.count, 10, "test.json has 10 file children")
        for (idx, child) in contents.enumerated() {
            guard case .file(let name, let size) = child else {
                return XCTFail("child \(idx) not a file: \(child)")
            }
            XCTAssertEqual(size, 1024, "\(name) should be 1024 bytes")
            XCTAssertTrue(name.hasPrefix("filename"), "expected filenameNNNNNNNNN.txt, got \(name)")
        }
    }

    // MARK: - trailing-report handling

    func testIgnoresTrailingReport() throws {
        let data = Data(
            """
            [
              {"type": "directory", "name": "root", "contents": [
                {"type": "file", "name": "a.txt", "size": 10}
              ]},
              {"type": "report", "directories": 1, "files": 1}
            ]
            """.utf8)
        let root = try JSONTree.load(from: data)
        guard case .directory(let name, let contents) = root else {
            return XCTFail("root should be a directory")
        }
        XCTAssertEqual(name, "root")
        XCTAssertEqual(contents.count, 1)
    }

    // MARK: - rejection cases

    func testRejectsEmptyArray() {
        let data = Data("[]".utf8)
        XCTAssertThrowsError(try JSONTree.load(from: data)) { error in
            guard let err = error as? JSONTree.LoadError, case .emptyArray = err else {
                return XCTFail("expected .emptyArray, got \(error)")
            }
        }
    }

    func testRejectsFirstEntryNotDirectory() {
        let data = Data(#"[{"type":"file","name":"x","size":0}]"#.utf8)
        XCTAssertThrowsError(try JSONTree.load(from: data)) { error in
            guard let err = error as? JSONTree.LoadError,
                case .firstEntryNotDirectory(let type) = err
            else {
                return XCTFail("expected .firstEntryNotDirectory, got \(error)")
            }
            XCTAssertEqual(type, "file")
        }
    }

    func testRejectsNonArrayTopLevel() {
        let data = Data(#"{"type":"directory","name":"x"}"#.utf8)
        XCTAssertThrowsError(try JSONTree.load(from: data))
    }

    // Anything after the leading directory must be a tree-emitted
    // `report` summary; a second directory or file at the top level
    // would otherwise be silently dropped.
    func testRejectsTrailingDirectory() {
        let data = Data(
            """
            [
              {"type":"directory","name":"first","contents":[]},
              {"type":"directory","name":"second","contents":[]}
            ]
            """.utf8)
        XCTAssertThrowsError(try JSONTree.load(from: data)) { error in
            guard let err = error as? JSONTree.LoadError,
                case .unexpectedTrailingEntry(let type) = err
            else {
                return XCTFail("expected .unexpectedTrailingEntry, got \(error)")
            }
            XCTAssertEqual(type, "directory")
        }
    }

    func testRejectsTrailingFile() {
        let data = Data(
            """
            [
              {"type":"directory","name":"r","contents":[]},
              {"type":"file","name":"stray.txt","size":1}
            ]
            """.utf8)
        XCTAssertThrowsError(try JSONTree.load(from: data)) { error in
            guard let err = error as? JSONTree.LoadError,
                case .unexpectedTrailingEntry(let type) = err
            else {
                return XCTFail("expected .unexpectedTrailingEntry, got \(error)")
            }
            XCTAssertEqual(type, "file")
        }
    }

    // MARK: - optional/default fields

    func testAllowsMissingContents() throws {
        let data = Data(#"[{"type":"directory","name":"empty"}]"#.utf8)
        let root = try JSONTree.load(from: data)
        guard case .directory(name: "empty", let contents) = root else {
            return XCTFail("expected empty directory")
        }
        XCTAssertEqual(contents.count, 0)
    }

    func testAllowsMissingSizeOnFile() throws {
        let data = Data(
            """
            [{"type":"directory","name":"r","contents":[
              {"type":"file","name":"nosize.txt"}
            ]}]
            """.utf8)
        let root = try JSONTree.load(from: data)
        guard case .directory(_, let contents) = root,
            case .file(name: "nosize.txt", size: 0) = contents.first
        else {
            return XCTFail("expected file with default size 0")
        }
    }

    // MARK: - nested structure

    func testNestedDirectories() throws {
        let data = Data(
            """
            [{"type":"directory","name":"a","contents":[
              {"type":"directory","name":"b","contents":[
                {"type":"file","name":"c.txt","size":42}
              ]}
            ]}]
            """.utf8)
        let root = try JSONTree.load(from: data)
        guard case .directory(name: "a", let level1) = root,
            case .directory(name: "b", let level2) = level1.first,
            case .file(name: "c.txt", size: 42) = level2.first
        else {
            return XCTFail("nested tree structure wrong: \(root)")
        }
    }

    // MARK: - tree -J -s quirks

    func testAcceptsDirectorySizeField() throws {
        // tree -J -s emits directories with a "size" field alongside
        // "contents"; we tolerate and ignore it.
        let data = Data(
            """
            [{"type":"directory","name":"d","size":99999,"contents":[
              {"type":"file","name":"x.txt","size":10}
            ]}]
            """.utf8)
        let root = try JSONTree.load(from: data)
        guard case .directory(name: "d", let contents) = root else {
            return XCTFail("did not parse directory with size field")
        }
        XCTAssertEqual(contents.count, 1)
    }

    func testRejectsUnknownNodeType() {
        let data = Data(#"[{"type":"directory","name":"r","contents":[{"type":"symlink","name":"l"}]}]"#.utf8)
        XCTAssertThrowsError(try JSONTree.load(from: data)) { error in
            guard let err = error as? JSONTree.LoadError, case .malformed = err else {
                return XCTFail("expected .malformed LoadError, got \(error)")
            }
            XCTAssertTrue(
                err.localizedDescription.contains("symlink"),
                "error description should name the offending type; got: \(err.localizedDescription)"
            )
        }
    }
}

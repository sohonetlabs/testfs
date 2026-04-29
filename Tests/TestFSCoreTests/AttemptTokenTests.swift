//
//  AttemptTokenTests.swift
//
//  Tests for the per-attempt token plumbed through the sidecar
//  (`MountOptions.attemptToken`) and the failure marker
//  (`LoadFailureMarker.attemptToken`). The token defends against
//  stale markers from a slow-failing prior loadResource on a
//  reused /dev/diskN — the host's poll filter accepts a marker
//  only when its token matches the current attempt's sidecar.
//

import XCTest
@testable import TestFSCore

final class AttemptTokenTests: XCTestCase {

    func testAttemptTokenAbsentDecodesAsNil() throws {
        let json = Data("""
            {"config": "/tmp/tree.json"}
            """.utf8)
        let decoded = try MountOptions.load(from: json)
        XCTAssertNil(decoded.attemptToken)
    }

    func testLoadFailureMarkerRoundTripsAttemptToken() throws {
        let marker = LoadFailureMarker(
            error: "bad sidecar", attemptToken: "abc-123")
        let data = try JSONEncoder().encode(marker)
        let decoded = try JSONDecoder().decode(LoadFailureMarker.self, from: data)
        XCTAssertEqual(decoded.error, "bad sidecar")
        XCTAssertEqual(decoded.attemptToken, "abc-123")
    }

    func testLoadFailureMarkerDecodesWithoutAttemptToken() throws {
        // Forward-compat: a marker written by an older extension (or
        // by the peek-failed path) has no token. Decode must succeed
        // so logs aren't poisoned; the host's filter then rejects it.
        let json = Data(#"{"error": "old format"}"#.utf8)
        let decoded = try JSONDecoder().decode(LoadFailureMarker.self, from: json)
        XCTAssertEqual(decoded.error, "old format")
        XCTAssertNil(decoded.attemptToken)
    }
}

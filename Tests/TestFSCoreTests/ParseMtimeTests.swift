//
//  ParseMtimeTests.swift
//
//  MountOptions.parseMtime semantics. Kept separate from MountOptionsTests
//  so the latter doesn't drift over SwiftLint's type_body_length budget,
//  and so the parity-contract assertions for date parsing stay together
//  as more cases get added.
//

import XCTest
@testable import TestFSCore

final class ParseMtimeTests: XCTestCase {

    // MARK: - date-only form

    func testParseMtimeDateOnlyHonorsTimeZoneArgument() {
        // Python jsonfs.py:874-876 does:
        //   datetime.strptime(args.mtime, "%Y-%m-%d").timestamp()
        // strptime returns a naive datetime; .timestamp() then interprets
        // it as local time. Swift parity requires the same: midnight in
        // the supplied zone, NOT midnight UTC.
        //
        // Use an explicit non-UTC timezone here so the test discriminates
        // the bug regardless of host — UTC hosts (e.g. CI) would otherwise
        // trivially pass either implementation. PST/PDT is 7-8 hours
        // off UTC so the gap is unmissable.
        let pst = TimeZone(identifier: "America/Los_Angeles")!
        guard let parsed = MountOptions.parseMtime("2017-10-17", timeZone: pst) else {
            return XCTFail("parseMtime returned nil")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = pst
        var components = DateComponents()
        components.year = 2017
        components.month = 10
        components.day = 17
        guard let expected = calendar.date(from: components) else {
            return XCTFail("could not build expected local midnight")
        }
        XCTAssertEqual(
            parsed, expected,
            "parseMtime should interpret YYYY-MM-DD as midnight in the supplied timezone"
        )
    }

    // MARK: - full ISO 8601 form (timezone is explicit, parser must honor it)

    func testParseMtimeIsoUtcReturnsExactInstant() {
        // ISO 8601 datetime carries an explicit zone — interpret it as
        // given regardless of host timezone. 2017-10-17T00:00:00Z is
        // exactly the Unix epoch 1508198400.
        let parsed = MountOptions.parseMtime("2017-10-17T00:00:00Z")
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.timeIntervalSince1970, 1508198400)
    }

    // MARK: - rejection

    func testParseMtimeRejectsGarbage() {
        XCTAssertNil(MountOptions.parseMtime("not-a-date"))
        XCTAssertNil(MountOptions.parseMtime(""))
        XCTAssertNil(MountOptions.parseMtime("2017-13-50"))
    }
}

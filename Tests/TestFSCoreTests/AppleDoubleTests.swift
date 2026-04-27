//
//  AppleDoubleTests.swift
//

import XCTest

@testable import TestFSCore

final class AppleDoubleTests: XCTestCase {

    func testSuppressedWhenOptionOnAndNameStartsWithDotUnderscore() {
        XCTAssertTrue(isSuppressedAppleDoubleName("._foo", ignoreAppledouble: true))
        XCTAssertTrue(isSuppressedAppleDoubleName("._.DS_Store", ignoreAppledouble: true))
    }

    func testNotSuppressedWhenOptionOff() {
        XCTAssertFalse(isSuppressedAppleDoubleName("._foo", ignoreAppledouble: false))
    }

    func testNotSuppressedForRegularName() {
        XCTAssertFalse(isSuppressedAppleDoubleName("foo.txt", ignoreAppledouble: true))
        XCTAssertFalse(isSuppressedAppleDoubleName(".DS_Store", ignoreAppledouble: true))
        XCTAssertFalse(isSuppressedAppleDoubleName("_foo", ignoreAppledouble: true))
    }

    func testNotSuppressedForEmptyName() {
        XCTAssertFalse(isSuppressedAppleDoubleName("", ignoreAppledouble: true))
    }
}

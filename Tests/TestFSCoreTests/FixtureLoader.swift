//
//  FixtureLoader.swift
//
//  Shared helper for loading test fixtures from the SPM test bundle.
//

import Foundation

enum FixtureLoader {
    enum LoadError: Error, LocalizedError {
        case missing(name: String)

        var errorDescription: String? {
            switch self {
            case .missing(let name): return "missing fixture: \(name)"
            }
        }
    }

    /// Load a fixture by base name from `Tests/TestFSCoreTests/Fixtures/`.
    /// Throws `LoadError.missing` if the resource isn't present — XCTest
    /// surfaces that as a test failure with the fixture name in the message.
    static func data(_ name: String) throws -> Data {
        guard
            let url = Bundle.module.url(
                forResource: name,
                withExtension: "json",
                subdirectory: "Fixtures"
            )
        else {
            throw LoadError.missing(name: "\(name).json")
        }
        return try Data(contentsOf: url)
    }
}

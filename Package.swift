// swift-tools-version: 5.9
// SPM alongside the Xcode project for unit-test the pure-Swift logic.
// The Xcode TestFSExtension target still auto-compiles the same files
// via its synced group; this package just gives us a fast `swift test`
// loop without hand-editing project.pbxproj to add a test target.
//
// Only pure-Swift (no FSKit import) files belong in TestFSCore. FSKit
// glue code stays out and is only compiled by the Xcode target.

import PackageDescription

let package = Package(
    name: "testfs",
    platforms: [
        .macOS(.v13)  // Pure-Swift logic targets broad macOS; FSKit glue is 15.4+ elsewhere
    ],
    products: [
        .library(name: "TestFSCore", targets: ["TestFSCore"])
    ],
    targets: [
        .target(
            name: "TestFSCore",
            path: ".",
            exclude: [
                "LICENSE",
                "README.md",
                "appcast.xml",
                ".swiftlint.yml",
                "TestFS",
                "TestFS.xcodeproj",
                "Tests",
                "research",
                "scripts",
                "build",
                "TestFSExtension/Info.plist",
                "TestFSExtension/TestFSExtension.entitlements",
                "TestFSExtension/TestFSExtension.swift",
                "TestFSExtension/TestFileSystem.swift"
            ],
            sources: [
                "TestFSExtension/BlockCache.swift",
                "TestFSExtension/BundledExamples.swift",
                "TestFSExtension/JSONTree.swift",
                "TestFSExtension/LoadFailureMarker.swift",
                "TestFSExtension/MountOptions.swift",
                "TestFSExtension/Throttle.swift",
                "TestFSExtension/TreeBuilder.swift",
                "TestFSExtension/TreeIndex.swift"
            ]
        ),
        .testTarget(
            name: "TestFSCoreTests",
            dependencies: ["TestFSCore"],
            path: "Tests/TestFSCoreTests",
            resources: [
                .copy("Fixtures")
            ]
        )
    ]
)

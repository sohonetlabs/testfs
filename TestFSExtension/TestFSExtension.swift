//
//  TestFSExtension.swift
//  TestFSExtension
//

import Foundation
import FSKit

@main
struct TestFSExtension: UnaryFileSystemExtension {
    var fileSystem: FSUnaryFileSystem & FSUnaryFileSystemOperations {
        TestFileSystem()
    }
}

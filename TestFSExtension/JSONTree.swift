//
//  JSONTree.swift
//  TestFSCore / TestFSExtension
//
//  Decoder for `tree -J -s` JSON output. Pure Swift, no FSKit imports,
//  so it can be unit-tested via the SPM TestFSCore target while also
//  being compiled into the Xcode FSKit extension target via the
//  PBXFileSystemSynchronizedRootGroup.
//

import Foundation

/// A node in a filesystem tree parsed from `tree -J -s` JSON output.
indirect enum TreeNode: Sendable, Equatable {
    case directory(name: String, contents: [TreeNode])
    case file(name: String, size: UInt64)

    var name: String {
        switch self {
        case .directory(let name, _): return name
        case .file(let name, _): return name
        }
    }
}

/// Discriminator for the `"type"` field in `tree -J -s` output.
/// `report` entries are the trailing summary object the `tree` command
/// appends to every dump; the top-level loader filters them out before
/// they reach `TreeNode`.
private enum NodeType: String, Decodable {
    case directory
    case file
    case report
}

extension TreeNode: Decodable {
    private enum CodingKeys: String, CodingKey {
        case type, name, contents, size
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let typeString = try container.decode(String.self, forKey: .type)
        guard let type = NodeType(rawValue: typeString) else {
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container,
                debugDescription: "unknown node type '\(typeString)'"
            )
        }
        let name = try container.decode(String.self, forKey: .name)
        switch type {
        case .directory:
            // tree -J -s emits a "size" on directories; we don't use it.
            let contents = try container.decodeIfPresent([TreeNode].self, forKey: .contents) ?? []
            self = .directory(name: name, contents: contents)
        case .file:
            let size = try container.decodeIfPresent(UInt64.self, forKey: .size) ?? 0
            self = .file(name: name, size: size)
        case .report:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container,
                debugDescription: "unexpected report entry as TreeNode"
            )
        }
    }
}

/// Loader for `tree -J -s` output.
enum JSONTree {
    enum LoadError: Error, LocalizedError {
        case emptyArray
        case firstEntryNotDirectory(foundType: String)
        case unexpectedTrailingEntry(foundType: String)
        case malformed(underlying: Error)

        var errorDescription: String? {
            switch self {
            case .emptyArray:
                return "tree -J -s output must be a non-empty JSON array"
            case .firstEntryNotDirectory(let foundType):
                return "first array entry must be a directory, got '\(foundType)'"
            case .unexpectedTrailingEntry(let foundType):
                return "only 'report' entries may follow the leading directory, got '\(foundType)'"
            case .malformed(let err):
                // DecodingError's default description is a structured dump that
                // buries the useful bit (debugDescription in Context). Pull it
                // out explicitly so callers see e.g. "unknown node type 'symlink'"
                // instead of a multi-line Foundation error dump.
                if let decodingError = err as? DecodingError {
                    let context: DecodingError.Context?
                    switch decodingError {
                    case .dataCorrupted(let ctx),
                        .keyNotFound(_, let ctx),
                        .typeMismatch(_, let ctx),
                        .valueNotFound(_, let ctx):
                        context = ctx
                    @unknown default:
                        context = nil
                    }
                    if let context {
                        return "malformed tree -J -s JSON: \(context.debugDescription)"
                    }
                }
                return "malformed tree -J -s JSON: \(err.localizedDescription)"
            }
        }
    }

    /// Parse a `tree -J -s` top-level array and return the root directory node.
    /// Silently ignores trailing entries whose type is not `directory` — in
    /// practice a single `{"type":"report", ...}` summary object.
    static func load(from data: Data) throws -> TreeNode {
        do {
            return try JSONDecoder().decode(TopLevel.self, from: data).root
        } catch let err as LoadError {
            throw err
        } catch {
            throw LoadError.malformed(underlying: error)
        }
    }

    /// Header used to peek the first array element's `type` before
    /// committing to a full TreeNode decode. Lifted out of TopLevel
    /// to keep nesting depth at 1 (SwiftLint's `nesting` rule). The
    /// CodingKeys is synthesized.
    private struct TopLevelHeader: Decodable {
        let type: String
    }

    /// Internal wrapper that decodes only the first element of the top-level
    /// array, in a single pass. Remaining entries (report, extra directories)
    /// are left untouched by the decoder.
    private struct TopLevel: Decodable {
        let root: TreeNode

        init(from decoder: Decoder) throws {
            var arr = try decoder.unkeyedContainer()
            guard !arr.isAtEnd else {
                throw LoadError.emptyArray
            }
            // Peek element 0's type via a minimal header so we can surface
            // firstEntryNotDirectory as a distinct error instead of a
            // generic DecodingError, then decode the same element as a
            // full TreeNode.
            let first = try arr.superDecoder()
            let header = try TopLevelHeader(from: first)
            guard header.type == NodeType.directory.rawValue else {
                throw LoadError.firstEntryNotDirectory(foundType: header.type)
            }
            self.root = try TreeNode(from: first)
        }
    }
}

//
//  TestFSVolume+Ops.swift
//  TestFSExtension
//

import Foundation
import FSKit

// MARK: - error helpers

func posixError(_ code: POSIXErrorCode) -> Error {
    fs_errorForPOSIXError(code.rawValue)
}

// MARK: - pathconf

extension TestFSVolume: FSVolume.PathConfOperations {
    var maximumLinkCount: Int { -1 }  // unlimited; directories legitimately have >= 2
    var maximumNameLength: Int { 255 }
    var restrictsOwnershipChanges: Bool { true }
    var truncatesLongNames: Bool { false }
    var maximumXattrSize: Int { 0 }
    var maximumFileSize: UInt64 { UInt64.max }
}

// MARK: - core operations

/// Capability flags are invariant for the lifetime of the volume, so
/// compute them once and hand out the same instance.
private let sharedVolumeCapabilities: FSVolume.SupportedCapabilities = {
    let caps = FSVolume.SupportedCapabilities()
    caps.supportsHardLinks = false
    caps.supportsSymbolicLinks = false
    caps.supportsPersistentObjectIDs = true
    caps.doesNotSupportVolumeSizes = false
    caps.supportsHiddenFiles = true
    caps.supports64BitObjectIDs = true
    // Must match `FSfileObjectsAreCaseSensitive=true` in Info.plist and
    // the byte-keyed `[Data: TreeNodeID]` lookup in TreeIndex. macOS 26
    // routes name-cache decisions through this runtime capability — a
    // mismatch with the personality plist produces aliased lookups for
    // case-distinct siblings (e.g. `Foo.txt` / `foo.txt`).
    caps.caseFormat = .sensitive
    return caps
}()

extension TestFSVolume: FSVolume.Operations {

    var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        sharedVolumeCapabilities
    }

    var volumeStatistics: FSStatFSResult {
        let blockSize = 4096
        let totalBlocks = (totalFileBytes + UInt64(blockSize) - 1) / UInt64(blockSize)
        let result = FSStatFSResult(fileSystemTypeName: Identity.name)
        result.blockSize = blockSize
        result.ioSize = blockSize
        result.totalBlocks = totalBlocks
        result.availableBlocks = 0
        result.freeBlocks = 0
        result.totalFiles = max(totalFileCount, 1)
        result.freeFiles = 0
        return result
    }

    // MARK: - lifecycle

    func activate(options: FSTaskOptions) async throws -> FSItem {
        Log.mount.debug("activate")
        return rootItem
    }

    func deactivate(options: FSDeactivateOptions = []) async throws {
        Log.mount.debug("deactivate")
        stopStatsLogger()
    }

    func mount(options: FSTaskOptions) async throws {
        Log.mount.debug("mount")
    }

    func unmount() async {
        Log.mount.debug("unmount")
    }

    func synchronize(flags: FSSyncFlags) async throws {
        // Read-only, nothing to flush.
    }

    // MARK: - attribute IO

    func attributes(
        _ desiredAttributes: FSItem.GetAttributesRequest,
        of item: FSItem
    ) async throws -> FSItem.Attributes {
        try await throttle.gate()
        let attrs = try requireTestItem(item).cachedAttributes
        await throttle.recordOp()
        return attrs
    }

    func setAttributes(
        _ newAttributes: FSItem.SetAttributesRequest,
        on item: FSItem
    ) async throws -> FSItem.Attributes {
        throw posixError(.EROFS)
    }

    // MARK: - directory traversal

    func lookupItem(
        named name: FSFileName,
        inDirectory directory: FSItem
    ) async throws -> (FSItem, FSFileName) {
        try await throttle.gate()
        let dir = try requireTestItem(directory)
        let nameString = name.string ?? ""
        guard let child = index.lookup(name: nameString, in: dir.node.id),
            let item = itemsByID[child.id]
        else {
            let level: OSLogType =
                isSuppressedAppleDoubleName(nameString, ignoreAppledouble: options.ignoreAppledouble)
                ? .debug : .default
            Log.lookup.log(
                level: level,
                "miss in '\(dir.node.name, privacy: .public)': '\(nameString, privacy: .public)'"
            )
            throw posixError(.ENOENT)
        }
        if options.verbose {
            Log.lookup.debug(
                "hit in '\(dir.node.name, privacy: .public)': '\(nameString, privacy: .public)' -> id \(child.id)")
        }
        await throttle.recordOp()
        return (item, item.fsName)
    }

    func reclaimItem(_ item: FSItem) async throws {
        // Strong-referenced in itemsByID; items live until unmount.
    }

    func readSymbolicLink(_ item: FSItem) async throws -> FSFileName {
        throw posixError(.ENOENT)
    }

    func enumerateDirectory(
        _ directory: FSItem,
        startingAt cookie: FSDirectoryCookie,
        verifier: FSDirectoryVerifier,
        attributes: FSItem.GetAttributesRequest?,
        packer: FSDirectoryEntryPacker
    ) async throws -> FSDirectoryVerifier {
        try await throttle.gate()
        let dir = try requireTestItem(directory)
        if options.verbose {
            Log.lookup.debug(
                "enumerate '\(dir.node.name, privacy: .public)' from cookie \(cookie.rawValue)")
        }
        let childIDs = dir.node.childrenIDs
        let start = Int(cookie.rawValue)
        guard start < childIDs.count else {
            await throttle.recordOp()
            return FSDirectoryVerifier(0)
        }
        for idx in start..<childIDs.count {
            guard let child = itemsByID[childIDs[idx]] else { continue }
            let accepted = packer.packEntry(
                name: child.fsName,
                itemType: child.cachedAttributes.type,
                itemID: child.cachedAttributes.fileID,
                nextCookie: FSDirectoryCookie(UInt64(idx + 1)),
                attributes: attributes != nil ? child.cachedAttributes : nil
            )
            // packEntry returns false when the kernel's buffer is full;
            // the next enumerate call will resume from nextCookie.
            if !accepted { break }
        }
        await throttle.recordOp()
        // Immutable tree: verifier never changes.
        return FSDirectoryVerifier(0)
    }

    // MARK: - mutating ops (read-only filesystem)

    func createItem(
        named name: FSFileName,
        type: FSItem.ItemType,
        inDirectory directory: FSItem,
        attributes newAttributes: FSItem.SetAttributesRequest
    ) async throws -> (FSItem, FSFileName) {
        throw posixError(.EROFS)
    }

    func createSymbolicLink(
        named name: FSFileName,
        inDirectory directory: FSItem,
        attributes newAttributes: FSItem.SetAttributesRequest,
        linkContents contents: FSFileName
    ) async throws -> (FSItem, FSFileName) {
        throw posixError(.EROFS)
    }

    func createLink(
        to item: FSItem,
        named name: FSFileName,
        inDirectory directory: FSItem
    ) async throws -> FSFileName {
        throw posixError(.EROFS)
    }

    func removeItem(
        _ item: FSItem,
        named name: FSFileName,
        fromDirectory directory: FSItem
    ) async throws {
        throw posixError(.EROFS)
    }

    // FSKit's renameItem signature is fixed at six parameters; we
    // can't reduce the count without breaking conformance.
    // swiftlint:disable:next function_parameter_count
    func renameItem(
        _ item: FSItem,
        inDirectory sourceDirectory: FSItem,
        named sourceName: FSFileName,
        to destinationName: FSFileName,
        inDirectory destinationDirectory: FSItem,
        overItem: FSItem?
    ) async throws -> FSFileName {
        throw posixError(.EROFS)
    }
}

extension TestFSVolume: FSVolume.OpenCloseOperations {
    func openItem(_ item: FSItem, modes: FSVolume.OpenModes) async throws {}
    func closeItem(_ item: FSItem, modes: FSVolume.OpenModes) async throws {}
}

extension TestFSVolume: FSVolume.ReadWriteOperations {
    func read(
        from item: FSItem,
        at offset: off_t,
        length: Int,
        into buffer: FSMutableFileDataBuffer
    ) async throws -> Int {
        try await throttle.gate()
        let testItem = try requireTestItem(item)
        guard testItem.node.kind == .file else {
            throw posixError(.EISDIR)
        }
        guard offset >= 0 else {
            throw posixError(.EINVAL)
        }
        if options.verbose {
            Log.read.debug(
                "read '\(testItem.path, privacy: .public)' offset=\(offset) length=\(length)")
        }

        let requested = min(length, buffer.length)
        let bytesToWrite = BlockCache.effectiveReadLength(
            fileSize: testItem.node.size,
            offset: UInt64(offset),
            requestedLength: requested
        )
        guard bytesToWrite > 0 else {
            await throttle.recordOp()
            return 0
        }

        buffer.withUnsafeMutableBytes { raw in
            if let cache = blockCache {
                cache.read(
                    path: testItem.path,
                    offset: UInt64(offset),
                    length: bytesToWrite,
                    fileSize: testItem.node.size,
                    into: raw.baseAddress!
                )
            } else {
                memset(raw.baseAddress, Int32(fillByte), bytesToWrite)
            }
        }
        await throttle.recordOp(bytes: UInt64(bytesToWrite))
        return bytesToWrite
    }

    func write(
        contents: Data,
        to item: FSItem,
        at offset: off_t
    ) async throws -> Int {
        throw posixError(.EROFS)
    }
}

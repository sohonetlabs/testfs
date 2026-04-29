//
//  MountRegistry.swift
//  TestFS
//
//  App-side source of truth for live testfs mounts. Backed by
//  getfsstat(2), so a CLI mount via scripts/mount.sh shows up in
//  the Live Mounts list and a Finder-eject is reflected after the
//  next refresh.
//
//  The app remembers the source-JSON path and volume name for
//  mounts it initiated; on refresh, those metadata fields are
//  preserved for entries we still see in getfsstat, dropped for
//  entries that are gone, and left nil for entries we discover
//  fresh from the kernel (CLI mounts, app-restart-with-live-
//  mounts).
//

import Foundation
import OSLog

struct MountRecord: Identifiable, Hashable, Sendable {
    let id: UUID
    let bsdName: String
    let devNodePath: String
    let mountpoint: String
    /// nil for mounts the app didn't initiate (CLI / app-restart).
    var sourceJSON: String?
    var volumeName: String?
    let mountedAt: Date
}

actor MountRegistry {
    static let shared = MountRegistry()

    private let log = Logger(subsystem: TestFSConstants.logSubsystem, category: "mount-registry")
    private var byBSD: [String: MountRecord] = [:]

    /// Sorted snapshot for the UI, no kernel re-read.
    func snapshot() -> [MountRecord] {
        Array(byBSD.values).sorted(by: { $0.mountedAt < $1.mountedAt })
    }

    /// Ground-truth from the kernel. Preserves source/volume metadata
    /// only when both the BSD name AND the canonical mountpoint match
    /// — `diskN` values are recyclable, and `getfsstat` returns the
    /// canonical kernel path (`/private/tmp/...`) while `record()`
    /// receives the user-picked path (`/tmp/...`). Without canonical
    /// comparison every `/tmp`-based mount looks "new" on each
    /// refresh and loses its app-side metadata.
    func refreshed() -> [MountRecord] {
        let live = TestFSMountScanner.scan()
        var fresh: [String: MountRecord] = [:]
        let now = Date()
        for entry in live {
            // `existing.mountpoint` is already canonical (record() stores
            // the canonicalized form), so only the kernel-supplied side
            // needs a fresh `realpath`.
            if let existing = byBSD[entry.bsdName],
                existing.mountpoint == MountTable.canonicalize(entry.mountpoint) {
                fresh[entry.bsdName] = existing
            } else {
                fresh[entry.bsdName] = MountRecord(
                    id: UUID(),
                    bsdName: entry.bsdName,
                    devNodePath: entry.devNodePath,
                    mountpoint: entry.mountpoint,
                    sourceJSON: nil,
                    volumeName: nil,
                    mountedAt: now
                )
            }
        }
        byBSD = fresh
        log.debug("refresh: \(self.byBSD.count, privacy: .public) live testfs mounts")
        return snapshot()
    }

    /// App-initiated mount succeeded. Stash the metadata we have.
    /// Canonicalize the mountpoint so a later `refreshed()` comparison
    /// against the kernel's canonical path doesn't churn the row.
    func record(
        prep: MountManager.PrepareResult,
        mountpoint: String, sourceJSON: String, volumeName: String?
    ) {
        byBSD[prep.bsdName] = MountRecord(
            id: UUID(),
            bsdName: prep.bsdName,
            devNodePath: prep.devNodePath,
            mountpoint: MountTable.canonicalize(mountpoint),
            sourceJSON: sourceJSON,
            volumeName: volumeName,
            mountedAt: Date()
        )
    }

    /// App-initiated unmount succeeded. Drop the row.
    func forget(bsdName: String) {
        byBSD.removeValue(forKey: bsdName)
    }
}

// MARK: - getfsstat scanner

/// Wraps `getfsstat(2)`. One-shot syscall with no state, so it lives
/// as a static utility rather than an actor.
enum MountTable {
    struct Entry {
        let fsType: String
        let bsdName: String
        let devNodePath: String
        let mountpoint: String
    }

    /// Every kernel mount, no fstype filter.
    static func all() -> [Entry] {
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else { return [] }
        let cap = Int(count)
        let buf = UnsafeMutablePointer<statfs>.allocate(capacity: cap)
        defer { buf.deallocate() }
        let bufSize = Int32(MemoryLayout<statfs>.stride * cap)
        let actual = getfsstat(buf, bufSize, MNT_NOWAIT)
        guard actual > 0 else { return [] }
        return (0..<Int(actual)).map { idx in
            var entry = buf[idx]
            let fsType = readCString(&entry.f_fstypename, capacity: Int(MFSTYPENAMELEN))
            let devNodePath = readCString(&entry.f_mntfromname, capacity: Int(MAXPATHLEN))
            let mountpoint = readCString(&entry.f_mntonname, capacity: Int(MAXPATHLEN))
            return Entry(
                fsType: fsType,
                bsdName: .bsdName(fromDevNode: devNodePath),
                devNodePath: devNodePath,
                mountpoint: mountpoint)
        }
    }

    /// Whether `path` is currently the on-name of any mounted
    /// filesystem. Canonicalizes via `realpath` so /tmp/foo and
    /// /private/tmp/foo compare equal — macOS auto-resolves
    /// /tmp -> /private/tmp on mount.
    static func isMountpoint(_ path: String) -> Bool {
        let entries = all()
        if entries.contains(where: { $0.mountpoint == path }) { return true }
        let canonical = canonicalize(path)
        guard canonical != path else { return false }
        return entries.contains { canonicalize($0.mountpoint) == canonical }
    }

    private static func readCString<T>(_ tuple: UnsafePointer<T>, capacity: Int) -> String {
        UnsafeRawPointer(tuple).withMemoryRebound(to: CChar.self, capacity: capacity) {
            String(cString: $0)
        }
    }

    fileprivate static func canonicalize(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

/// Subset of `MountTable.all()` filtered to f_fstypename == TestFSConstants.fstype.
enum TestFSMountScanner {
    typealias Entry = MountTable.Entry

    static func scan() -> [Entry] {
        MountTable.all().filter { $0.fsType == TestFSConstants.fstype }
    }
}

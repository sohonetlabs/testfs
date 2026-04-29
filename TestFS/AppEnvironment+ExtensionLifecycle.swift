//
//  AppEnvironment+ExtensionLifecycle.swift
//  TestFS
//
//  Lower-level helpers for the first-launch extension cleanup that
//  `performReregisterIfNeeded` orchestrates: parsing `lsregister
//  -dump` for stale registrations the macOS 12+ NSWorkspace API
//  hides, and killing orphan extension processes left over after a
//  Sparkle update. Pulled into its own file so the ContentView
//  helpers stay within SwiftLint's file_length budget.
//

import Foundation
import OSLog

extension AppEnvironment {
    /// Parse `lsregister -dump` for every path registered against the
    /// given bundle identifier. The dump format pairs each registration
    /// with `path:` followed by `identifier:` on consecutive lines.
    /// Used in preference to `NSWorkspace.urlsForApplications` because
    /// the latter filters out registrations whose underlying file no
    /// longer exists (unmounted DMGs, deleted Trash items) — which
    /// are exactly the entries most likely to confuse extensionkitd's
    /// UUID resolution.
    static func registeredPaths(forBundleID bundleID: String) -> [String] {
        let result = ShellRunner.run(lsregisterPath, ["-dump"])
        guard result.exit == 0 else { return [] }
        var matches: [String] = []
        var pendingPath: String?
        for line in result.stdout.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("path:") {
                let trimmed = line.trimmingPrefix("path:")
                    .trimmingCharacters(in: .whitespaces)
                // Strip the trailing `(0xNNNN)` registration ID.
                if let parenIdx = trimmed.lastIndex(of: "(") {
                    pendingPath = trimmed[..<parenIdx].trimmingCharacters(in: .whitespaces)
                } else {
                    pendingPath = trimmed
                }
            } else if line.hasPrefix("identifier:") {
                let identifier = line.trimmingPrefix("identifier:")
                    .trimmingCharacters(in: .whitespaces)
                if identifier == bundleID, let path = pendingPath {
                    matches.append(path)
                }
                pendingPath = nil
            }
        }
        return matches
    }

    /// Kill any TestFSExtension process left over from a prior
    /// version. Sparkle's bundle replace doesn't tear down live
    /// ExtensionKit instances; the pluginkit toggle alone doesn't
    /// always reap them either. extensionkitd then refuses to spawn
    /// a fresh instance for the new bundle and the user gets
    /// `Cocoa 4099 / NSXPCConnectionInvalid`. Returns 1 if at least
    /// one process was signalled, 0 otherwise.
    static func killOrphanExtensionProcesses() -> Int {
        let log = Logger(subsystem: TestFSConstants.logSubsystem, category: "orphan-kill")
        let extensionBinary = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Extensions/TestFSExtension.appex")
            .appendingPathComponent("Contents/MacOS/TestFSExtension")
            .resolvingSymlinksInPath().path
        let result = ShellRunner.run("/usr/bin/pkill", ["-f", extensionBinary])
        if result.exit == 0 {
            log.info("killed orphan TestFSExtension process(es)")
            return 1
        }
        return 0
    }

    /// Kill `fskit_agent`, the per-user FSKit broker. It holds an
    /// in-memory cache of XPC connections to sibling helpers; when
    /// we kill an orphan appex, sibling helpers can be torn down by
    /// runningboard but the broker's cache still references their
    /// PIDs. Subsequent spawn attempts then fail with `Cocoa 4099 /
    /// "connection to service with pid <N> was invalidated"`.
    /// `fskit_agent` is a launchd user service
    /// (`com.apple.fskit.fskit_agent`); kicking it forces fresh XPC
    /// state on next demand. Returns 1 if a process was signalled.
    static func killFSKitAgent() -> Int {
        let log = Logger(subsystem: TestFSConstants.logSubsystem, category: "fskit-agent-kill")
        let result = ShellRunner.run("/usr/bin/pkill", ["-x", "fskit_agent"])
        if result.exit == 0 {
            log.info("killed fskit_agent to flush per-user XPC cache")
            return 1
        }
        return 0
    }
}

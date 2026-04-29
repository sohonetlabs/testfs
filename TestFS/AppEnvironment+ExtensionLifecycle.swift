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
        for rawLine in result.stdout.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix("path:") {
                let trimmed = line.dropFirst("path:".count).trimmingCharacters(in: CharacterSet.whitespaces)
                // Strip the trailing `(0xNNNN)` registration ID.
                if let parenIdx = trimmed.lastIndex(of: "(") {
                    pendingPath = trimmed[..<parenIdx].trimmingCharacters(in: CharacterSet.whitespaces)
                } else {
                    pendingPath = trimmed
                }
            } else if line.hasPrefix("identifier:") {
                let identifier = line.dropFirst("identifier:".count)
                    .trimmingCharacters(in: CharacterSet.whitespaces)
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
    /// `Cocoa 4099 / NSXPCConnectionInvalid`. SIGTERM to any process
    /// running the extension binary forces a clean replacement on
    /// the next mount. Returns 1 if pkill found and signalled at
    /// least one process, 0 otherwise.
    @discardableResult
    static func killOrphanExtensionProcesses() -> Int {
        let log = Logger(subsystem: TestFSConstants.logSubsystem, category: "orphan-kill")
        let extensionBinary = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Extensions/TestFSExtension.appex")
            .appendingPathComponent("Contents/MacOS/TestFSExtension")
            .resolvingSymlinksInPath().path
        // pkill -f matches the substring against the full command line
        // (including the appex's `-LaunchArguments <base64>` payload).
        // Exit 0 = at least one process signalled, 1 = no match.
        let result = ShellRunner.run("/usr/bin/pkill", ["-f", extensionBinary])
        if result.exit == 0 {
            log.info("killed orphan TestFSExtension process(es)")
            return 1
        }
        return 0
    }
}

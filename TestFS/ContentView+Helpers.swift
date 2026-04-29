//
//  ContentView+Helpers.swift
//  TestFS
//
//  Cached statics and small helpers for ContentView. Split out so
//  the main ContentView.swift stays inside SwiftLint's
//  type-body-length budget.
//

import AppKit
import OSLog
import SwiftUI

/// App-wide constants shared between ContentView and AboutView.
/// Bundle info and the running icon don't change for the process
/// lifetime, so they're cached once at type init instead of being
/// rebuilt per SwiftUI body recompute.
enum AppEnvironment {
    static let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    static let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    static let versionLabel = "v\(version) (build \(build))"

    static let icon: Image = Image(nsImage: NSApplication.shared.applicationIconImage)
        .resizable()

    /// Re-register and re-enable the FSKit extension. Four steps:
    ///
    ///   1. `lsregister -f <app>` — kicks LaunchServices to re-ingest
    ///      the bundle so its database has the post-update version.
    ///   2. `pluginkit -a <appex>` — kicks pluginkit's discovery so
    ///      the extension shows up under the FSKit extension point.
    ///   3. `pluginkit -e ignore -i <bundle-id>` — adjudication state
    ///      → "user-disabled" (the `-` flag).
    ///   4. `pluginkit -e use -i <bundle-id>` — adjudication state
    ///      → "user-enabled" (the `+` flag).
    ///
    /// Steps 3 + 4 are the toggle cycle — the same off-then-on flip
    /// that System Settings does. The state *transition* is what
    /// forces `extensionkitd` to drop its cached UUID for the appex
    /// and re-resolve against the current bundle.
    ///
    /// Don't gate the "did this work" stamp on shell-command success:
    /// pluginkit succeeding is not proof that `extensionkitd` resolves
    /// the new bundle. Only a successful mount is proof. The mount
    /// path stamps `verifiedMountedVersion` on success; while that
    /// stamp doesn't match `versionLabel`, this re-runs every launch.
    ///
    /// All four commands run as the user, no admin required.
    /// Returns `true` when every step exited 0 within its timeout.
    /// A `false` return triggers `ExtensionReregistration` to clear
    /// its memoized task so a later mount click can retry instead
    /// of awaiting a wedged result forever.
    /// Path to the private LaunchServices `lsregister` binary, used by
    /// both `performReregisterIfNeeded` and `sweepStaleRegistrations`.
    static let lsregisterPath =
        "/System/Library/Frameworks/CoreServices.framework"
        + "/Versions/A/Frameworks/LaunchServices.framework"
        + "/Versions/A/Support/lsregister"

    @discardableResult
    static func performReregisterIfNeeded() -> Bool {
        // Skip the whole cleanup path when we already verified a
        // mount on this version. The dump+parse + pkill + four-step
        // toggle is multi-MB read + several subprocesses; running it
        // every launch on a stable install is wasted work. The stamp
        // resets on every release, so post-upgrade always cleans up.
        let last = UserDefaults.standard.string(forKey: "verifiedMountedVersion") ?? ""
        guard versionLabel != last else { return true }

        // Sweep stale LaunchServices entries before any toggle work.
        // macOS 26's ExtensionKit hard-fails (Cocoa 4099) when the
        // bundle resolver latches onto a stale path that pluginkit
        // no longer reflects (#68).
        sweepStaleRegistrations()
        // Kill any orphan TestFSExtension process from before the
        // upgrade. Sparkle's bundle replace doesn't terminate live
        // ExtensionKit instances, leaving the old PID alive holding a
        // stale UUID (#70).
        killOrphanExtensionProcesses()
        // Kill fskit_agent's stale XPC cache. Killing an orphan appex
        // tears down sibling helpers via runningboard; fskit_agent
        // (the per-user broker) still references those torn-down
        // PIDs and every subsequent spawn fails with `connection to
        // service with pid <N> was invalidated`. launchd respawns it
        // on demand (#72).
        killFSKitAgent()

        let appBundle = Bundle.main.bundleURL
        let appex = appBundle.appendingPathComponent(
            "Contents/Extensions/TestFSExtension.appex")
        guard FileManager.default.fileExists(atPath: appex.path) else { return false }

        let bundleID = TestFSConstants.extensionBundleID
        let ok1 = runSilently(lsregisterPath, ["-f", appBundle.path])
        let ok2 = runSilently("/usr/bin/pluginkit", ["-a", appex.path])
        let ok3 = runSilently("/usr/bin/pluginkit", ["-e", "ignore", "-i", bundleID])
        let ok4 = runSilently("/usr/bin/pluginkit", ["-e", "use", "-i", bundleID])
        return ok1 && ok2 && ok3 && ok4
    }

    /// Sweep stale LaunchServices registrations for our host bundle
    /// ID, keeping only the running bundle's path. Enumerates via
    /// `lsregister -dump` parsing rather than `urlsForApplications`
    /// because the latter filters out registrations whose underlying
    /// file no longer exists (unmounted DMGs, deleted Trash items) —
    /// which are exactly the entries most likely to confuse
    /// extensionkitd's UUID resolution. `lsregister -u` on a host
    /// bundle cascades to the embedded appex, so the extension's
    /// bundle ID isn't enumerated separately.
    @discardableResult
    static func sweepStaleRegistrations() -> Int {
        let log = Logger(subsystem: TestFSConstants.logSubsystem, category: "lsregister-sweep")
        guard let bundleID = Bundle.main.bundleIdentifier else { return 0 }
        let canonical = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        let stalePaths = registeredPaths(forBundleID: bundleID)
            .filter { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path != canonical }
        guard !stalePaths.isEmpty else { return 0 }
        for path in stalePaths {
            log.info("sweeping stale registration: \(path, privacy: .public)")
        }
        // `lsregister -u` accepts N paths per invocation; batching
        // amortizes fork+exec across long stale lists.
        let batchOK = runSilently(lsregisterPath, ["-u"] + stalePaths)
        if batchOK {
            log.info("sweep removed \(stalePaths.count, privacy: .public) stale path(s)")
            return stalePaths.count
        }
        log.error("sweep failed for batch of \(stalePaths.count, privacy: .public) path(s)")
        return 0
    }

    /// 5s per command. Real `lsregister`/`pluginkit` runs finish in
    /// well under a second; a longer wait means the system process
    /// is wedged and we should fail loud rather than block the actor.
    private static let subprocessTimeout: TimeInterval = 5.0

    @discardableResult
    private static func runSilently(_ tool: String, _ args: [String]) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: tool)
        proc.arguments = args
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in done.signal() }
        do {
            try proc.run()
        } catch {
            return false
        }
        if done.wait(timeout: .now() + subprocessTimeout) == .timedOut {
            // A child that traps SIGTERM (or is stuck in uninterruptible
            // I/O) would survive a bare terminate(), letting a later
            // retry stack overlapping pluginkit / lsregister processes
            // against the same registration.
            ShellRunner.terminate(proc, exitSem: done)
            return false
        }
        return proc.terminationStatus == 0
    }
}

/// One-shot serialization of `performReregisterIfNeeded`. The first
/// caller spawns the work; later/parallel callers `await` the same
/// task value. Mount path uses this to ensure post-update toggling
/// has finished before invoking `mount(8)` — without it the
/// app-init kickoff and the user's first Mount click race, and
/// extensionkitd can resolve a stale UUID.
///
/// On failure (a subprocess timed out, or any step exited non-zero)
/// the cached task is cleared so the next mount click retries
/// instead of awaiting a wedged result forever.
actor ExtensionReregistration {
    static let shared = ExtensionReregistration()
    private var task: Task<Bool, Never>?

    func ensureCompleted() async {
        if task == nil {
            task = Task.detached(priority: .userInitiated) {
                AppEnvironment.performReregisterIfNeeded()
            }
        }
        let success = await task?.value ?? false
        if !success {
            task = nil
        }
    }
}

extension ContentView {
    static let validationEncoder = JSONEncoder()

    func recomputeOptionsValidation() {
        var probe = options
        probe.config = "."
        do {
            let data = try Self.validationEncoder.encode(probe)
            _ = try MountOptions.load(from: data)
            optionsValidationError = nil
        } catch {
            optionsValidationError = error.localizedDescription
        }
    }

    /// Translate a `MountConfirmResult` into UI status text. Returns
    /// `true` if the mount succeeded, `false` after writing status
    /// text describing the failure (caller should `return` early).
    func handleConfirmResult(_ result: MountManager.MountConfirmResult) -> Bool {
        switch result {
        case .mounted:
            return true
        case .failed(.some(let reason)):
            status = "Mount failed: \(reason)"
            return false
        case .failed(.none):
            status =
                "Mount failed: the kernel accepted the mount but the FSKit "
                + "extension didn't report a result within 15s. Open Show "
                + "log… for diagnostics."
            return false
        }
    }

    @ViewBuilder
    var extensionDisabledBanner: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("Enable the FSKit extension")
                    .font(.callout).bold()
                Text(
                    "Toggle TestFS on under General → Login Items & Extensions → "
                    + "File System Extensions, then mount. App updates can reset "
                    + "this toggle, so you may need to re-enable after each update.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open System Settings…") { openExtensionSettings() }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.blue.opacity(0.10))
        )
    }

    /// Translate a raw `mount(8)` failure into something an end-user
    /// can act on. We don't classify confidently because the same
    /// raw text (`Operation not permitted` / exit 69) can come from
    /// several places — TCC denial on the mountpoint, the FSKit
    /// extension not being adjudicated, fskitd state, etc — and
    /// substring matching gets it wrong as often as it gets it right.
    /// So: surface the raw `mount(8)` text verbatim, then list the
    /// common causes without claiming which one applies. The full
    /// stdout/stderr is also logged to OSLog from MountManager for
    /// the in-app log viewer.
    static func friendlyMountError(_ raw: String, mountpoint: String) -> String {
        // ExtensionKit error 2 = macOS couldn't invoke the extension.
        // Adjudication state goes stale after an app update even though
        // the System Settings toggle still reads "on"; toggling off+on
        // is the user-side fix.
        if raw.contains("extensionKit.errorDomain") {
            return """
                Mount failed: \(raw)

                macOS couldn't reach the FSKit extension. Toggle TestFS \
                off and back on under System Settings → General → Login \
                Items & Extensions → File System Extensions to force \
                re-adjudication, then try mounting again. App updates \
                often leave the extension in this stale state without \
                changing what the UI shows.
                """
        }
        if raw.range(of: "unknown file ?system", options: .regularExpression) != nil {
            return """
                Mount failed: the FSKit extension isn't enabled. Toggle \
                TestFS on under System Settings → General → Login Items \
                & Extensions → File System Extensions, then mount again. \
                App updates can reset this toggle.
                """
        }
        if raw.contains("Operation not permitted") || raw.contains("exit 69") {
            return """
                Mount failed: \(raw)

                Common causes:
                • The FSKit extension isn't enabled or is registered \
                in a stale state. Open System Settings → General → \
                Login Items & Extensions → File System Extensions and \
                make sure TestFS is on; toggling off and on again \
                forces re-adjudication. App updates can leave this \
                stale.
                • The mountpoint is in a privacy-protected directory \
                (Desktop, Documents, Downloads, iCloud Drive, \
                Pictures, Movies, Music). /tmp/<name> is the \
                known-safe choice.
                """
        }
        return "mount failed: \(raw)"
    }

    func pickJSON() async {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.title = "Choose tree JSON"
        if panel.runModal() == .OK { pickedJSON = panel.url }
    }

    func pickMountpoint() async {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Choose mountpoint (must be empty)"
        if panel.runModal() == .OK { pickedMountpoint = panel.url }
    }

    /// `NSOpenPanel` rooted at the bundled examples folder. Used by
    /// the **File ▸ Try an example…** menu item.
    func pickBundledExample() async {
        guard let examples = Bundle.main.url(
            forResource: "Examples", withExtension: nil
        ) else {
            return
        }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.directoryURL = examples
        panel.title = "Try an example"
        if panel.runModal() == .OK { pickedJSON = panel.url }
    }

    /// Open System Settings → Login Items & Extensions →
    /// File System Extensions so the user can flip the extension
    /// toggle on.
    func openExtensionSettings() {
        let url = URL(string:
            "x-apple.systempreferences:com.apple.LoginItems-Settings.extension?Extensions")!
        NSWorkspace.shared.open(url)
    }
}

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
    /// `UserDefaults` key the host stamps after a successful mount.
    /// Read by `performReregisterIfNeeded` to skip the toggle cycle
    /// when nothing's changed since the last good mount, and bound
    /// directly via `@AppStorage` from ContentView.
    static let verifiedMountedVersionKey = "verifiedMountedVersion"

    @discardableResult
    static func performReregisterIfNeeded() -> Bool {
        let last = UserDefaults.standard.string(forKey: verifiedMountedVersionKey) ?? ""
        guard versionLabel != last else { return true }

        let appBundle = Bundle.main.bundleURL
        let appex = appBundle.appendingPathComponent(
            "Contents/Extensions/TestFSExtension.appex")
        guard FileManager.default.fileExists(atPath: appex.path) else { return false }

        let lsregister = "/System/Library/Frameworks/CoreServices.framework"
            + "/Versions/A/Frameworks/LaunchServices.framework"
            + "/Versions/A/Support/lsregister"
        let bundleID = TestFSConstants.extensionBundleID
        let timeout = subprocessTimeout
        let ok1 = ShellRunner.run(lsregister, ["-f", appBundle.path], timeout: timeout).exit == 0
        let ok2 = ShellRunner.run("/usr/bin/pluginkit", ["-a", appex.path], timeout: timeout).exit == 0
        let ok3 = ShellRunner.run("/usr/bin/pluginkit",
            ["-e", "ignore", "-i", bundleID], timeout: timeout).exit == 0
        let ok4 = ShellRunner.run("/usr/bin/pluginkit",
            ["-e", "use", "-i", bundleID], timeout: timeout).exit == 0
        return ok1 && ok2 && ok3 && ok4
    }

    /// Path of fskitd's per-user enabled-modules plist. System Settings
    /// → General → Login Items & Extensions → File System Extensions
    /// writes the bundle ID of every enabled FSKit module into this
    /// plist's array on toggle; fskitd reads it at mount time to
    /// decide whether to spawn the extension. Apple DTS confirmed
    /// (DevForums 808594) that this is the persisted state and there
    /// is no public API to write it programmatically — the host can
    /// only detect the state and direct the user to the GUI toggle.
    static let enabledModulesPlistURL: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(
            "Library/Group Containers/group.com.apple.fskit.settings/enabledModules.plist")

    /// True iff fskitd's enabledModules.plist lists our extension's
    /// bundle ID. False when the file is missing, unparseable, or
    /// the bundle ID isn't in the array. This is the authoritative
    /// "will mount succeed" signal; the host's pre-flight uses it to
    /// short-circuit before invoking mount(8) when the user hasn't
    /// toggled the extension on yet.
    static func isFSKitExtensionEnabled() -> Bool {
        guard let data = try? Data(contentsOf: enabledModulesPlistURL),
            let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String]
        else { return false }
        return plist.contains(TestFSConstants.extensionBundleID)
    }

    /// 5s per `lsregister` / `pluginkit` invocation. Real runs finish
    /// in well under a second; a longer wait means the system process
    /// is wedged and we should fail loud rather than block the actor.
    private static let subprocessTimeout: TimeInterval = 5.0
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
                    "Toggle TestFS on under General → Login Items & Extensions "
                    + "→ File System Extensions. This banner disappears "
                    + "automatically the moment the toggle takes effect.")
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
    /// can act on. The "extension not enabled" class is filtered out
    /// upstream by the FSKitEnabledWatcher pre-flight, so the only
    /// guidance left for `Operation not permitted` is the TCC /
    /// privacy-protected-mountpoint case. Other errors surface the
    /// raw mount(8) text verbatim and let the in-app log viewer
    /// expose the full stdout/stderr captured by MountManager.
    static func friendlyMountError(_ raw: String, mountpoint: String) -> String {
        if raw.contains("Operation not permitted") || raw.contains("exit 69") {
            return """
                Mount failed: \(raw)

                The mountpoint may be in a privacy-protected directory \
                (Desktop, Documents, Downloads, iCloud Drive, Pictures, \
                Movies, Music). `/tmp/<name>` is the known-safe choice.
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

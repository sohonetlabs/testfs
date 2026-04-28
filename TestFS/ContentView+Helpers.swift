//
//  ContentView+Helpers.swift
//  TestFS
//
//  Cached statics and small helpers for ContentView. Split out so
//  the main ContentView.swift stays inside SwiftLint's
//  type-body-length budget.
//

import AppKit
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

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

extension ContentView {
    static let validationEncoder = JSONEncoder()

    /// Resizable wrapper around the running app's icon, cached so
    /// each `mountRow` render reuses one `Image` value.
    static let appIcon: Image = Image(nsImage: NSApplication.shared.applicationIconImage)
        .resizable()

    /// Bundle info is fixed for the app's lifetime, so compute the
    /// label once at type init instead of per body recompute.
    static let versionLabel: String = {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "v\(version) (build \(build))"
    }()

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
                Text("First time? Enable the FSKit extension")
                    .font(.callout).bold()
                Text("Toggle TestFS on under General → Login Items & Extensions → File System Extensions, then mount.")
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

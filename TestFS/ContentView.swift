//
//  ContentView.swift
//  TestFS
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(\.openWindow) private var openWindow
    // State fields are `internal` (no `private`) so that
    // ContentView+Options.swift's extension members can bind to
    // them. The struct itself is the only consumer; visibility
    // doesn't leak outside the module.
    @State var pickedJSON: URL?
    @State var pickedMountpoint: URL?
    @State var mounts: [MountRecord] = []
    @State var status: String = ""
    @State var busy = false
    @State var alreadyMountedPath: String?
    @State var options: MountOptions = .default
    @State var optionsExpanded = false

    /// The version+build label the user last successfully mounted
    /// with on this machine. Empty on first launch. The banner shows
    /// whenever this doesn't match the running build, which covers:
    /// fresh install (empty != current); Sparkle update that reset
    /// the System Settings extension toggle (old version != new); a
    /// manual install of an older build (also won't match). Once the
    /// user mounts successfully with the current version, the banner
    /// stays gone until the next update. We don't try to detect the
    /// toggle state directly because pluginkit's adjudication state
    /// isn't a reliable oracle (Apple's own msdos/exfat extensions
    /// show `-` and they work fine).
    @AppStorage("verifiedMountedVersion") var verifiedMountedVersion = ""

    /// Remembered values for the Rate limit / IOP limit toggles, so
    /// flipping the toggle off → on restores whatever the user last
    /// typed instead of jumping back to the default.
    @State var rememberedRateLimit: Double = 1.0
    @State var rememberedIopLimit: Int = 100

    /// Cached result of running `MountOptions.load(from:)` against
    /// a probe copy of `options` (with `config = "."` so the
    /// `missingConfig` check doesn't fire from the form panel — the
    /// host fills in the real path at mount time). Updated only
    /// when `options` changes, not on every body recompute, so the
    /// JSON round-trip happens once per edit instead of once per
    /// SwiftUI render.
    @State var optionsValidationError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("TestFS").font(.title)
                Spacer()
                Text(AppEnvironment.versionLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Divider()
            VSplitView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) { mountSection }
                        .padding(.trailing, 12)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(minHeight: 200)
                VStack(alignment: .leading, spacing: 8) { liveMountsSection }
                    .padding(.top, 4)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .frame(minHeight: 140)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding()
        .frame(
            minWidth: 720, maxWidth: .infinity,
            minHeight: 380, maxHeight: .infinity,
            alignment: .topLeading
        )
        .task { await refresh() }
        .onChange(of: options) { _, _ in recomputeOptionsValidation() }
        .onReceive(NotificationCenter.default.publisher(for: .testFSPickExample)) { _ in
            Task { await pickBundledExample() }
        }
        .alert(
            "Already mounted",
            isPresented: Binding(
                get: { alreadyMountedPath != nil },
                set: { if !$0 { alreadyMountedPath = nil } }
            ),
            presenting: alreadyMountedPath
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { path in
            Text("\(path) already has a filesystem mounted on it. Pick an empty directory.")
        }
    }

    @ViewBuilder
    private var mountSection: some View {
        if verifiedMountedVersion != AppEnvironment.versionLabel {
            extensionDisabledBanner
        }
        Text("Mount").font(.headline)
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 6) {
            GridRow {
                Text("Source JSON").foregroundStyle(.secondary)
                Text(pickedJSON?.path ?? "—")
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
                Button("Choose…") { Task { await pickJSON() } }
                    .disabled(busy)
            }
            GridRow {
                Text("Mount at").foregroundStyle(.secondary)
                Text(pickedMountpoint?.path ?? "—")
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
                Button("Choose…") { Task { await pickMountpoint() } }
                    .disabled(busy)
            }
        }
        DisclosureGroup("Advanced options", isExpanded: $optionsExpanded) {
            optionsForm
        }
        HStack {
            Button("Mount") { Task { await mountSelected() } }
                .disabled(
                    busy
                        || pickedJSON == nil
                        || pickedMountpoint == nil
                        || optionsValidationError != nil)
            if busy { ProgressView().controlSize(.small) }
            Spacer()
        }
        if !status.isEmpty {
            Text(status)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var liveMountsSection: some View {
        HStack {
            Text("Live mounts").font(.headline)
            Spacer()
            Button("Show log…") { openWindow(id: "log") }
            Button("Refresh") { Task { await refresh() } }
                .disabled(busy)
        }
        if mounts.isEmpty {
            Text("none").foregroundStyle(.secondary)
        } else {
            ForEach(mounts, id: \.id) { record in
                mountRow(record)
            }
        }
    }

    private func mountRow(_ record: MountRecord) -> some View {
        HStack {
            Button {
                NSWorkspace.shared.open(URL(fileURLWithPath: record.mountpoint))
            } label: {
                ZStack {
                    AppEnvironment.icon
                        .frame(width: 28, height: 28)
                    Image(systemName: IconBadge.symbolName)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .red)
                        .font(.system(size: 10, weight: .bold))
                }
                .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("Open in Finder")
            VStack(alignment: .leading) {
                Text(record.mountpoint)
                    .font(.system(.body, design: .monospaced))
                Text("\(record.devNodePath)" + (record.sourceJSON.map { " ← \($0)" } ?? ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Unmount") { Task { await unmount(record) } }
                .disabled(busy)
        }
    }

    // MARK: - Mount / unmount

    private func mountSelected() async {
        guard let json = pickedJSON, let mnt = pickedMountpoint else { return }
        busy = true; defer { busy = false }

        if MountTable.isMountpoint(mnt.path) {
            alreadyMountedPath = mnt.path
            return
        }

        status = "mounting \(json.lastPathComponent) at \(mnt.path)…"

        let accessing = json.startAccessingSecurityScopedResource()
        defer { if accessing { json.stopAccessingSecurityScopedResource() } }
        let jsonData: Data
        do {
            jsonData = try Data(contentsOf: json, options: .mappedIfSafe)
        } catch {
            status = "couldn't read JSON: \(error.localizedDescription)"
            return
        }

        var toMount = options
        if (toMount.volumeName ?? "").isEmpty {
            toMount.volumeName = json.deletingPathExtension().lastPathComponent
        }

        let prep: MountManager.PrepareResult
        do {
            prep = try await MountManager.shared.prepareMount(
                treeJSON: jsonData, options: toMount)
        } catch {
            status = "prepareMount failed: \(error.localizedDescription)"
            return
        }

        let mountAccess = mnt.startAccessingSecurityScopedResource()
        defer { if mountAccess { mnt.stopAccessingSecurityScopedResource() } }
        do {
            try await MountManager.shared.mount(devNode: prep.devNodePath, at: mnt.path)
        } catch {
            try? await MountManager.shared.detach(bsdName: prep.bsdName)
            status = Self.friendlyMountError(error.localizedDescription, mountpoint: mnt.path)
            return
        }

        // mount(8) only confirms the kernel queued the mount; FSKit's
        // loadResource runs asynchronously and can still fail. Verify
        // the volume actually came up before recording it, otherwise
        // the UI shows a phantom mount that doesn't serve file data.
        let confirmed = await MountManager.shared.confirmMountedOrRollback(
            prep: prep, mountpoint: mnt.path)
        guard confirmed else {
            status =
                "Mount failed: the kernel accepted the mount but the FSKit "
                + "extension didn't load the volume. Open Show log… for the "
                + "extension's error (JSON parse error, missing config, "
                + "or similar)."
            return
        }

        await recordSuccessfulMount(
            prep: prep, mountpoint: mnt.path,
            sourceJSON: json.path, volumeName: toMount.volumeName)
    }

    private func recordSuccessfulMount(
        prep: MountManager.PrepareResult,
        mountpoint: String,
        sourceJSON: String,
        volumeName: String?
    ) async {
        await MountRegistry.shared.record(
            prep: prep, mountpoint: mountpoint,
            sourceJSON: sourceJSON, volumeName: volumeName)
        mounts = await MountRegistry.shared.snapshot()
        // Stamp the running version as verified-working so the
        // "enable the extension" banner stays hidden until the next
        // app update potentially resets the System Settings toggle.
        verifiedMountedVersion = AppEnvironment.versionLabel
        status = "mounted \(prep.devNodePath) at \(mountpoint)"
    }

    private func unmount(_ record: MountRecord) async {
        busy = true; defer { busy = false }
        status = "unmounting \(record.mountpoint)…"
        do {
            try await MountManager.shared.unmount(at: record.mountpoint)
        } catch {
            status = "umount failed: \(error.localizedDescription)"
            return
        }
        do {
            try await MountManager.shared.detach(bsdName: record.bsdName)
        } catch {
            status = "unmounted, but detach failed: \(error.localizedDescription)"
            await MountRegistry.shared.forget(bsdName: record.bsdName)
            mounts = await MountRegistry.shared.snapshot()
            return
        }
        await MountRegistry.shared.forget(bsdName: record.bsdName)
        mounts = await MountRegistry.shared.snapshot()
        status = "unmounted \(record.mountpoint)"
    }

    private func refresh() async {
        mounts = await MountRegistry.shared.refreshed()
    }
}

#Preview {
    ContentView()
}

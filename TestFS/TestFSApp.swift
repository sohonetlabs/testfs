//
//  TestFSApp.swift
//  TestFS
//
//  Created by Khaos Tian on 6/13/24.
//

import AppKit
import OSLog
import Sparkle
import SwiftUI

/// SF Symbol used as the dock-icon overlay (TestFSApp) and the
/// per-mount-row badge (ContentView). Defined here so the symbol
/// name lives in one place across the AppKit composite and the
/// SwiftUI overlay.
enum IconBadge {
    static let symbolName = "ladybug.fill"
}

extension Notification.Name {
    /// Posted by the **File ▸ Try an example…** menu item.
    /// `ContentView` listens and opens an `NSOpenPanel` rooted at
    /// the bundled `Contents/Resources/Examples/` folder.
    static let testFSPickExample = Notification.Name("TestFSPickExample")
}

/// Sparkle delegate that unmounts every live testfs volume before
/// allowing the bundle replace. An active mount keeps the FSKit
/// appex pinned in the kernel — without this gate, Sparkle would
/// proceed and the bundle replace would fail silently, leaving the
/// user on a stale install. If unmount-all fails for any volume we
/// abort the install loudly via an alert, so the user can clean up
/// and retry instead of ending up half-updated. See #65.
final class TestFSUpdaterDelegate: NSObject, SPUUpdaterDelegate {
    private let log = Logger(subsystem: TestFSConstants.logSubsystem, category: "sparkle")

    /// Hard ceiling on the precheck. ShellRunner's per-call timeout
    /// already bounds individual umount/detach waits, but a long
    /// list of mounts (each requiring two ShellRunner calls) could
    /// otherwise stretch past a reasonable user-visible budget.
    /// Past this point we abort with the same loud-failure alert as
    /// any other cleanup failure.
    private static let precheckBudget: Duration = .seconds(60)

    /// Defer Sparkle's install until our async cleanup finishes. Any
    /// failure (umount error or budget timeout) aborts the install —
    /// we never call `immediateInstallationBlock`, Sparkle keeps the
    /// downloaded update queued, and the user gets an alert telling
    /// them to clean up and retry.
    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock: @escaping () -> Void
    ) -> Bool {
        Task { @MainActor in
            let succeeded = await Self.unmountAllForUpdate(
                log: log, budget: Self.precheckBudget)
            if succeeded {
                immediateInstallationBlock()
            } else {
                Self.showAbortAlert()
            }
        }
        return true
    }

    /// Iterate the live mount list and run `unmountAndForget` per
    /// record. `.detachFailed` is *not* a fatal precheck error: the
    /// kernel has already released the appex by then, so the install
    /// can proceed; the leftover dev node will be swept on next
    /// launch. Cancellation (from the budget watchdog) is checked
    /// between mounts so a wedged sweep can't outlive its budget by
    /// more than the currently-running ShellRunner call.
    private static func unmountAllForUpdate(log: Logger, budget: Duration) async -> Bool {
        let cleanup = Task { () -> Bool in
            let mounts = await MountRegistry.shared.refreshed()
            guard !mounts.isEmpty else {
                log.info("update precheck: no live testfs mounts")
                return true
            }
            log.info("update precheck: \(mounts.count, privacy: .public) live mount(s) to sweep")
            var allOK = true
            for record in mounts {
                guard !Task.isCancelled else { return false }
                switch await MountManager.shared.unmountAndForget(record) {
                case .ok:
                    continue
                case .umountFailed(let error):
                    let msg = error.localizedDescription
                    log.error("umount \(record.mountpoint, privacy: .public) failed: \(msg, privacy: .public)")
                    allOK = false
                case .detachFailed(let error):
                    let msg = error.localizedDescription
                    let bsd = record.bsdName
                    log.warning(
                        "detach \(bsd, privacy: .public) failed (umount ok): \(msg, privacy: .public)")
                }
            }
            return allOK
        }
        let watchdog = Task {
            try? await Task.sleep(for: budget)
            cleanup.cancel()
        }
        let result = await cleanup.value
        watchdog.cancel()
        return result
    }

    @MainActor
    private static func showAbortAlert() {
        let alert = NSAlert()
        alert.messageText = "TestFS update aborted"
        alert.informativeText =
            "One or more testfs volumes could not be cleanly "
            + "unmounted. The kernel still has the previous "
            + "extension pinned, so installing now would leave "
            + "TestFS half-updated. Unmount the affected volumes "
            + "manually, then choose Check for Updates… again."
        alert.alertStyle = .warning
        alert.runModal()
    }
}

@main
struct TestFSApp: App {
    /// Sparkle delegate that runs unmount-all before the update's
    /// quit-to-relaunch. Held by the App for the process lifetime so
    /// SPUStandardUpdaterController's weak reference stays valid.
    private let updaterDelegate = TestFSUpdaterDelegate()

    /// Sparkle's standard updater. Held by the App so it lives
    /// for the process lifetime; `startingUpdater: true` performs
    /// the auto-check on launch governed by `SUEnableAutomaticChecks`
    /// in Info.plist.
    private let updaterController: SPUStandardUpdaterController

    init() {
        self.updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: updaterDelegate,
            userDriverDelegate: nil)
        // Composite the ladybug onto the dock + About-box icon. In
        // Release it's solid black; in Debug it's solid red so a dev
        // build stands out from a shipped one at a glance.
        applyIconBadge()
        // Kick off post-update extension re-registration. Mount path
        // awaits the same actor task to avoid racing this kickoff.
        Task { await ExtensionReregistration.shared.ensureCompleted() }
    }

    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            // Replace the system About panel with our own SwiftUI
            // window so users can copy a clean diagnostics block
            // straight into a bug report.
            CommandGroup(replacing: .appInfo) {
                Button("About TestFS") {
                    openWindow(id: "about")
                }
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updaterController.checkForUpdates(nil)
                }
            }
            CommandGroup(after: .newItem) {
                Button("Try an example…") {
                    NotificationCenter.default.post(
                        name: .testFSPickExample, object: nil)
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            }
        }
        WindowGroup("TestFS Log", id: "log") {
            LogView()
        }
        .defaultSize(width: 760, height: 480)
        Window("About TestFS", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
    }
}

private func applyIconBadge() {
    let app = NSApplication.shared
    guard let base = app.applicationIconImage else { return }
    let size = base.size
    let composite = NSImage(size: size)
    composite.lockFocus()
    base.draw(in: NSRect(origin: .zero, size: size))
    // Centered ladybug, no badge background. Sized to ~35% of the
    // icon edge so the silhouette reads but the underlying icon
    // stays mostly visible.
    let bugEdge = size.width * 0.35
    var symbolConfig = NSImage.SymbolConfiguration(
        pointSize: bugEdge, weight: .bold)
    #if DEBUG
        // Debug build: solid red ladybug — clearly different from
        // Release so a dev build stands out from a shipped one.
        symbolConfig = symbolConfig.applying(.init(paletteColors: [.systemRed]))
        let accessibility = "Debug build"
    #else
        // Release: solid black ladybug as the brand mark.
        symbolConfig = symbolConfig.applying(.init(paletteColors: [.black]))
        let accessibility = "TestFS"
    #endif
    if let bug = NSImage(
        systemSymbolName: IconBadge.symbolName,
        accessibilityDescription: accessibility
    )?.withSymbolConfiguration(symbolConfig) {
        let bugSize = bug.size
        let bugRect = NSRect(
            x: (size.width - bugSize.width) / 2,
            y: (size.height - bugSize.height) / 2,
            width: bugSize.width,
            height: bugSize.height)
        bug.draw(
            in: bugRect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high.rawValue])
    }
    composite.unlockFocus()
    app.applicationIconImage = composite
}

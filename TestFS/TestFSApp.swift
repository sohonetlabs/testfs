//
//  TestFSApp.swift
//  TestFS
//
//  Created by Khaos Tian on 6/13/24.
//

import AppKit
import Sparkle
import SwiftUI

/// SF Symbol used as the Debug-build / mount-row badge. Defined
/// here so the symbol name lives in one place across the AppKit
/// composite (TestFSApp) and the SwiftUI overlay (ContentView).
enum DebugBadge {
    static let symbolName = "ladybug.fill"
}

extension Notification.Name {
    /// Posted by the **File ▸ Try an example…** menu item.
    /// `ContentView` listens and opens an `NSOpenPanel` rooted at
    /// the bundled `Contents/Resources/Examples/` folder.
    static let testFSPickExample = Notification.Name("TestFSPickExample")
}

@main
struct TestFSApp: App {
    /// Sparkle's standard updater. Held by the App so it lives
    /// for the process lifetime; `startingUpdater: true` performs
    /// the auto-check on launch governed by `SUEnableAutomaticChecks`
    /// in Info.plist.
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    init() {
        #if DEBUG
            // Debug builds: composite a bug badge onto the running app's
            // dock + About-box icon so the visual cue distinguishes a
            // dev build from a Release build at a glance.
            applyDebugBadge()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
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
    }
}

#if DEBUG
    private func applyDebugBadge() {
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
        let symbolConfig = NSImage.SymbolConfiguration(
            pointSize: bugEdge, weight: .bold)
        if let bug = NSImage(
            systemSymbolName: DebugBadge.symbolName,
            accessibilityDescription: "Debug build"
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
#endif

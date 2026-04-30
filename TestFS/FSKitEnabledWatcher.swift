//
//  FSKitEnabledWatcher.swift
//  TestFS
//
//  Watches fskitd's per-user enabled-modules plist
//  (`~/Library/Group Containers/group.com.apple.fskit.settings/
//  enabledModules.plist`) and republishes whether our extension is
//  currently in the enabled list.
//
//  The plist is the authoritative source fskitd reads at mount time
//  (see DevForums 808594). System Settings → File System Extensions
//  writes the file via atomic-replace (write-temp + rename), so a
//  single-fd `DispatchSourceFileSystemObject` would lose the watch
//  on first toggle. FSEventStream watches the parent directory and
//  survives renames cleanly.
//

import Combine
import CoreServices
import Foundation

/// Observable wrapper over the live "is the FSKit extension enabled"
/// state. Bind to `isEnabled` from SwiftUI; updates fire as soon as
/// the user flips the System Settings toggle.
@MainActor
final class FSKitEnabledWatcher: ObservableObject {
    @Published private(set) var isEnabled: Bool

    private let plistDir: URL
    private var stream: FSEventStreamRef?

    init() {
        plistDir = AppEnvironment.enabledModulesPlistURL.deletingLastPathComponent()
        isEnabled = AppEnvironment.isFSKitExtensionEnabled()
        start()
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    private func start() {
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil)
        let paths = [plistDir.path] as CFArray
        let callback: FSEventStreamCallback = { _, ctx, _, _, _, _ in
            guard let ctx else { return }
            let watcher = Unmanaged<FSKitEnabledWatcher>.fromOpaque(ctx)
                .takeUnretainedValue()
            Task { @MainActor in watcher.refresh() }
        }
        guard let newStream = FSEventStreamCreate(
            nil, callback, &context, paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)
        ) else { return }
        FSEventStreamSetDispatchQueue(newStream, .main)
        FSEventStreamStart(newStream)
        stream = newStream
    }

    private func refresh() {
        let new = AppEnvironment.isFSKitExtensionEnabled()
        if new != isEnabled { isEnabled = new }
    }
}

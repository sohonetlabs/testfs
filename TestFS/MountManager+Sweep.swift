//
//  MountManager+Sweep.swift
//  TestFS
//
//  Shared umount → detach → forget helper used by both the user's
//  per-row unmount click (`ContentView.unmount`) and the Sparkle
//  pre-install hook (`TestFSUpdaterDelegate.unmountAllForUpdate`).
//  Living in its own file keeps `MountManager.swift` under the
//  file-length budget.
//

import Foundation

extension MountManager {
    /// Outcome of a single `unmountAndForget` call. `.detachFailed`
    /// means the volume is no longer mounted (so the kernel no longer
    /// pins the FSKit appex), but the backing dev node is still
    /// attached — caller should treat it as a soft failure.
    enum UnmountOutcome {
        // swiftlint:disable:next identifier_name
        case ok
        case umountFailed(Error)
        case detachFailed(Error)
    }

    /// Run umount → detach → forget for a single mount record. Always
    /// invokes `MountRegistry.forget` once umount succeeds, even if
    /// detach later fails: the kernel no longer holds the volume, so
    /// the registry must stop claiming it does.
    func unmountAndForget(_ record: MountRecord) async -> UnmountOutcome {
        do {
            try unmount(at: record.mountpoint)
        } catch {
            return .umountFailed(error)
        }
        var detachError: Error?
        do {
            try detach(bsdName: record.bsdName)
        } catch {
            detachError = error
        }
        await MountRegistry.shared.forget(bsdName: record.bsdName)
        if let detachError {
            return .detachFailed(detachError)
        }
        return .ok
    }
}

//
//  Throttle.swift
//  TestFSCore / TestFSExtension
//

import Foundation

/// Enforces two independent rate constraints on filesystem operations:
/// a minimum gap between consecutive ops (`rateLimit`) and a maximum
/// number of ops in any rolling one-second window (`iopLimit`). Each
/// `gate()` call sleeps until both constraints are satisfied. Concurrent
/// callers serialize through the actor so the constraints are honoured
/// globally, not per-task.
actor Throttle {
    nonisolated let rateLimit: Duration
    nonisolated let iopLimit: Int
    private var lastOpAt: ContinuousClock.Instant?
    /// Deadlines of the last `iopLimit` reservations, monotonically
    /// non-decreasing. Front is oldest; entries older than one second
    /// are dropped at the start of each `reserveDeadline`.
    private var recentOps: [ContinuousClock.Instant] = []
    private var totalOps: UInt64 = 0
    private var totalBytes: UInt64 = 0

    init(rateLimit: Duration, iopLimit: Int) {
        self.rateLimit = rateLimit
        self.iopLimit = iopLimit
        if iopLimit > 0 {
            self.recentOps.reserveCapacity(iopLimit + 1)
        }
    }

    nonisolated func gate() async throws {
        guard rateLimit > .zero || iopLimit > 0 else { return }
        let deadline = await reserveDeadline()
        if deadline > .now {
            try await Task.sleep(until: deadline, clock: .continuous)
        }
    }

    /// Record one completed op for the running stats counters. `bytes` is
    /// 0 for non-read ops (lookup, stat, enumerate); read ops pass the
    /// number of bytes actually delivered.
    func recordOp(bytes: UInt64 = 0) {
        totalOps += 1
        totalBytes += bytes
    }

    /// Cumulative ops and bytes since this Throttle was created.
    func snapshot() -> (ops: UInt64, bytes: UInt64) {
        (totalOps, totalBytes)
    }

    /// Advance `lastOpAt` / `recentOps` to reflect this op's deadline and
    /// return it. Must be called before any sleep so concurrent callers
    /// queue up behind us instead of all racing on the same snapshot.
    private func reserveDeadline() -> ContinuousClock.Instant {
        let now = ContinuousClock.now
        var rateDeadline = now
        var iopDeadline = now

        if rateLimit > .zero, let last = lastOpAt {
            rateDeadline = max(now, last + rateLimit)
        }

        if iopLimit > 0 {
            let windowStart = now - .seconds(1)
            let keepFrom = recentOps.firstIndex(where: { $0 > windowStart }) ?? recentOps.count
            recentOps.removeFirst(keepFrom)
            if let oldest = recentOps.first, recentOps.count >= iopLimit {
                iopDeadline = oldest + .seconds(1)
            }
        }

        let deadline = max(rateDeadline, iopDeadline)
        lastOpAt = deadline
        if iopLimit > 0 {
            recentOps.append(deadline)
        }
        return deadline
    }
}

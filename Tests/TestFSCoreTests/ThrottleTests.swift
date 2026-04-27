//
//  ThrottleTests.swift
//

import XCTest

@testable import TestFSCore

final class ThrottleTests: XCTestCase {

    func testZeroDisablesGate() async throws {
        let throttle = Throttle(rateLimit: .zero, iopLimit: 0)
        let start = ContinuousClock.now
        for _ in 0..<10 {
            try await throttle.gate()
        }
        let elapsed = ContinuousClock.now - start
        // Generous upper bound — point is "didn't sleep on purpose", not "was instant on a loaded CI".
        XCTAssertLessThan(elapsed, .milliseconds(200))
    }

    func testRateLimitEnforcesMinimumGap() async throws {
        let throttle = Throttle(rateLimit: .milliseconds(50), iopLimit: 0)
        let start = ContinuousClock.now
        for _ in 0..<20 {
            try await throttle.gate()
        }
        let elapsed = ContinuousClock.now - start
        // 19 gaps × 50ms = 950ms minimum; first call is free.
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(950))
    }

    func testConcurrentCallsSerialize() async throws {
        let throttle = Throttle(rateLimit: .milliseconds(50), iopLimit: 0)
        let start = ContinuousClock.now
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask { try await throttle.gate() }
            }
            try await group.waitForAll()
        }
        let elapsed = ContinuousClock.now - start
        // 4 enforced gaps × 50ms = 200ms minimum even though all 5 fired at once.
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(200))
    }

    // MARK: - stats accumulator

    func testStatsAccumulator() async {
        let throttle = Throttle(rateLimit: .zero, iopLimit: 0)
        await throttle.recordOp(bytes: 1024)
        await throttle.recordOp(bytes: 2048)
        await throttle.recordOp()  // no bytes (e.g. lookup)
        let snap = await throttle.snapshot()
        XCTAssertEqual(snap.ops, 3)
        XCTAssertEqual(snap.bytes, 3072)
    }

    func testStatsStartAtZero() async {
        let throttle = Throttle(rateLimit: .zero, iopLimit: 0)
        let snap = await throttle.snapshot()
        XCTAssertEqual(snap.ops, 0)
        XCTAssertEqual(snap.bytes, 0)
    }

    func testCancellationPropagates() async {
        let throttle = Throttle(rateLimit: .seconds(5), iopLimit: 0)
        let task = Task {
            try await throttle.gate()  // first call returns immediately (no prior op)
            try await throttle.gate()  // blocks ~5s until cancel lands
        }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        do {
            try await task.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
    }

    // MARK: - iops limit

    func testIopsLimitEnforcesRollingWindow() async throws {
        let throttle = Throttle(rateLimit: .zero, iopLimit: 100)
        let start = ContinuousClock.now
        for _ in 0..<200 {
            try await throttle.gate()
        }
        let elapsed = ContinuousClock.now - start
        // First 100 fire instantly. Op 101 waits until op 1's timestamp
        // is 1s old; ops 102-200 trickle at ~10ms each as each previous
        // op ages out. Minimum total elapsed ≈ 1s.
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(950))
    }

    func testZeroIopLimitDisabled() async throws {
        let throttle = Throttle(rateLimit: .zero, iopLimit: 0)
        let start = ContinuousClock.now
        for _ in 0..<500 {
            try await throttle.gate()
        }
        let elapsed = ContinuousClock.now - start
        XCTAssertLessThan(elapsed, .milliseconds(200))
    }

    func testRateAndIopLimitCompose() async throws {
        // rate=1ms (1000/s ceiling) + iop=10 (10/s ceiling). IOP dominates.
        let throttle = Throttle(rateLimit: .milliseconds(1), iopLimit: 10)
        let start = ContinuousClock.now
        for _ in 0..<20 {
            try await throttle.gate()
        }
        let elapsed = ContinuousClock.now - start
        // 10 ops instant, then 10 more over ~1s (oldest ages out at 100ms intervals
        // in a steady state of 10 ops in the window).
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(900))
    }
}

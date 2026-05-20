import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavioral coverage of CasperBoundedAsyncWorkPool. Verifies the
/// concurrency cap, queue drain, and that `_debugSnapshot` reflects the
/// internal state so the perf-sensitive call-sites can trust the contract.
@MainActor
final class CasperBoundedAsyncWorkPoolTests: XCTestCase {

    /// Tracks peak concurrency seen by work items. Mutated from a serial
    /// actor so observations remain race-free without external locking.
    private actor PeakTracker {
        private(set) var current = 0
        private(set) var peak = 0

        func enter() {
            current += 1
            if current > peak { peak = current }
        }

        func leave() {
            current -= 1
        }
    }

    /// With 10 items and a cap of 3, the pool must never let more than 3
    /// items execute their body concurrently. All 10 must still complete.
    func testConcurrencyCapIsEnforced() async {
        let pool = CasperBoundedAsyncWorkPool(maxConcurrent: 3)
        let tracker = PeakTracker()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    await pool.run {
                        await tracker.enter()
                        // ~20ms so the test is robust to scheduler jitter
                        // while still finishing in well under a second.
                        try? await Task.sleep(nanoseconds: 20_000_000)
                        await tracker.leave()
                    }
                }
            }
        }

        let peak = await tracker.peak
        XCTAssertLessThanOrEqual(peak, 3, "Concurrency cap violated, peak=\(peak)")
        XCTAssertGreaterThan(peak, 1, "Pool should have actually parallelized work")

        let (active, waiting) = await pool._debugSnapshot()
        XCTAssertEqual(active, 0, "Active count should drain to 0")
        XCTAssertEqual(waiting, 0, "Waiter queue should drain to 0")
    }

    /// Throwing variant releases its slot on error so downstream waiters
    /// proceed. Without this, a single throwing call leaks a slot and
    /// progressively starves the pool — observable as a hang.
    func testThrowingVariantReleasesSlotOnError() async {
        let pool = CasperBoundedAsyncWorkPool(maxConcurrent: 1)
        struct Boom: Error {}

        for _ in 0..<5 {
            do {
                _ = try await pool.runThrowing { () throws -> Int in throw Boom() }
                XCTFail("Expected Boom to propagate")
            } catch is Boom {
                // expected
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }

        let (active, waiting) = await pool._debugSnapshot()
        XCTAssertEqual(active, 0)
        XCTAssertEqual(waiting, 0)
    }

    /// Wall-clock performance: 30 items @ ~50ms each with cap=4 should
    /// finish in roughly `ceil(30/4) * 50ms = 400ms`, allowing slack for
    /// scheduler overhead and CI noise. Without the cap (unbounded), all
    /// 30 race in parallel and finish in ~50ms — the cap should add ~7x
    /// serialization. The test asserts both a lower and upper bound so a
    /// regression in either direction fails loudly.
    func testWallClockUnderBoundedConcurrency() async {
        let pool = CasperBoundedAsyncWorkPool(maxConcurrent: 4)
        let start = Date()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<30 {
                group.addTask {
                    await pool.run {
                        try? await Task.sleep(nanoseconds: 50_000_000)
                    }
                }
            }
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertGreaterThan(elapsed, 0.30, "Work seemed unbounded (elapsed=\(elapsed))")
        XCTAssertLessThan(elapsed, 1.50, "Work took too long, scheduler issue or deadlock (elapsed=\(elapsed))")
    }

    /// FIFO ordering: with cap=1, items must complete in submission order.
    /// Higher caps don't make this guarantee meaningfully (system scheduler
    /// can reorder near-simultaneous tasks), so test with cap=1.
    func testFIFOWithCapOfOne() async {
        let pool = CasperBoundedAsyncWorkPool(maxConcurrent: 1)
        actor Recorder {
            private(set) var order: [Int] = []
            func record(_ i: Int) { order.append(i) }
        }
        let recorder = Recorder()

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<8 {
                // Stagger submissions slightly so they enter the pool in
                // a known order; without this, TaskGroup spawn order is
                // not guaranteed FIFO into the actor.
                try? await Task.sleep(nanoseconds: 1_000_000)
                group.addTask {
                    await pool.run {
                        await recorder.record(i)
                        try? await Task.sleep(nanoseconds: 5_000_000)
                    }
                }
            }
        }
        let order = await recorder.order
        XCTAssertEqual(order, Array(0..<8), "FIFO violated under cap=1: \(order)")
    }

    /// Cancellation while suspended in the waiter queue must drain the
    /// waiter entry and NOT leave a "ghost slot" reserved for the cancelled
    /// task. Repro for the bug fixed by routing `acquire` through
    /// `withTaskCancellationHandler`: a bare `withCheckedContinuation` left
    /// the continuation in `waiters` even after the owning Task moved on,
    /// so the next `release()` handed the slot to a dead task — wasting
    /// pool capacity ahead of live work.
    func testCancellationWhileWaitingFreesSlotAndDrainsWaiter() async {
        let pool = CasperBoundedAsyncWorkPool(maxConcurrent: 1)

        let blockerStarted = expectation(description: "blocker started")
        let blockerCanFinish = expectation(description: "blocker can finish")
        let blockerTask = Task {
            await pool.run {
                blockerStarted.fulfill()
                await self.waitForFulfillment(of: blockerCanFinish)
            }
        }
        await fulfillment(of: [blockerStarted], timeout: 2.0)

        // Inverted: if `release` hands the slot to a cancelled waiter,
        // this body runs and the test fails.
        let waiterRan = expectation(description: "waiter ran (should NOT fire)")
        waiterRan.isInverted = true
        let waiterTask = Task {
            await pool.run { waiterRan.fulfill() }
        }

        // Wait long enough for `acquire()` to actually park in `waiters`
        // before we cancel.
        try? await Task.sleep(nanoseconds: 50_000_000)
        let waitingBeforeCancel = await pool._debugSnapshot().waiting
        XCTAssertEqual(waitingBeforeCancel, 1, "Waiter should be parked in queue before cancel")

        waiterTask.cancel()

        // The cancel handler dispatches a Task onto the actor; poll
        // instead of a single sleep so this isn't flaky under contention.
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 10_000_000)
            if await pool._debugSnapshot().waiting == 0 { break }
        }
        XCTAssertEqual(await pool._debugSnapshot().waiting, 0, "Cancelled waiter must drain from queue")

        blockerCanFinish.fulfill()
        _ = await blockerTask.value
        _ = await waiterTask.value

        let freshRan = expectation(description: "fresh task ran")
        await pool.run { freshRan.fulfill() }
        await fulfillment(of: [freshRan, waiterRan], timeout: 1.0)

        let (active, waiting) = await pool._debugSnapshot()
        XCTAssertEqual(active, 0)
        XCTAssertEqual(waiting, 0)
    }

    /// `XCTestCase.fulfillment(of:)` is `@MainActor`-bound; bridge it so
    /// it can be awaited from inside a `@Sendable` pool closure.
    private func waitForFulfillment(of expectation: XCTestExpectation) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            Task.detached {
                await self.fulfillment(of: [expectation], timeout: 10.0)
                cont.resume()
            }
        }
    }
}

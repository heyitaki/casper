// CASPER: Reusable bounded-concurrency primitive for fanned-out async work
// (e.g. git metadata probes across 30 workspaces, JSONL activity scans).
// Without this, every poll tick spawns N `Task.detached` calls that race
// concurrently and saturate cores + queue N MainActor follow-ups. Delete if
// upstream introduces a project-wide async work-pool primitive.

import Foundation

/// Caps the number of concurrent async work items run through `run(_:)`.
///
/// Work items are admitted in FIFO order. When the active count is below the
/// limit, the next caller proceeds immediately; otherwise it suspends on a
/// continuation that resumes when a slot frees up.
///
/// This is intentionally simpler than a full `OperationQueue`: no cancellation
/// API (cancel via the calling `Task` if needed), no per-item QoS overrides,
/// no priority lanes. It is meant to be the bottleneck around a single class
/// of background scan, not a general-purpose scheduler.
actor CasperBoundedAsyncWorkPool {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let maxConcurrent: Int
    private var activeCount = 0
    private var waiters: [Waiter] = []

    init(maxConcurrent: Int) {
        precondition(maxConcurrent > 0, "maxConcurrent must be > 0")
        self.maxConcurrent = maxConcurrent
    }

    /// Runs `work` once a slot is available. Returns whatever `work` returns.
    /// `work` still runs even if the calling Task was cancelled — observe
    /// `Task.isCancelled` inside `work` to bail out fast. The slot is always
    /// released (only if one was actually acquired — see `acquire`).
    func run<T: Sendable>(_ work: @Sendable () async -> T) async -> T {
        let acquired = await acquire()
        defer { if acquired { release() } }
        return await work()
    }

    /// Throwing variant. Same admission rules.
    func runThrowing<T: Sendable>(_ work: @Sendable () async throws -> T) async rethrows -> T {
        let acquired = await acquire()
        defer { if acquired { release() } }
        return try await work()
    }

    /// Test-only snapshot of the pool's internal counters. Returns
    /// `(activeCount, waiterCount)`.
    func _debugSnapshot() -> (active: Int, waiting: Int) {
        (activeCount, waiters.count)
    }

    /// Returns `true` when a slot was acquired and the caller must release it.
    /// Returns `false` ONLY when the caller's Task was cancelled while
    /// suspended in the waiter queue — no slot was reserved and `release`
    /// must NOT be called, otherwise `activeCount` underflows the next time
    /// a real slot is freed.
    private func acquire() async -> Bool {
        if activeCount < maxConcurrent {
            activeCount += 1
            return true
        }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                waiters.append(Waiter(id: id, continuation: cont))
            }
        } onCancel: {
            // Cancellation handlers run synchronously off-actor; dispatch
            // back onto the actor to mutate `waiters`. If the waiter was
            // already dequeued by `release` between the cancel firing and
            // this Task running, `cancelWaiter` finds nothing and exits —
            // the original continuation has already resumed with `true` and
            // the caller correctly releases its slot.
            Task { await self.cancelWaiter(id: id) }
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let idx = waiters.firstIndex(where: { $0.id == id }) else { return }
        let entry = waiters.remove(at: idx)
        entry.continuation.resume(returning: false)
    }

    private func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            // Hand the existing slot off to the next waiter; activeCount
            // stays the same so the `activeCount <= max` invariant holds.
            next.continuation.resume(returning: true)
        } else {
            activeCount -= 1
        }
    }
}

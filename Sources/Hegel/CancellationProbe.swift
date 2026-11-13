import Synchronization

/// A test double for code that has to cancel the work it starts: an
/// operation that runs until its task is cancelled, and counts how many
/// started and how many are still waiting for their cancel.
///
/// Hand `hang()` to the code under test as the work it runs (a request
/// that never answers, a transform that never finishes), cancel that code,
/// and check that nothing it started was left running:
///
/// ```swift
/// try await property { tc in
///     let probe = CancellationProbe()
///     let run = try await tc.withRandomCancellation(endsWithin: .seconds(5)) { cancellation in
///         try await pool.map(jobs) { _ in
///             cancellation.checkpoint()
///             await probe.hang()
///         }
///     }
///     #expect(probe.uncancelled == 0)
/// }
/// ```
///
/// A hang's cancel is counted in its cancellation handler, which runs as
/// the task is cancelled, in the cancelling task. Counting it when the
/// hanging task ends instead would also wait for that task to be scheduled
/// again, which can take seconds on a busy machine, and make the check
/// flaky. So `uncancelled` is 0 as soon as every cancel has been made.
public final class CancellationProbe: Sendable {
    private let starts = Atomic<Int>(0)
    private let cancels = Atomic<Int>(0)

    public init() {}

    /// The number of hangs that started.
    public var started: Int {
        starts.load(ordering: .sequentiallyConsistent)
    }

    /// The number of hangs whose task was cancelled.
    public var cancelled: Int {
        cancels.load(ordering: .sequentiallyConsistent)
    }

    /// The number of hangs that started and whose task hasn't been
    /// cancelled. Never too low: a hang that starts and is cancelled while
    /// this reads counts here.
    public var uncancelled: Int {
        let cancelled = cancels.load(ordering: .sequentiallyConsistent)
        return starts.load(ordering: .sequentiallyConsistent) - cancelled
    }

    /// Runs until its task is cancelled, for at most `limit`. A hang whose
    /// task is already cancelled returns at once, counted as cancelled.
    ///
    /// - Returns: Whether the task was cancelled, rather than the limit
    ///   running out.
    @discardableResult
    public func hang(atMost limit: Duration = .seconds(60)) async -> Bool {
        starts.add(1, ordering: .sequentiallyConsistent)
        let wasCancelled = Atomic(false)
        await withTaskCancellationHandler {
            try? await Task.sleep(for: limit)
        } onCancel: {
            wasCancelled.store(true, ordering: .sequentiallyConsistent)
            cancels.add(1, ordering: .sequentiallyConsistent)
        }
        return wasCancelled.load(ordering: .sequentiallyConsistent)
    }
}

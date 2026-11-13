import Synchronization

extension TestCase {
    /// Runs `body` in a task and cancels that task right after a drawn
    /// checkpoint, so a property can check what the code under test does
    /// when it is cancelled at any point.
    ///
    /// The code under test, or the closures a property hands it, marks the
    /// points where a cancellation is interesting by calling
    /// `cancellation.checkpoint()`. Hegel draws a number N, and the task is
    /// cancelled inside the call that makes the Nth checkpoint, so whatever
    /// runs after it sees `Task.isCancelled`:
    ///
    /// ```swift
    /// try await property { tc in
    ///     let run = try await tc.withRandomCancellation { cancellation in
    ///         let log = Log(onEntry: { cancellation.checkpoint($0) })
    ///         return await resource.use(log: log)
    ///     }
    ///     #expect(run.value.isReleased)
    /// }
    /// ```
    ///
    /// N is 0, which cancels before `body` starts, up to the number of
    /// checkpoints, which cancels after the last one. Sometimes the task is
    /// not cancelled at all, and a failure that doesn't need a cancellation
    /// shrinks to that. Otherwise N shrinks toward the earliest checkpoint
    /// that still fails. Pass `checkpoints` when you know how many there
    /// will be, so every cancel lands on one; without it, N is drawn from
    /// any `Int`, mostly small ones, and a number past the last checkpoint
    /// means the task is never cancelled.
    ///
    /// `checkpoint()` can be called from any task, synchronous code
    /// included, and counts calls from all of them: a checkpoint in a task
    /// the code under test starts still cancels `body`'s task. When several
    /// tasks reach checkpoints at once, which call is the Nth depends on
    /// scheduling, so a failure replays the same N but may not land on the
    /// same event.
    ///
    /// The report says where the cancel landed, with the checkpoint's label
    /// if it has one. Cancelling the task that calls this cancels `body`'s
    /// task too. `body` can't draw: draw everything it needs before.
    ///
    /// The property cancellation tests check most often is that cancelled
    /// work ends. Pass `endsWithin` to check it: once the drawn cancel
    /// lands, `body` has that long to end, or the test case fails with
    /// `StillRunning`. Its task is abandoned rather than awaited, so work
    /// that ignores cancellation fails the test case instead of hanging the
    /// test, and the failure shrinks like any other:
    ///
    /// ```swift
    /// try await property { tc in
    ///     let run = try await tc.withRandomCancellation(endsWithin: .seconds(5)) { cancellation in
    ///         try await reader.readAll(onChunk: { _ in cancellation.checkpoint() })
    ///     }
    ///     #expect(reader.isClosed)
    /// }
    /// ```
    ///
    /// As with `withStallDetection`, once a test case has stayed running,
    /// the cases the engine tries while shrinking get a shorter limit,
    /// based on how long passing cases took to end after their cancel. The
    /// cases a failure report is built from still get the full one.
    ///
    /// - Parameters:
    ///   - checkpoints: The cancel points to draw from, when the number of
    ///     checkpoints is known: `0...count`.
    ///   - name: The name the drawn cancel point is shown under.
    ///   - limit: How long `body` may keep running after the drawn cancel,
    ///     or nil to wait for it however long it takes. Allow for a busy
    ///     machine: a few seconds.
    ///   - body: The code to cancel. It gets the `Cancellation` to call
    ///     `checkpoint()` on.
    public func withRandomCancellation<Value: Sendable>(
        checkpoints: ClosedRange<Int>? = nil,
        named name: String = "cancelAfter",
        endsWithin limit: Duration? = nil,
        fileID: String = #fileID,
        line: Int = #line,
        _ body: @escaping @Sendable (_ cancellation: Cancellation) async throws -> Value
    ) async throws -> CancellationRun<Value> {
        if let checkpoints {
            precondition(checkpoints.lowerBound >= 0, "checkpoints can't be negative")
        }
        if let limit {
            precondition(limit > .zero, "an endsWithin limit must be positive")
        }
        let index: Gen<Int> =
            checkpoints.map { .int(in: $0) } ?? .oneOf(.int(in: 0...16), .int(in: 0...Int.max))
        // Printed as the number, not `Optional(n)`.
        let point = Gen<Int?>(label: Label.optional.combined(with: index.label)) { tc, printer in
            try tc.draw(index, printer: printer)
        }
        // Not cancelling at all comes first, so a failure that doesn't need
        // a cancellation shrinks to it, and a quarter of the time.
        let at = try draw(.oneOf(.just(nil), point, point, point), named: name)

        let cancellation = Cancellation(at: at)
        let task = Task {
            await cancellation.waitUntilArmed()
            defer { cancellation.noteEnded() }
            return try await body(cancellation)
        }
        cancellation.arm { task.cancel() }
        let result: Result<Value, any Error>
        if let limit {
            let effectiveLimit = stalls?.limit(for: limit) ?? limit
            guard let ended = await cancellation.result(of: task, endingWithin: effectiveLimit)
            else {
                stalls?.noteStall()
                let run = cancellation.snapshot
                note(run.description)
                throw StillRunning(
                    limit: effectiveLimit,
                    cancelledAt: run.cancelledAt ?? 0,
                    label: run.label,
                    location: "\(fileID):\(line)"
                )
            }
            if let took = cancellation.endedAfterCancel {
                stalls?.record(took)
            }
            result = ended
        } else {
            result = await withTaskCancellationHandler {
                await task.result
            } onCancel: {
                task.cancel()
            }
        }

        let run = cancellation.snapshot
        note(run.description)
        return CancellationRun(
            value: try result.get(),
            cancelledAt: run.cancelledAt,
            checkpoints: run.checkpoints
        )
    }
}

/// What `withRandomCancellation` ran: `body`'s value, and where the task
/// was cancelled.
public struct CancellationRun<Value: Sendable>: Sendable {
    /// What `body` returned.
    public var value: Value
    /// The checkpoint the task was cancelled right after, 0 for before
    /// `body` started, or nil if it was never cancelled.
    public var cancelledAt: Int?
    /// How many checkpoints `body` reached by the time it returned.
    public var checkpoints: Int

    /// Whether a checkpoint numbered `n` (counting from 1) came after the
    /// cancel, so the code that ran after it saw the task cancelled.
    public func isCancelled(after n: Int) -> Bool {
        cancelledAt.map { n >= $0 } ?? false
    }
}

/// The checkpoints of one `withRandomCancellation` run. Safe to use from
/// any task.
public final class Cancellation: Sendable {
    struct State {
        let at: Int?
        var checkpoints = 0
        var cancelledAt: Int?
        var label: String?
        var cancel: (@Sendable () -> Void)?
        var armed = false
        var waiter: CheckedContinuation<Void, Never>?
        /// When the drawn cancel landed.
        var cancelledTime: ContinuousClock.Instant?
        /// How long after the drawn cancel the body ended.
        var endedAfterCancel: Duration?
        var ended = false

        var description: String {
            let total = "\(checkpoints) checkpoint\(checkpoints == 1 ? "" : "s")"
            guard let cancelledAt else {
                return "// Not cancelled: \(total)"
            }
            if cancelledAt == 0 {
                return "// Cancelled before the first of \(total)"
            }
            let label = label.map { " (\($0))" } ?? ""
            return "// Cancelled after checkpoint \(cancelledAt) of \(checkpoints)\(label)"
        }
    }

    private let state: Mutex<State>

    init(at: Int?) {
        state = Mutex(State(at: at))
    }

    /// Counts a checkpoint, and cancels the task if it is the drawn one.
    /// The cancel happens before this returns.
    ///
    /// - Parameter label: What happened at this checkpoint, for the report.
    ///   It is evaluated only for the checkpoint the cancel lands on.
    public func checkpoint(_ label: @autoclosure () -> String? = nil) {
        let cancel = state.withLock { state -> (@Sendable () -> Void)? in
            state.checkpoints += 1
            guard state.checkpoints == state.at else {
                return nil
            }
            state.cancelledAt = state.checkpoints
            state.cancelledTime = .now
            return state.cancel
        }
        guard let cancel else {
            return
        }
        let label = label()
        state.withLock { $0.label = label }
        cancel()
    }

    /// The number of checkpoints so far.
    public var checkpoints: Int {
        state.withLock { $0.checkpoints }
    }

    /// The checkpoint the task was cancelled right after, 0 for before the
    /// body started, or nil if it hasn't been cancelled.
    public var cancelledAt: Int? {
        state.withLock { $0.cancelledAt }
    }

    var snapshot: (cancelledAt: Int?, checkpoints: Int, label: String?, description: String) {
        state.withLock { ($0.cancelledAt, $0.checkpoints, $0.label, $0.description) }
    }

    /// Notes that the body has ended, in the body's task: the time its
    /// waiter takes to be scheduled is not the body's.
    func noteEnded() {
        state.withLock { state in
            state.ended = true
            state.endedAfterCancel = state.cancelledTime.map { $0.duration(to: .now) }
        }
    }

    /// How long after the drawn cancel the body ended, if it was cancelled.
    var endedAfterCancel: Duration? {
        state.withLock { $0.endedAfterCancel }
    }

    /// Whether the body is still running `limit` after the drawn cancel.
    func isStillRunning(after limit: Duration) -> Bool {
        state.withLock { state in
            guard !state.ended, let cancelledTime = state.cancelledTime else {
                return false
            }
            return cancelledTime.duration(to: .now) >= limit
        }
    }

    /// Waits for `task`'s result, or nil once it is still running `limit`
    /// after the drawn cancel. Cancelling the waiting task cancels `task`
    /// and goes on waiting for it.
    func result<Value: Sendable>(
        of task: Task<Value, any Error>,
        endingWithin limit: Duration
    ) async -> Result<Value, any Error>? {
        let (endings, delivery) = AsyncStream.makeStream(of: Ending<Value>.self)
        Task.detached {
            delivery.yield(.ended(await task.result))
        }
        let watchdog = Task.detached {
            let poll = min(max(limit / 20, .milliseconds(1)), .milliseconds(10))
            while !Task.isCancelled {
                try? await Task.sleep(for: poll)
                if self.isStillRunning(after: limit) {
                    delivery.yield(.stillRunning)
                    return
                }
            }
        }
        let ending = await withTaskCancellationHandler {
            // In a task of its own: in a cancelled task, the stream would
            // end at once.
            await Task {
                var iterator = endings.makeAsyncIterator()
                return await iterator.next()
            }.value
        } onCancel: {
            task.cancel()
        }
        watchdog.cancel()
        switch ending {
            case .ended(let result)?:
                return result
            case .stillRunning?, nil:
                return nil
        }
    }

    /// Holds the body back until it can be cancelled, so no checkpoint is
    /// reached before there is a task to cancel.
    func waitUntilArmed() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let armed = state.withLock { state in
                if !state.armed {
                    state.waiter = continuation
                }
                return state.armed
            }
            if armed {
                continuation.resume()
            }
        }
    }

    /// Gives the cancellation the body's task, cancels it at once if the
    /// drawn point is 0, and lets the body start.
    ///
    /// The cancel is made before the body is let go: once `armed` is set,
    /// a body that hasn't started waiting yet starts at once, and would run
    /// ahead of a cancel made after it.
    func arm(_ cancel: @escaping @Sendable () -> Void) {
        let cancelNow = state.withLock { state in
            state.cancel = cancel
            guard state.at == 0 else {
                return false
            }
            state.cancelledAt = 0
            state.cancelledTime = .now
            return true
        }
        if cancelNow {
            cancel()
        }
        let waiter = state.withLock { state in
            state.armed = true
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume()
    }
}

private enum Ending<Value: Sendable>: Sendable {
    case ended(Result<Value, any Error>)
    case stillRunning
}

/// The failure of a test case whose work kept running after
/// `withRandomCancellation` cancelled it: it did not end within the
/// `endsWithin` limit.
///
/// Work that ignores cancellation at different `withRandomCancellation`
/// calls is a different bug, so the origin is the call's location.
public struct StillRunning: Error, FailureOrigin, CustomStringConvertible {
    /// How long the work kept running after the cancel.
    public let limit: Duration
    /// The checkpoint the cancel landed right after, or 0 for before the
    /// body started.
    public let cancelledAt: Int
    /// The label of that checkpoint, if it had one.
    public let label: String?
    /// Where `withRandomCancellation` was called, as `file:line`.
    public let location: String

    public var failureOrigin: String {
        "Still running after cancellation at \(location)"
    }

    public var description: String {
        let point =
            cancelledAt == 0
            ? "before the first checkpoint"
            : "at checkpoint \(cancelledAt)\(label.map { " (\($0))" } ?? "")"
        return "Still running \(limit) after cancellation \(point), at \(location)"
    }
}

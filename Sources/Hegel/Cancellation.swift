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
    /// - Parameters:
    ///   - checkpoints: The cancel points to draw from, when the number of
    ///     checkpoints is known: `0...count`.
    ///   - name: The name the drawn cancel point is shown under.
    ///   - body: The code to cancel. It gets the `Cancellation` to call
    ///     `checkpoint()` on.
    public func withRandomCancellation<Value: Sendable>(
        checkpoints: ClosedRange<Int>? = nil,
        named name: String = "cancelAfter",
        _ body: @escaping @Sendable (_ cancellation: Cancellation) async throws -> Value
    ) async throws -> CancellationRun<Value> {
        if let checkpoints {
            precondition(checkpoints.lowerBound >= 0, "checkpoints can't be negative")
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
            return try await body(cancellation)
        }
        cancellation.arm { task.cancel() }
        let result = await withTaskCancellationHandler {
            await task.result
        } onCancel: {
            task.cancel()
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

    var snapshot: (cancelledAt: Int?, checkpoints: Int, description: String) {
        state.withLock { ($0.cancelledAt, $0.checkpoints, $0.description) }
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
    func arm(_ cancel: @escaping @Sendable () -> Void) {
        let (waiter, cancelNow) = state.withLock { state in
            state.cancel = cancel
            state.armed = true
            let cancelNow = state.at == 0
            if cancelNow {
                state.cancelledAt = 0
            }
            defer { state.waiter = nil }
            return (state.waiter, cancelNow)
        }
        if cancelNow {
            cancel()
        }
        waiter?.resume()
    }
}

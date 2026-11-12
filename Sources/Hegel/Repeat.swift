import CHegel

extension TestCase {
    /// Runs `body` again and again, for as long as the engine wants another
    /// iteration, and never returns.
    ///
    /// It is a loop the engine controls: a failing loop shrinks to the
    /// fewest iterations that show the failure, as a collection shrinks to
    /// the fewest elements. Use it for a sequence of operations driven by
    /// drawn values, when a full state machine is more than you need:
    ///
    /// ```swift
    /// try property { tc in
    ///     var stack = Stack<Int>()
    ///     try tc.repeat { tc in
    ///         let n = try tc.draw(.int(), named: "n")
    ///         stack.push(n)
    ///         #expect(stack.top == n)
    ///     }
    /// }
    /// ```
    ///
    /// The report shows each iteration's draws and notes under a
    /// `// Repetition #N` line, indented. Draw names carry on from one
    /// iteration to the next (`n`, `n_2`, ...).
    ///
    /// An iteration that fails an assumption is skipped and the loop goes
    /// on. Any other failure ends the loop and fails the test case. When the
    /// engine ends the loop, `repeat` throws to end the test case as passed:
    /// let that error propagate, and put nothing after the call.
    public func `repeat`(_ body: (TestCase) throws -> Void) throws -> Never {
        let loop = try RepeatLoop(self)
        while let iteration = try loop.next() {
            var failure: (any Error)?
            do {
                try body(iteration)
            } catch {
                failure = error
            }
            try loop.finish(iteration, failure)
        }
        throw RepeatFinished()
    }

    /// Runs the async `body` again and again, for as long as the engine
    /// wants another iteration, and never returns. See `repeat(_:)`.
    public func `repeat`(_ body: (TestCase) async throws -> Void) async throws -> Never {
        let loop = try RepeatLoop(self)
        while let iteration = try loop.next() {
            var failure: (any Error)?
            do {
                try await body(iteration)
            } catch {
                failure = error
            }
            try loop.finish(iteration, failure)
        }
        throw RepeatFinished()
    }
}

/// Thrown by `repeat` when the engine ends the loop: the test case passed.
struct RepeatFinished: Error {}

/// One `repeat` call's engine loop, shared by the sync and async versions.
private final class RepeatLoop {
    private let tc: TestCase
    private let raw: OpaquePointer
    private var iteration = 0

    init(_ tc: TestCase) throws {
        var handle: OpaquePointer?
        try tc.call { hegel_new_repeat($0, tc.raw, &handle) }
        guard let handle else {
            throw HegelError.engine("libhegel returned no repeat handle")
        }
        self.tc = tc
        raw = handle
    }

    deinit {
        hegel_repeat_free(nil, raw)
    }

    /// The handle the next iteration runs on, or nil when the loop is over.
    func next() throws -> TestCase? {
        var more = false
        try tc.call { hegel_repeat_more($0, tc.raw, raw, &more) }
        guard more else {
            return nil
        }
        iteration += 1
        tc.note("// Repetition #\(iteration)")
        return try tc.block(indent: 2, sharingNames: true)
    }

    /// Closes an iteration that returned or threw `error`: a rejected one
    /// is skipped, and any other failure ends the loop.
    func finish(_ iteration: TestCase, _ error: (any Error)?) throws {
        switch error {
            case nil:
                if tc.hasRecordedFailure() {
                    try failed()
                    throw StopAfterRecordedFailure()
                }
            case TestCaseStop.rejected?:
                break
            case let error?:
                if let stop = iteration.stop {
                    tc.stop = stop
                }
                // A stop or a usage error is not the iteration failing.
                if !(error is TestCaseStop), !(error is HegelError) {
                    try failed()
                }
                throw error
        }
    }

    /// Tells the engine the iteration just run failed, so the shrinker can
    /// tell it from the ones before.
    private func failed() throws {
        try tc.call { hegel_repeat_failed($0, tc.raw, raw) }
    }
}

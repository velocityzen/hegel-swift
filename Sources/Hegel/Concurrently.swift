extension TestCase {
    /// Runs `body` on `workers` tasks at once, each drawing from its own
    /// clone of this test case, and returns their results in worker order.
    ///
    /// Use it to test code under real concurrency: each worker runs on its
    /// own thread from the global executor, at the same time as the others.
    ///
    /// ```swift
    /// try await property { tc in
    ///     let counter = AtomicCounter()
    ///     let added = try await tc.concurrently(workers: 4) { worker, tc in
    ///         let n = try tc.draw(.int(in: 0...100), named: "n")
    ///         counter.add(n)
    ///         return n
    ///     }
    ///     #expect(counter.value == added.reduce(0, +))
    /// }
    /// ```
    ///
    /// Each clone draws from an independent stream of choices, so what a
    /// worker draws doesn't depend on how the workers are scheduled, and a
    /// failure replays and shrinks like any other. What your code does with
    /// those values across threads is up to the scheduler, so a race in it
    /// may not reproduce every time.
    ///
    /// The report prefixes each worker's lines with `[worker N +X.XXXms]`:
    /// the worker and when the line was printed. Draw names are shared with
    /// this test case.
    ///
    /// The workers make up one test case. If any of them is rejected or
    /// runs out of budget, the test case ends that way. Otherwise, if any
    /// fails, the lowest-numbered worker's failure fails the test case, and
    /// the others are noted in the report. Don't draw from this test case
    /// while the workers run; `concurrently` waits for all of them.
    public func concurrently<Value: Sendable>(
        workers: Int,
        _ body: @escaping @Sendable (_ worker: Int, _ tc: TestCase) async throws -> Value
    ) async throws -> [Value] {
        precondition(workers > 0, "concurrently needs at least one worker")
        var clones: [Handoff<TestCase>] = []
        for worker in 0..<workers {
            clones.append(Handoff(value: try clone(worker: worker)))
        }
        let results = await withTaskGroup(of: (Int, WorkerOutcome, Value?).self) { group in
            for (worker, clone) in clones.enumerated() {
                group.addTask {
                    await Self.work(worker, clone, body)
                }
            }
            var results = [(WorkerOutcome, Value?)](repeating: (.done, nil), count: workers)
            for await (worker, outcome, value) in group {
                results[worker] = (outcome, value)
            }
            return results
        }
        try resolveWorkers(results.map(\.0), self)
        // Every worker that didn't end the test case returned a value.
        return results.map { $0.1! }
    }

    @concurrent
    private static func work<Value: Sendable>(
        _ worker: Int,
        _ handoff: Handoff<TestCase>,
        _ body: @Sendable (Int, TestCase) async throws -> Value
    ) async -> (Int, WorkerOutcome, Value?) {
        let tc = handoff.value
        do {
            let value = try await body(worker, tc)
            return (worker, tc.hasRecordedFailure() ? .recordedFailure : .done, value)
        } catch TestCaseStop.rejected {
            return (worker, .rejected, nil)
        } catch TestCaseStop.overrun {
            return (worker, .overrun, nil)
        } catch let error as HegelError {
            return (worker, .engineError(error), nil)
        } catch {
            return (worker, .failed(error), nil)
        }
    }
}

/// How a concurrent worker's run ended.
enum WorkerOutcome: Sendable {
    case done
    /// The worker failed an `#expect` (or the like) that the test framework
    /// recorded.
    case recordedFailure
    case rejected
    case overrun
    case engineError(HegelError)
    case failed(any Error)
}

/// Ends the test case if a worker did: an engine error first, then a stop,
/// then the lowest-numbered worker's failure. The failures of other
/// workers are noted in the report.
func resolveWorkers(_ outcomes: [WorkerOutcome], _ tc: TestCase) throws {
    var failures: [(worker: Int, error: any Error)] = []
    var stop: TestCaseStop?
    var recorded = false
    for (worker, outcome) in outcomes.enumerated() {
        switch outcome {
            case .done: break
            case .engineError(let error): throw error
            case .overrun: stop = .overrun
            case .rejected: stop = stop ?? .rejected
            case .recordedFailure: recorded = true
            case .failed(let error): failures.append((worker, error))
        }
    }
    let dropped = stop == nil ? failures.dropFirst() : failures[...]
    for failure in dropped {
        tc.note("Dropped concurrent failure from worker \(failure.worker): \(failure.error)")
    }
    if let stop {
        tc.stop = stop
        throw stop
    }
    if let first = failures.first {
        throw first.error
    }
    if recorded {
        throw StopAfterRecordedFailure()
    }
}

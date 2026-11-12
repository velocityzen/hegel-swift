import Hegel
import Synchronization
import Testing

/// Reaches `count` checkpoints, and returns whether the task was cancelled
/// after each one.
@Sendable
private func cancelledAfterEach(_ count: Int, _ cancellation: Cancellation) -> [Bool] {
    (1...count).map { n in
        cancellation.checkpoint("step \(n)")
        return Task.isCancelled
    }
}

@Suite("withRandomCancellation")
struct CancellationTests {
    @Test("cancels right after the drawn checkpoint, before the first, or never")
    func cancelsAtTheDrawnPoint() async throws {
        let seen = Mutex<Set<Int?>>([])
        let outcome = try await Property.run(settings: isolated) { tc in
            let run = try await tc.withRandomCancellation(checkpoints: 0...10) { cancellation in
                let before = Task.isCancelled
                return (before, cancelledAfterEach(10, cancellation))
            }
            seen.withLock { _ = $0.insert(run.cancelledAt) }
            let (before, after) = run.value
            if before != (run.cancelledAt == 0) {
                throw Failed()
            }
            if after != (1...10).map(run.isCancelled(after:)) {
                throw Failed()
            }
            if run.checkpoints != 10 {
                throw Failed()
            }
        }
        #expect(outcome.failure == nil)
        let points = seen.withLock { $0 }
        #expect(points.contains(nil))
        #expect(points.contains(0))
        #expect(points.contains(10))
    }

    @Test("a checkpoint in another task cancels the body's task")
    func otherTasks() async throws {
        let outcome = try await Property.run(settings: isolated) { tc in
            let run = try await tc.withRandomCancellation(checkpoints: 0...4) { cancellation in
                var seen: [Bool] = []
                for _ in 1...4 {
                    // An unstructured task: it doesn't inherit the body's
                    // cancellation, but its checkpoint cancels the body.
                    await Task { cancellation.checkpoint() }.value
                    seen.append(Task.isCancelled)
                }
                return seen
            }
            if run.value != (1...4).map(run.isCancelled(after:)) {
                throw Failed()
            }
        }
        #expect(outcome.failure == nil)
    }

    @Test("without a range, cancels at small and large points, and past the last")
    func unbounded() async throws {
        let cancelled = Atomic(0)
        let notCancelled = Atomic(0)
        let outcome = try await Property.run(settings: isolated) { tc in
            let run = try await tc.withRandomCancellation { cancellation in
                cancelledAfterEach(20, cancellation)
            }
            if run.value != (1...20).map(run.isCancelled(after:)) {
                throw Failed()
            }
            if run.cancelledAt == nil {
                notCancelled.add(1, ordering: .relaxed)
            } else {
                cancelled.add(1, ordering: .relaxed)
            }
        }
        #expect(outcome.failure == nil)
        #expect(cancelled.load(ordering: .relaxed) > 0)
        #expect(notCancelled.load(ordering: .relaxed) > 0)
    }

    @Test("a failure shrinks to the earliest checkpoint that shows it, with its label")
    func shrinksToTheEarliestPoint() async throws {
        let outcome = try await Property.run(settings: isolated) { tc in
            let run = try await tc.withRandomCancellation(checkpoints: 0...6) { cancellation in
                cancelledAfterEach(6, cancellation)
            }
            // A bug that shows when the cancel lands at step 4 or later.
            if run.value[3...].contains(true), !run.value[..<3].contains(true) {
                throw Failed()
            }
        }
        let failure = try #require(outcome.failure)
        #expect(
            failure.counterexamples[0].drawn == [
                "let cancelAfter = 4", "// Cancelled after checkpoint 4 of 6 (step 4)",
            ]
        )
    }

    @Test("a failure that doesn't need a cancellation shrinks to none")
    func shrinksToNoCancellation() async throws {
        let outcome = try await Property.run(settings: isolated) { tc in
            let n = try tc.draw(.int(in: 0...10), named: "n")
            _ = try await tc.withRandomCancellation(checkpoints: 0...3) { cancellation in
                cancelledAfterEach(3, cancellation)
            }
            if n > 5 {
                throw Failed()
            }
        }
        let failure = try #require(outcome.failure)
        #expect(
            failure.counterexamples[0].drawn == [
                "let n = 6", "let cancelAfter = nil", "// Not cancelled: 3 checkpoints",
            ]
        )
    }

    @Test("cancelling the caller cancels the body")
    func callerCancellation() async throws {
        let outcome = try await Property.run(settings: isolated.merging(Settings(testCases: 5))) {
            tc in
            let started = Atomic(false)
            // The caller task only borrows the test case: this body awaits
            // it before going on.
            nonisolated(unsafe) let tc = tc
            let caller = Task {
                try await tc.withRandomCancellation(checkpoints: 0...0) { _ in
                    started.store(true, ordering: .sequentiallyConsistent)
                    while !Task.isCancelled { await Task.yield() }
                    return true
                }
            }
            while !started.load(ordering: .sequentiallyConsistent) { await Task.yield() }
            caller.cancel()
            let run = try await caller.value
            if !run.value {
                throw Failed()
            }
        }
        #expect(outcome.failure == nil)
    }

    @Test("the body's error is rethrown")
    func errors() async {
        await #expect(throws: Failed.self) {
            let outcome = try await Property.run(settings: isolated) { tc in
                _ = try await tc.withRandomCancellation { _ in throw Failed() }
            }
            if let failure = outcome.failure {
                throw failure.counterexamples[0].error
            }
        }
    }
}

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

/// Lends the test case to a task that the property body awaits before it
/// goes on. Swift's region checks can't see that this is safe.
private final class CallerTask: @unchecked Sendable {
    let tc: TestCase
    let started = Atomic(false)

    init(_ tc: TestCase) {
        self.tc = tc
    }
}

/// A count that tasks can share: a local `Atomic` can't be captured by a
/// task group's child tasks.
private final class Counter: Sendable {
    private let count = Atomic(0)

    var value: Int { count.load(ordering: .relaxed) }

    func increment() {
        count.add(1, ordering: .relaxed)
    }
}

/// Waits forever, ignoring cancellation, as a lost wakeup does, and
/// counts the waits.
private final class Stuck: Sendable {
    private let starts = Atomic<Int>(0)

    var started: Int { starts.load(ordering: .sequentiallyConsistent) }

    func wait() async {
        starts.add(1, ordering: .sequentiallyConsistent)
        await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
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

    @Test("a cancel before the first checkpoint lands before the body starts, under load")
    func cancelBeforeStartUnderLoad() async throws {
        // Many runs at once, so a body's task can start the moment it is
        // let go, on another thread, racing the cancel.
        let missed = Counter()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    _ = try? await Property.run(
                        settings: isolated.merging(Settings(testCases: 2000))
                    ) { tc in
                        let run = try await tc.withRandomCancellation(checkpoints: 0...0) { _ in
                            Task.isCancelled
                        }
                        if run.cancelledAt == 0, !run.value {
                            missed.increment()
                        }
                    }
                }
            }
        }
        #expect(missed.value == 0)
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
            let caller = CallerTask(tc)
            let task = Task {
                try await caller.tc.withRandomCancellation(checkpoints: 0...0) { _ in
                    caller.started.store(true, ordering: .sequentiallyConsistent)
                    while !Task.isCancelled { await Task.yield() }
                    return true
                }
            }
            while !caller.started.load(ordering: .sequentiallyConsistent) { await Task.yield() }
            task.cancel()
            let run = try await task.value
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

    @Test("endsWithin: work that ends promptly after the cancel passes")
    func endsPromptly() async throws {
        let cancelled = Atomic(0)
        let outcome = try await Property.run(settings: isolated) { tc in
            let run = try await tc.withRandomCancellation(
                checkpoints: 0...5,
                endsWithin: .seconds(5)
            ) { cancellation in
                for step in 1...5 {
                    cancellation.checkpoint("step \(step)")
                    // Ends the work once the task is cancelled.
                    guard (try? await Task.sleep(for: .milliseconds(1))) != nil else {
                        return step
                    }
                }
                return 5
            }
            if run.cancelledAt != nil {
                cancelled.add(1, ordering: .relaxed)
            }
        }
        #expect(outcome.failure == nil)
        #expect(cancelled.load(ordering: .relaxed) > 0)
    }

    @Test("endsWithin: work that ignores the cancel fails, shrunk to the earliest checkpoint")
    func ignoresTheCancel() async throws {
        let stuck = Stuck()
        let outcome = try await Property.run(settings: isolated) { tc in
            _ = try await tc.withRandomCancellation(
                checkpoints: 0...5,
                endsWithin: .milliseconds(300)
            ) { cancellation in
                for step in 1...5 {
                    cancellation.checkpoint("step \(step)")
                    // A bug: a cancel that lands at step 3 or later is lost.
                    if step >= 3, cancellation.cancelledAt == step {
                        await stuck.wait()
                    }
                }
            }
        }
        let counterexample = try #require(outcome.failure?.counterexamples.first)
        #expect(
            counterexample.drawn == [
                "let cancelAfter = 3", "// Cancelled after checkpoint 3 of 3 (step 3)",
            ]
        )
        let stillRunning = try #require(counterexample.error as? StillRunning)
        #expect(stillRunning.limit == .milliseconds(300))
        #expect(stillRunning.cancelledAt == 3)
        #expect(stillRunning.label == "step 3")
        #expect(stillRunning.location.hasPrefix("HegelTests/CancellationTests.swift:"))
        #expect(counterexample.origin.hasPrefix("Still running after cancellation at "))
        #expect(stuck.started > 0)
    }

    @Test("endsWithin: work that was never cancelled may take longer than the limit")
    func notCancelled() async throws {
        let notCancelled = Atomic(0)
        let outcome = try await Property.run(settings: isolated.merging(Settings(testCases: 8))) {
            tc in
            let run = try await tc.withRandomCancellation(
                checkpoints: 1...1,
                endsWithin: .milliseconds(100)
            ) { cancellation in
                // The cancel lands in this call, in this task, so the
                // cancelled work ends without waiting to be scheduled.
                cancellation.checkpoint()
                if !Task.isCancelled {
                    try await Task.sleep(for: .milliseconds(250))
                }
            }
            if run.cancelledAt == nil {
                notCancelled.add(1, ordering: .relaxed)
            }
        }
        #expect(outcome.failure == nil)
        #expect(notCancelled.load(ordering: .relaxed) > 0)
    }

    @Test("endsWithin: cancelling the caller cancels the body, and waits for it")
    func endsWithinCallerCancellation() async throws {
        let outcome = try await Property.run(settings: isolated.merging(Settings(testCases: 5))) {
            tc in
            let caller = CallerTask(tc)
            let task = Task {
                try await caller.tc.withRandomCancellation(
                    checkpoints: 1...1,
                    endsWithin: .seconds(5)
                ) { _ in
                    caller.started.store(true, ordering: .sequentiallyConsistent)
                    while !Task.isCancelled { await Task.yield() }
                    return true
                }
            }
            while !caller.started.load(ordering: .sequentiallyConsistent) { await Task.yield() }
            task.cancel()
            let run = try await task.value
            if !run.value {
                throw Failed()
            }
        }
        #expect(outcome.failure == nil)
    }

    @Test("endsWithin: shrink candidates get a shorter limit; the report has the full one")
    func shrinksFaster() async throws {
        let full: Duration = .seconds(1)
        let stuck = Stuck()
        let limits = Mutex<[Duration]>([])
        let outcome = try await Property.run(settings: isolated) { tc in
            let n = try tc.draw(.int(in: 0...1000), named: "n")
            do {
                _ = try await tc.withRandomCancellation(
                    checkpoints: 1...1,
                    endsWithin: full
                ) { cancellation in
                    cancellation.checkpoint()
                    if n >= 10, Task.isCancelled {
                        await stuck.wait()
                    }
                }
            } catch let stillRunning as StillRunning {
                limits.withLock { $0.append(stillRunning.limit) }
                throw stillRunning
            }
        }
        let counterexample = try #require(outcome.failure?.counterexamples.first)
        #expect(counterexample.drawn.first == "let n = 10")
        #expect((counterexample.error as? StillRunning)?.limit == full)
        // Checked by the limits the failures had, not by wall-clock time,
        // which a loaded CI runner stretches.
        let seen = limits.withLock { $0 }
        let shortened = seen.filter { $0 < full }
        #expect(!shortened.isEmpty)
        #expect(shortened.allSatisfy { $0 >= .milliseconds(100) })
    }

    @Test("stallsAfter: a hang in a run that isn't cancelled fails, shrunk to no cancel")
    func stallsUncancelled() async throws {
        let stuck = Stuck()
        let outcome = try await Property.run(settings: isolated) { tc in
            _ = try await tc.withRandomCancellation(
                checkpoints: 0...3,
                endsWithin: .seconds(5),
                stallsAfter: .milliseconds(300)
            ) { cancellation in
                cancellation.checkpoint("step 1")
                cancellation.checkpoint("step 2")
                // A bug: work the cancel doesn't reach first never ends.
                if !Task.isCancelled {
                    await stuck.wait()
                }
            }
        }
        let counterexample = try #require(outcome.failure?.counterexamples.first)
        #expect(
            counterexample.drawn == ["let cancelAfter = nil", "// Not cancelled: 2 checkpoints"]
        )
        let stalled = try #require(counterexample.error as? Stalled)
        #expect(stalled.limit == .milliseconds(300))
        #expect(stalled.beats == 2)
        #expect(stalled.location.hasPrefix("HegelTests/CancellationTests.swift:"))
        #expect(counterexample.origin.hasPrefix("Stalled at "))
        #expect(stuck.started > 0)
    }

    @Test("stallsAfter: a hang before the drawn cancel fails")
    func stallsBeforeTheCancel() async throws {
        let stuck = Stuck()
        let outcome = try await Property.run(settings: isolated) { tc in
            _ = try await tc.withRandomCancellation(
                checkpoints: 1...1,
                stallsAfter: .milliseconds(300)
            ) { cancellation in
                // A bug: the work hangs before it reaches its cancel point.
                await stuck.wait()
                cancellation.checkpoint()
            }
        }
        let counterexample = try #require(outcome.failure?.counterexamples.first)
        let stalled = try #require(counterexample.error as? Stalled)
        #expect(stalled.beats == 0)
    }

    @Test("stallsAfter: slow work that keeps beating passes")
    func slowButBeating() async throws {
        let outcome = try await Property.run(settings: isolated.merging(Settings(testCases: 3))) {
            tc in
            _ = try await tc.withRandomCancellation(
                checkpoints: 0...0,
                stallsAfter: .seconds(1)
            ) { cancellation in
                // Uncancelled runs take 1.5 s in all, beating every 50 ms.
                for _ in 1...30 {
                    try? await Task.sleep(for: .milliseconds(50))
                    cancellation.beat()
                }
            }
        }
        #expect(outcome.failure == nil)
    }

    @Test("stallsAfter: once the cancel lands, endsWithin takes over")
    func endsWithinTakesOver() async throws {
        let cancelled = Atomic(0)
        let outcome = try await Property.run(settings: isolated.merging(Settings(testCases: 8))) {
            tc in
            let run = try await tc.withRandomCancellation(
                checkpoints: 1...1,
                endsWithin: .seconds(5),
                stallsAfter: .milliseconds(100)
            ) { cancellation in
                cancellation.checkpoint()
                if Task.isCancelled {
                    // Cleanup that takes longer than the stall limit, with
                    // no beats: within `endsWithin`, so not a stall.
                    await Task.detached { try? await Task.sleep(for: .milliseconds(300)) }.value
                }
            }
            if run.cancelledAt != nil {
                cancelled.add(1, ordering: .relaxed)
            }
        }
        #expect(outcome.failure == nil)
        #expect(cancelled.load(ordering: .relaxed) > 0)
    }

    @Test("stallsAfter: shrink candidates get a shorter limit; the report has the full one")
    func stallsShrinkFaster() async throws {
        let full: Duration = .seconds(1)
        let stuck = Stuck()
        let limits = Mutex<[Duration]>([])
        let outcome = try await Property.run(settings: isolated) { tc in
            let n = try tc.draw(.int(in: 0...1000), named: "n")
            do {
                _ = try await tc.withRandomCancellation(
                    checkpoints: 1...1,
                    stallsAfter: full
                ) { cancellation in
                    if n >= 10 {
                        await stuck.wait()
                    }
                    cancellation.checkpoint()
                }
            } catch let stalled as Stalled {
                limits.withLock { $0.append(stalled.limit) }
                throw stalled
            }
        }
        let counterexample = try #require(outcome.failure?.counterexamples.first)
        #expect(counterexample.drawn.first == "let n = 10")
        #expect((counterexample.error as? Stalled)?.limit == full)
        let shortened = limits.withLock { $0 }.filter { $0 < full }
        #expect(!shortened.isEmpty)
        #expect(shortened.allSatisfy { $0 >= .milliseconds(100) })
    }
}

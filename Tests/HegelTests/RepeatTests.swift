import Hegel
import Synchronization
import Testing

/// A passing loop runs until the test case's budget is used up, many
/// thousands of iterations, so tests of passing loops run few cases.
private let fewCases = isolated.merging(Settings(testCases: 5))

@Suite("repeat")
struct RepeatTests {
    @Test("a loop the engine ends passes")
    func passes() throws {
        let iterations = Atomic(0)
        let outcome = try Property.run(settings: fewCases) { tc in
            try tc.repeat { tc in
                _ = try tc.draw(.int(in: 0...9))
                iterations.add(1, ordering: .relaxed)
            }
        }
        #expect(outcome.failure == nil)
        let count = iterations.load(ordering: .relaxed)
        #expect(count > 0)
    }

    @Test("a failing loop shrinks to the fewest iterations, each under its heading")
    func shrinks() throws {
        let outcome = try Property.run(settings: isolated) { tc in
            var total = 0
            try tc.repeat { tc in
                let n = try tc.draw(.int(in: 0...10), named: "n")
                total += n
                if total > 15 {
                    throw Failed()
                }
            }
        }
        let failure = try #require(outcome.failure)
        #expect(
            failure.counterexamples[0].drawn == [
                "// Repetition #1", "  let n = 6", "// Repetition #2", "  let n_2 = 10",
            ]
        )
    }

    @Test("an iteration that fails an assumption is skipped")
    func rejectedIterations() throws {
        let outcome = try Property.run(settings: fewCases) { tc in
            try tc.repeat { tc in
                let n = try tc.draw(.int(in: 0...1))
                try tc.assume(n == 0)
            }
        }
        #expect(outcome.failure == nil)
    }

    @Test("async bodies")
    func async() async throws {
        let outcome = try await Property.run(settings: isolated) { tc in
            try await tc.repeat { tc in
                let n = try tc.draw(.int(in: 0...100), named: "n")
                await Task.yield()
                if n > 50 {
                    throw Failed()
                }
            }
        }
        let failure = try #require(outcome.failure)
        #expect(failure.counterexamples[0].drawn == ["// Repetition #1", "  let n = 51"])
    }
}

@Suite("concurrently")
struct ConcurrentlyTests {
    @Test("returns each worker's value in worker order")
    func values() async throws {
        let outcome = try await Property.run(settings: isolated) { tc in
            let workers = try await tc.concurrently(workers: 4) { worker, _ in worker }
            if workers != [0, 1, 2, 3] {
                throw Failed()
            }
        }
        #expect(outcome.failure == nil)
    }

    @Test("a worker's failure fails the test case, with its lines attributed")
    func failure() async throws {
        let outcome = try await Property.run(settings: isolated) { tc in
            _ = try await tc.concurrently(workers: 2) { worker, tc in
                let n = try tc.draw(.int(in: 0...10), named: "n")
                if worker == 1, n > 3 {
                    throw Failed()
                }
            }
        }
        let drawn = try #require(outcome.failure).counterexamples[0].drawn
        #expect(drawn.count == 2)
        #expect(drawn[0].hasPrefix("[worker 0 ") && drawn[0].hasSuffix("] let n = 0"))
        #expect(drawn[1].hasPrefix("[worker 1 ") && drawn[1].hasSuffix("] let n_2 = 4"))
    }

    @Test("a worker that rejects rejects the test case")
    func rejection() async {
        await #expect(throws: HegelError.self) {
            try await Property.run(settings: isolated) { tc in
                _ = try await tc.concurrently(workers: 2) { worker, tc in
                    if worker == 0 {
                        try tc.reject()
                    }
                }
            }
        }
    }

    @Test("workers run at the same time")
    func parallel() async throws {
        // Each worker spins, without yielding, until the other has arrived:
        // only workers on different threads both get there.
        let bothArrived = Atomic(true)
        let outcome = try await Property.run(settings: isolated.merging(Settings(testCases: 5))) {
            tc in
            let arrived = Atomic(0)
            _ = try await tc.concurrently(workers: 2) { _, _ in
                arrived.add(1, ordering: .sequentiallyConsistent)
                let deadline = ContinuousClock.now + .seconds(5)
                while arrived.load(ordering: .sequentiallyConsistent) < 2 {
                    if ContinuousClock.now > deadline {
                        bothArrived.store(false, ordering: .relaxed)
                        return
                    }
                }
            }
        }
        let parallel = bothArrived.load(ordering: .relaxed)
        #expect(outcome.failure == nil)
        #expect(parallel)
    }
}

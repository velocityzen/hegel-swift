import Hegel
import Synchronization
import Testing

/// Only the explicit phase: the examples run, and nothing is generated.
private let examplesOnly = isolated.merging(Settings(phases: .explicit))

/// The usage error a run threw, if it threw one.
private func usageError(_ run: () throws -> Void) -> String? {
    do {
        try run()
        return nil
    } catch HegelError.usage(let message) {
        return message
    } catch {
        return "unexpected \(error)"
    }
}

@Suite("Explicit examples")
struct ExplicitExampleTests {
    @Test("run first, in order, with their values")
    func values() throws {
        let seen = Mutex<[Int]>([])
        let outcome = try Property.run(settings: examplesOnly, examples: [["n": 3], ["n": 7]]) {
            tc in
            let n = try tc.draw(.int(), named: "n")
            seen.withLock { $0.append(n) }
        }
        #expect(outcome.failure == nil)
        #expect(seen.withLock { $0 } == [3, 7])
    }

    @Test("run before generated cases")
    func beforeGeneration() throws {
        let seen = Mutex<[Int]>([])
        _ = try Property.run(
            settings: isolated.merging(Settings(testCases: 3)),
            examples: [["n": -1]]
        ) {
            tc in
            let n = try tc.draw(.int(in: 0...10), named: "n")
            seen.withLock { $0.append(n) }
        }
        let first = seen.withLock { $0.first }
        #expect(first == -1)
    }

    @Test("don't run when the explicit phase is off")
    func phaseOff() throws {
        let ran = Atomic(false)
        _ = try Property.run(
            settings: isolated.merging(Settings(testCases: 3, phases: [.generate])),
            examples: [["n": -1]]
        ) { tc in
            if try tc.draw(.int(in: 0...10), named: "n") == -1 {
                ran.store(true, ordering: .relaxed)
            }
        }
        let explicitRan = ran.load(ordering: .relaxed)
        #expect(!explicitRan)
    }

    @Test("a failing example is reported with its values and no blob, and ends the run")
    func failure() throws {
        let runs = Atomic(0)
        let outcome = try Property.run(settings: isolated, examples: [["n": 3, "label": "x"]]) {
            tc in
            let n = try tc.draw(.int(), named: "n")
            _ = try tc.draw(.string(), named: "label")
            tc.note("checking")
            runs.add(1, ordering: .relaxed)
            if n == 3 {
                throw Failed()
            }
        }
        let counterexample = try #require(outcome.failure?.counterexamples.first)
        #expect(counterexample.drawn == ["let n = 3", "let label = \"x\"", "checking"])
        #expect(counterexample.reproductionBlob == nil)
        let n = counterexample.example?.values["n"] as? Int
        #expect(n == 3)
        // Only the example ran: nothing was generated after it.
        let bodyRuns = runs.load(ordering: .relaxed)
        #expect(bodyRuns == 1)
    }

    @Test("with reportMultipleFailures, every example runs and generation drops their bugs")
    func multipleFailures() throws {
        struct Negative: Error {}
        struct Large: Error {}
        let settings = isolated.merging(Settings(reportMultipleFailures: true))
        let outcome = try Property.run(settings: settings, examples: [["n": -5], ["n": -6]]) { tc in
            let n = try tc.draw(.int(in: -1000...1000), named: "n")
            if n < 0 { throw Negative() }
            if n > 100 { throw Large() }
        }
        let counterexamples = try #require(outcome.failure).counterexamples
        #expect(counterexamples.map { $0.example != nil } == [true, true, false])
        #expect(counterexamples[0].drawn == ["let n = -5"])
        #expect(counterexamples[2].drawn == ["let n = 101"])
    }

    @Test("unnamed and repeated draws, repeat and concurrently")
    func names() throws {
        let outcome = try Property.run(
            settings: examplesOnly,
            examples: [["draw_1": true, "n": 1, "n_2": 2]]
        ) { tc in
            _ = try tc.draw(.bool())
            _ = try tc.draw(.int(), named: "n")
            try tc.repeat { tc in
                _ = try tc.draw(.int(), named: "n")
                throw Failed()
            }
        }
        let drawn = try #require(outcome.failure).counterexamples[0].drawn
        #expect(drawn == ["let draw_1 = true", "let n = 1", "// Repetition #1", "  let n_2 = 2"])
    }

    @Test("concurrent workers share the example's values")
    func concurrently() async throws {
        let outcome = try await Property.run(
            settings: examplesOnly,
            examples: [["a": 1, "b": 2]]
        ) { tc in
            let values = try await tc.concurrently(workers: 2) { worker, tc in
                try tc.draw(.int(), named: worker == 0 ? "a" : "b")
            }
            if values != [1, 2] {
                throw Failed()
            }
        }
        #expect(outcome.failure == nil)
    }

    @Test("misuse is a usage error")
    func misuse() {
        let missing = usageError {
            _ = try Property.run(settings: examplesOnly, examples: [["m": 1]]) { tc in
                _ = try tc.draw(.int(), named: "n")
            }
        }
        #expect(missing?.contains("no value for the draw \"n\"") == true)

        let wrongType = usageError {
            _ = try Property.run(settings: examplesOnly, examples: [["x": 1]]) { tc in
                _ = try tc.draw(.double(), named: "x")
            }
        }
        #expect(wrongType?.contains("is a Int, but the draw makes a Double") == true)

        let unused = usageError {
            _ = try Property.run(settings: examplesOnly, examples: [["n": 1, "typo": 2]]) { tc in
                _ = try tc.draw(.int(), named: "n")
            }
        }
        #expect(unused?.contains("\"typo\"") == true)

        let rejected = usageError {
            _ = try Property.run(settings: examplesOnly, examples: [[:]]) { tc in
                try tc.reject()
            }
        }
        #expect(rejected == "Explicit examples must not be rejected")

        let engineOnly = usageError {
            _ = try Property.run(settings: examplesOnly, examples: [[:]]) { tc in
                _ = try tc.pool(of: Int.self)
            }
        }
        #expect(engineOnly?.contains("make no engine calls") == true)
    }
}

@Suite("Engine output")
struct EngineOutputTests {
    @Test("goes to the output callback, statistics included")
    func callback() throws {
        let lines = Mutex<[String]>([])
        let settings = isolated.merging(Settings(testCases: 20, showStatistics: true))
        _ = try Property.run(
            settings: settings,
            output: { line in lines.withLock { $0.append(line) } }
        ) {
            tc in
            try tc.event(try tc.draw(.bool()) ? "yes" : "no")
        }
        let output = lines.withLock { $0 }
        #expect(output.contains { $0.hasPrefix("Statistics") })
        #expect(output.contains { $0.contains("* yes: ") })
    }
}

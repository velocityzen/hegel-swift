import Hegel
import HegelTesting
import Testing

/// A counter that wraps around at 3.
final class WrappingCounter {
    private(set) var value = 0

    func increment() {
        value = (value + 1) % 3
    }
}

struct CounterModel {
    var expected = 0
    let counter = WrappingCounter()
}

@Suite("state machines", .hegel(database: .disabled))
struct HegelStateMachineTests {
    @Test(.capturingIssues, .hegel)
    func expectationFailureStopsAtItsStep() throws {
        let machine = StateMachine<CounterModel>()
            .rule("increment") { model, _ in
                model.expected += 1
                model.counter.increment()
                #expect(model.counter.value == model.expected)
            }
        let issues = try capture {
            try property { tc in
                try machine.run(tc, from: CounterModel())
            }
        }
        #expect(issues.count == 1)
        let report = try #require(issues.first).commentText
        #expect(report.contains("Step 3: increment {"))
        #expect(!report.contains("Step 4"))
        #expect(report.contains("Rule increment failed:"))
    }

    @Test(.capturingIssues, .hegel)
    func invariantExpectationFailure() throws {
        let machine = StateMachine<CounterModel>()
            .rule("increment") { model, _ in
                model.expected += 1
                model.counter.increment()
            }
            .invariant("agrees", everyStep: true) { model, _ in
                #expect(model.counter.value == model.expected)
            }
        let issues = try capture {
            try property { tc in
                try machine.run(tc, from: CounterModel())
            }
        }
        #expect(issues.count == 1)
        let report = try #require(issues.first).commentText
        #expect(report.contains("Step 3: increment {"))
        #expect(report.contains("Invariant agrees failed:"))
    }

    @Test(.capturingIssues, .hegel)
    func asyncInvariantExpectation() async throws {
        let machine = StateMachine<CounterModel>()
            .rule("increment") { model, _ in
                model.expected += 1
                model.counter.increment()
            }
            .invariant("agrees", everyStep: true) { model, _ in
                await Task.yield()
                #expect(model.counter.value == model.expected)
            }
        let issues = try await capture {
            try await property { tc in
                try await machine.run(tc, from: CounterModel())
            }
        }
        #expect(issues.count == 1)
        #expect(try #require(issues.first).commentText.contains("Invariant agrees failed:"))
    }

    @Test(.capturingIssues, .hegel(Settings(nondeterminism: .quiet)))
    func concurrentExpectation() async throws {
        let machine = ConcurrentStateMachine<SharedTally>(concurrency: 2...2)
            .rule("bump") { tally, _ in
                await tally.bump()
            }
            .invariant("consistent", everyStep: true) { tally, _ in
                let (value, bumps) = await tally.snapshot
                #expect(value == bumps)
            }
        let issues = try await capture {
            try await property { tc in
                try await machine.run(tc, from: SharedTally())
            }
        }
        #expect(issues.count == 1)
        let report = try #require(issues.first).commentText
        #expect(report.contains("Round 1"))
        #expect(report.contains("[worker 1 "))
        #expect(report.contains("Invariant consistent failed:"))
    }
}

/// Loses a bump when two overlap, through actor reentrancy.
actor SharedTally {
    private var value = 0
    private var bumps = 0

    var snapshot: (Int, Int) { (value, bumps) }

    func bump() async {
        bumps += 1
        let read = value
        await Task.yield()
        value = read + 1
    }
}

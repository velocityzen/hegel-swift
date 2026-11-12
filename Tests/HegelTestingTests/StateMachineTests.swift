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
}

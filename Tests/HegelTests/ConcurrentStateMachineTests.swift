import Hegel
import Synchronization
import Testing

@Suite("Async state machines")
struct AsyncStateMachineTests {
    /// The stack machine of `StateMachineTests`, with an async rule.
    static let machine = StateMachine<StackModel>()
        .rule("push") { model, tc in
            let x = try tc.draw(.int(in: 0...100), named: "x")
            await Task.yield()
            model.expected.append(x)
            model.stack.push(x)
        }
        .rule("pop") { model, tc in
            try tc.assume(!model.expected.isEmpty)
            if model.stack.pop() != model.expected.removeLast() {
                throw Mismatch(description: "popped the wrong element")
            }
        }

    @Test("async rules run and shrink")
    func asyncRules() async throws {
        let outcome = try await Property.run(settings: isolated) { tc in
            try await Self.machine.run(tc, from: StackModel())
        }
        let drawn = try #require(outcome.failure).counterexamples[0].drawn
        #expect(drawn.filter { $0.hasSuffix(": push {") }.count == 3)
        #expect(drawn.last == "Rule pop failed:")
    }

    @Test("async invariants run")
    func asyncInvariants() async throws {
        let machine = StateMachine<Int>()
            .rule("count") { n, _ in n += 1 }
            .invariant("small", everyStep: true) { n, _ in
                await Task.yield()
                if n > 2 {
                    throw Failed()
                }
            }
        let outcome = try await Property.run(settings: isolated) { tc in
            try await machine.run(tc, from: 0)
        }
        let drawn = try #require(outcome.failure).counterexamples[0].drawn
        #expect(drawn.filter { $0.hasPrefix("Step") }.count == 3)
        #expect(drawn.last == "Invariant small failed:")
    }

    @Test("a machine with async rules can't run synchronously")
    func syncRunRefused() {
        #expect(throws: HegelError.self) {
            try Property.run(settings: isolated) { tc in
                try Self.machine.run(tc, from: StackModel())
            }
        }
    }
}

/// A counter whose increment loses updates when two overlap: actor
/// reentrancy lets another increment run during the suspension.
actor RacyCounter {
    private(set) var value = 0

    func increment() async {
        let read = value
        await Task.yield()
        value = read + 1
    }
}

final class CounterRig: Sendable {
    let counter = RacyCounter()
    let increments = Atomic<Int>(0)
}

/// Counts the rules running in each group, to check that groups that share
/// no rule never overlap.
final class GroupRig: Sendable {
    private let reading = Atomic<Int>(0)
    private let writing = Atomic<Int>(0)

    /// Runs for a few suspensions as a reader or a writer, failing if the
    /// other kind runs meanwhile.
    func hold(reading isReading: Bool) async throws {
        add(isReading ? 1 : 0, isReading ? 0 : 1)
        defer { add(isReading ? -1 : 0, isReading ? 0 : -1) }
        for _ in 0..<3 {
            await Task.yield()
            let other =
                isReading
                ? writing.load(ordering: .sequentiallyConsistent)
                : reading.load(ordering: .sequentiallyConsistent)
            if other != 0 {
                throw Overlap()
            }
        }
    }

    private func add(_ readers: Int, _ writers: Int) {
        reading.add(readers, ordering: .sequentiallyConsistent)
        writing.add(writers, ordering: .sequentiallyConsistent)
    }
}

struct Overlap: Error {}

@Suite("Concurrent state machines")
struct ConcurrentStateMachineTests {
    @Test("a race between workers is found and reported by round")
    func findsRace() async throws {
        let machine = ConcurrentStateMachine<CounterRig>(concurrency: 2...2)
            .rule("increment") { rig, _ in
                rig.increments.add(1, ordering: .relaxed)
                await rig.counter.increment()
            }
            .invariant("no lost updates", everyStep: true) { rig, _ in
                if await rig.counter.value != rig.increments.load(ordering: .relaxed) {
                    throw Failed()
                }
            }
        let settings = isolated.merging(Settings(nondeterminism: .quiet))
        let outcome = try await Property.run(settings: settings) { tc in
            try await machine.run(tc, from: CounterRig())
        }
        let drawn = try #require(outcome.failure).counterexamples[0].drawn
        #expect(drawn.contains("Concurrency level: 2"))
        #expect(drawn.contains { $0.hasPrefix("---------------- Round 1: group \"default\"") })
        #expect(drawn.contains { $0.hasPrefix("[worker 1 ") && $0.hasSuffix("Rule: increment {") })
        #expect(drawn.last == "Invariant no lost updates failed:")
    }

    @Test("rules that share no group never overlap")
    func groupsSeparate() async throws {
        let machine = ConcurrentStateMachine<GroupRig>(steps: 20, concurrency: 1...4)
            .rule("read", groups: ["reads"]) { rig, _ in try await rig.hold(reading: true) }
            .rule("write", groups: ["writes"]) { rig, _ in try await rig.hold(reading: false) }
        let outcome = try await Property.run(settings: isolated) { tc in
            try await machine.run(tc, from: GroupRig())
        }
        #expect(outcome.failure == nil)
    }

    @Test("workers draw values and reject rules without rejecting the test case")
    func workerDraws() async throws {
        let machine = ConcurrentStateMachine<CounterRig>(steps: 10, concurrency: 1...3)
            .rule("maybe") { rig, tc in
                let n = try tc.draw(.int(in: 0...9), named: "n")
                try tc.assume(n.isMultiple(of: 2))
                rig.increments.add(1, ordering: .relaxed)
            }
            .rule("never") { _, tc in try tc.reject() }
        let outcome = try await Property.run(settings: isolated) { tc in
            try await machine.run(tc, from: CounterRig())
        }
        #expect(outcome.failure == nil)
    }

    @Test("workers can add to and draw from a shared pool")
    func sharedPool() async throws {
        final class Rig: Sendable {
            let pool: Pool<Int>
            init(_ pool: Pool<Int>) { self.pool = pool }
        }
        let machine = ConcurrentStateMachine<Rig>(steps: 10, concurrency: 2...3)
            .rule("add") { rig, tc in
                try rig.pool.add(try tc.draw(.int(in: 0...9), named: "n"), using: tc)
            }
            .rule("take") { rig, tc in
                let n = try tc.draw(rig.pool.consumed, named: "n")
                if !(0...9).contains(n) {
                    throw Failed()
                }
            }
        let outcome = try await Property.run(settings: isolated) { tc in
            try await machine.run(tc, from: Rig(try tc.pool()))
        }
        #expect(outcome.failure == nil)
    }
}

import CHegel

/// A stateful test whose rules run at the same time, on several workers,
/// against one shared model: for finding races in code that is meant to be
/// used concurrently.
///
/// The run is split into rounds. In each round, the engine picks a
/// concurrency group, and each active worker runs a sequence of that
/// group's rules, at the same time as the others. Invariants are checked
/// between rounds, when no rule is running.
///
/// ```swift
/// final class Counter: Sendable { ... }  // the system under test
///
/// let counter = ConcurrentStateMachine<Counter>(concurrency: 2...4)
///     .rule("increment", groups: ["writes"]) { counter, _ in
///         await counter.increment()
///     }
///     .rule("read", groups: ["writes", "reads"]) { counter, _ in
///         _ = await counter.value
///     }
///     .invariant("never negative") { counter, _ in
///         #expect(await counter.value >= 0)
///     }
///
/// try await property { tc in
///     try await counter.run(tc, from: Counter())
/// }
/// ```
///
/// Rules in the same group may overlap; rules that share no group never
/// do. A rule in several groups runs in the rounds of each.
///
/// The model is shared by every worker, so it must be `Sendable`: an actor,
/// or a class that does its own locking. Each worker draws from its own
/// test case, and its lines in the report are prefixed with the worker and
/// the time they were printed.
///
/// A concurrent failure may not reproduce on every run. The engine notices
/// when a failure comes and goes, and handles it as the `nondeterminism`
/// setting says.
public struct ConcurrentStateMachine<Model: Sendable>: Sendable {
    /// The number of rounds the engine aims for in each test case.
    public var steps: Int
    /// How many workers may run rules at the same time. The engine picks a
    /// level in this range, favouring the top, and may change it between
    /// rounds.
    public var concurrency: ClosedRange<Int>

    var rules: [Rule] = []
    var invariants: [Invariant] = []

    struct Rule: Sendable {
        let name: String
        let groups: [String]
        let weight: Double
        let apply: @Sendable (Model, TestCase) async throws -> Void
    }

    struct Invariant: Sendable {
        let name: String
        let everyStep: Bool
        let check: @Sendable (Model, TestCase) async throws -> Void
    }

    /// A machine with no rules yet.
    ///
    /// - Parameters:
    ///   - steps: The number of rounds the engine aims for in each test case.
    ///   - concurrency: How many workers may run rules at the same time.
    public init(steps: Int = 50, concurrency: ClosedRange<Int> = 1...4) {
        precondition(steps >= 1, "a state machine needs at least one step")
        precondition(concurrency.lowerBound >= 1, "a state machine needs at least one worker")
        self.steps = steps
        self.concurrency = concurrency
    }

    /// Adds a rule.
    ///
    /// - Parameters:
    ///   - name: The rule's name in the report.
    ///   - groups: The concurrency groups the rule belongs to; at least one.
    ///     Rules with no group in common never run at the same time. By
    ///     default every rule is in one group, so any two may overlap.
    ///   - weight: How often the rule is chosen relative to the others in
    ///     its group: a hint, not a guarantee. Must be finite and positive.
    public func rule(
        _ name: String,
        groups: [String] = ["default"],
        weight: Double = 1,
        _ apply: @escaping @Sendable (_ model: Model, _ tc: TestCase) async throws -> Void
    ) -> ConcurrentStateMachine {
        precondition(!groups.isEmpty, "a rule needs at least one concurrency group")
        precondition(Set(groups).count == groups.count, "a rule's groups must not repeat")
        precondition(weight.isFinite && weight > 0, "a rule's weight must be finite and positive")
        var machine = self
        machine.rules.append(Rule(name: name, groups: groups, weight: weight, apply: apply))
        return machine
    }

    /// Adds an invariant, checked between rounds while no rule runs.
    ///
    /// Every invariant is checked on the initial and final states. Between
    /// rounds, the engine checks each one about once per test case, or after
    /// every round with `everyStep`.
    public func invariant(
        _ name: String,
        everyStep: Bool = false,
        _ check: @escaping @Sendable (_ model: Model, _ tc: TestCase) async throws -> Void
    ) -> ConcurrentStateMachine {
        var machine = self
        machine.invariants.append(Invariant(name: name, everyStep: everyStep, check: check))
        return machine
    }

    /// Runs the machine on `model` in test case `tc`.
    ///
    /// The report lists the rounds, and under each the rules every worker
    /// ran:
    ///
    /// ```
    /// Concurrency level: 2
    /// ---------------- Round 1: group "writes" ----------------
    /// [worker 0 +0.012ms] Rule: increment {
    /// [worker 0 +0.020ms] }
    /// [worker 1 +0.015ms] Rule: read {
    /// [worker 1 +0.031ms] }
    /// ```
    public func run(_ tc: TestCase, from model: Model) async throws {
        precondition(!rules.isEmpty, "a state machine needs at least one rule")
        var groupNames: [String] = []
        let declarations = rules.map { rule in
            RuleDeclaration(
                name: rule.name,
                weight: rule.weight,
                groups: rule.groups.map { group in
                    if let index = groupNames.firstIndex(of: group) {
                        return Int64(index)
                    }
                    groupNames.append(group)
                    return Int64(groupNames.count - 1)
                }
            )
        }
        let machine = try MachineHandle(
            tc,
            concurrency: concurrency,
            steps: steps,
            rules: declarations,
            invariants: invariants.map { ($0.name, $0.everyStep) }
        )

        if !invariants.isEmpty {
            tc.note("Checking invariants on the initial state.")
        }
        try await checkInvariants(model, tc, machine, sampling: false)

        var round = 0
        var notedLevel: Int?
        while let (group, level) = try machine.nextRound(tc) {
            guard groupNames.indices.contains(Int(group)) else {
                throw HegelError.engine("libhegel chose group \(group) of \(groupNames.count)")
            }
            round += 1
            if notedLevel != level {
                tc.note("Concurrency level: \(level)")
                notedLevel = level
            }
            tc.note(
                "---------------- Round \(round): group \"\(groupNames[Int(group)])\" ----------------"
            )
            // Every worker takes part in every round: the engine hands
            // inactive ones no rules.
            var clones: [Handoff<TestCase>] = []
            for worker in 0..<machine.concurrency {
                clones.append(Handoff(value: try tc.clone(worker: worker)))
            }
            let outcomes = await runRound(clones, model, machine)
            try resolveWorkers(outcomes, tc)
            try await checkInvariants(model, tc, machine, sampling: true)
        }

        if !invariants.isEmpty {
            tc.note("Checking invariants on the final state.")
        }
        try await checkInvariants(model, tc, machine, sampling: false)
    }

    /// Runs one round: every worker at once, each on its own test case.
    /// Returns each worker's outcome, in worker order.
    private func runRound(
        _ clones: [Handoff<TestCase>],
        _ model: Model,
        _ machine: MachineHandle
    ) async -> [WorkerOutcome] {
        await withTaskGroup(of: (Int, WorkerOutcome).self) { group in
            for (worker, clone) in clones.enumerated() {
                group.addTask {
                    (worker, await Self.work(worker, clone, model, rules, machine))
                }
            }
            var outcomes = [WorkerOutcome](repeating: .done, count: clones.count)
            for await (worker, outcome) in group {
                outcomes[worker] = outcome
            }
            return outcomes
        }
    }

    /// One worker's round: pull rules until the engine says the round is
    /// over, or one fails.
    @concurrent
    private static func work(
        _ worker: Int,
        _ handoff: Handoff<TestCase>,
        _ model: Model,
        _ rules: [Rule],
        _ machine: MachineHandle
    ) async -> WorkerOutcome {
        let tc = handoff.value
        do {
            while !tc.hasRecordedFailure(), let index = try machine.nextRule(tc, worker: worker) {
                guard rules.indices.contains(index) else {
                    throw HegelError.engine("libhegel chose rule \(index) of \(rules.count)")
                }
                let rule = rules[index]
                tc.note("Rule: \(rule.name) {")
                let block = try tc.block(indent: 2)
                do {
                    try await rule.apply(model, block)
                    tc.note("}")
                } catch TestCaseStop.rejected {
                    try machine.ruleRejected(tc, worker: worker)
                    block.note("Rule stopped early due to violated assumption.")
                    tc.note("}")
                } catch {
                    tc.note("}")
                    if !(error is TestCaseStop) {
                        tc.note("Rule \(rule.name) failed:")
                    }
                    throw error
                }
            }
            return tc.hasRecordedFailure() ? .recordedFailure : .done
        } catch TestCaseStop.rejected {
            return .rejected
        } catch TestCaseStop.overrun {
            return .overrun
        } catch let error as HegelError {
            return .engineError(error)
        } catch {
            return .failed(error)
        }
    }

    private func checkInvariants(
        _ model: Model,
        _ tc: TestCase,
        _ machine: MachineHandle,
        sampling: Bool
    ) async throws {
        for index in try machine.dueInvariants(tc, count: invariants.count, sampling: sampling) {
            let invariant = invariants[index]
            let trailer = "Invariant \(invariant.name) failed:"
            let block = try tc.block(indent: 2)
            var failure: (any Error)?
            do {
                try await invariant.check(model, block)
            } catch {
                failure = error
            }
            if let failure {
                try rethrowStepError(failure, trailer: trailer, root: tc, block: block)
            }
            if tc.hasRecordedFailure() {
                tc.note(trailer)
                throw StopAfterRecordedFailure()
            }
        }
    }
}

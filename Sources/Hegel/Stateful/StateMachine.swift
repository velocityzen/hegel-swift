import CHegel

/// A stateful test: a model, rules that act on it, and invariants that must
/// hold between them.
///
/// Each test case runs a sequence of rules the engine chooses. When a rule
/// or invariant fails, the sequence shrinks to the fewest, simplest steps
/// that still fail:
///
/// ```swift
/// struct Stack {
///     var model: [Int] = []
///     let real = MyStack()
/// }
///
/// let stack = StateMachine<Stack>()
///     .rule("push") { s, tc in
///         let x = try tc.draw(.int(), named: "x")
///         s.model.append(x)
///         s.real.push(x)
///     }
///     .rule("pop") { s, tc in
///         try tc.assume(!s.model.isEmpty)
///         #expect(s.real.pop() == s.model.removeLast())
///     }
///     .invariant("count") { s, _ in
///         #expect(s.real.count == s.model.count)
///     }
///
/// try property { tc in
///     try stack.run(tc, from: Stack())
/// }
/// ```
///
/// A machine is a value, like a generator: build it once and run it in as
/// many properties as you like. The model is a fresh copy for every test
/// case; put the system under test in it, created per run.
///
/// A rule that rejects its test case, with `assume`, `reject` or a draw
/// from an empty `Pool`, is skipped instead: the machine goes on to
/// another rule.
public struct StateMachine<Model>: Sendable {
    /// The number of steps the engine aims for in each test case.
    public var steps: Int

    var rules: [Rule] = []
    var invariants: [Invariant] = []

    struct Rule: Sendable {
        let name: String
        let weight: Double
        let apply: @Sendable (inout Model, TestCase) throws -> Void
    }

    struct Invariant: Sendable {
        let name: String
        let everyStep: Bool
        let check: @Sendable (Model, TestCase) throws -> Void
    }

    /// A machine with no rules yet, aiming for `steps` steps per test case.
    public init(steps: Int = 50) {
        precondition(steps >= 1, "a state machine needs at least one step")
        self.steps = steps
    }

    /// Adds a rule: a step that draws what it needs from its test case and
    /// changes the model.
    ///
    /// - Parameters:
    ///   - name: The rule's name in the report.
    ///   - weight: How often the rule is chosen relative to the others: a
    ///     hint, not a guarantee. Must be finite and positive.
    public func rule(
        _ name: String,
        weight: Double = 1,
        _ apply: @escaping @Sendable (_ model: inout Model, _ tc: TestCase) throws -> Void
    ) -> StateMachine {
        precondition(weight.isFinite && weight > 0, "a rule's weight must be finite and positive")
        var machine = self
        machine.rules.append(Rule(name: name, weight: weight, apply: apply))
        return machine
    }

    /// Adds an invariant: a check of the model.
    ///
    /// Every invariant is checked on the initial state and on the final
    /// state. Between steps, the engine checks each one about once per test
    /// case, at a step it chooses, or after every step with `everyStep`.
    /// Checking after every step finds a failure at the step that causes it,
    /// at the cost of running the check `steps` times as often.
    public func invariant(
        _ name: String,
        everyStep: Bool = false,
        _ check: @escaping @Sendable (_ model: Model, _ tc: TestCase) throws -> Void
    ) -> StateMachine {
        var machine = self
        machine.invariants.append(Invariant(name: name, everyStep: everyStep, check: check))
        return machine
    }

    /// Runs the machine from `model` in test case `tc`, and returns the
    /// final model.
    ///
    /// The report of a failing example lists the steps, each with what it
    /// drew:
    ///
    /// ```
    /// Step 1: push {
    ///   let x = 0
    /// }
    /// Step 2: pop {
    /// }
    /// Rule pop failed:
    /// ```
    @discardableResult
    public func run(_ tc: TestCase, from model: Model) throws -> Model {
        precondition(!rules.isEmpty, "a state machine needs at least one rule")
        let machine = try MachineHandle(tc, steps: steps, rules: rules, invariants: invariants)
        var model = model

        if !invariants.isEmpty {
            tc.note("Checking invariants on the initial state.")
        }
        try checkInvariants(model, tc, sampling: nil)

        var step = 0
        while true {
            try tc.startSpan(.stateMachineRule)
            guard try machine.nextRound(tc) else {
                try tc.stopSpan()
                break
            }
            var rejected = false
            // At concurrency 1 the engine hands out one rule per round, but
            // that is its policy, not the protocol: pull rules until the join
            // point.
            while let index = try machine.nextRule(tc) {
                guard rules.indices.contains(index) else {
                    throw HegelError.engine("libhegel chose rule \(index) of \(rules.count)")
                }
                let rule = rules[index]
                step += 1
                tc.note("Step \(step): \(rule.name) {")
                let stepCase = try tc.block(indent: 2)
                do {
                    try rule.apply(&model, stepCase)
                } catch TestCaseStop.rejected {
                    try machine.ruleRejected(tc)
                    rejected = true
                    stepCase.note("Rule stopped early due to violated assumption.")
                    tc.note("}")
                    continue
                } catch {
                    tc.note("}")
                    try fail("Rule \(rule.name) failed:", error, tc, stepCase)
                }
                tc.note("}")
                if tc.hasRecordedFailure() {
                    tc.note("Rule \(rule.name) failed:")
                    throw StopAfterRecordedFailure()
                }
            }
            try tc.stopSpan(discard: rejected)
            try checkInvariants(model, tc, sampling: machine)
        }

        if !invariants.isEmpty {
            tc.note("Checking invariants on the final state.")
        }
        try checkInvariants(model, tc, sampling: nil)
        return model
    }

    /// Checks the invariants the engine picks for this join point, or all
    /// of them without a machine to ask: the guaranteed checks of the
    /// initial and final states.
    private func checkInvariants(
        _ model: Model,
        _ tc: TestCase,
        sampling machine: MachineHandle?
    ) throws {
        for (index, invariant) in invariants.enumerated() {
            if let machine, try !machine.shouldCheckInvariant(tc, index: index) {
                continue
            }
            let checkCase = try tc.block(indent: 2)
            do {
                try invariant.check(model, checkCase)
            } catch {
                try fail("Invariant \(invariant.name) failed:", error, tc, checkCase)
            }
            if tc.hasRecordedFailure() {
                tc.note("Invariant \(invariant.name) failed:")
                throw StopAfterRecordedFailure()
            }
        }
    }

    /// Rethrows an error from a step or check, naming the step in the
    /// report unless the error only ends the test case.
    private func fail(
        _ trailer: String,
        _ error: any Error,
        _ tc: TestCase,
        _ block: TestCase
    ) throws -> Never {
        if let stop = block.stop {
            tc.stop = stop
        }
        if !(error is TestCaseStop) {
            tc.note(trailer)
        }
        throw error
    }
}

/// Ends a state machine run at the step where the test framework recorded
/// a failure. The recorded failure, not this error, is what gets reported.
struct StopAfterRecordedFailure: Error {}

/// `HEGEL_STATE_MACHINE_DONE`, which Swift can't import (`INT64_MIN`).
private let machineDone = Int64.min

/// A `hegel_state_machine_t`, driven sequentially: one worker, one group.
private final class MachineHandle {
    let raw: OpaquePointer

    init<Model>(
        _ tc: TestCase,
        steps: Int,
        rules: [StateMachine<Model>.Rule],
        invariants: [StateMachine<Model>.Invariant]
    ) throws {
        var handle: OpaquePointer?
        try tc.call { hegel_new_state_machine($0, tc.raw, 1, 1, Int64(steps), &handle) }
        guard let handle else {
            throw HegelError.engine("libhegel returned no state machine handle")
        }
        raw = handle
        let group: [Int64] = [0]
        for rule in rules {
            try rule.name.withHegelString { (name) throws in
                try group.withUnsafeBufferPointer { groups in
                    try tc.call {
                        hegel_state_machine_add_rule(
                            $0,
                            tc.raw,
                            handle,
                            name,
                            rule.weight,
                            groups.baseAddress,
                            groups.count
                        )
                    }
                }
            }
        }
        for invariant in invariants {
            try invariant.name.withHegelString { (name) throws in
                try tc.call {
                    hegel_state_machine_add_invariant($0, tc.raw, handle, name, invariant.everyStep)
                }
            }
        }
        var concurrency: Int64 = 0
        try tc.call { hegel_state_machine_start($0, tc.raw, handle, &concurrency) }
    }

    deinit {
        hegel_state_machine_free(nil, raw)
    }

    /// Starts the next round; false when the machine is done.
    func nextRound(_ tc: TestCase) throws -> Bool {
        var group: Int64 = 0
        var concurrency: Int64 = 0
        try tc.call { hegel_state_machine_next_group($0, tc.raw, raw, &group, &concurrency) }
        return group != machineDone
    }

    /// The next rule of this round, or nil at the round's end.
    func nextRule(_ tc: TestCase) throws -> Int? {
        var index: Int64 = 0
        try tc.call { hegel_state_machine_next_rule($0, tc.raw, raw, 0, &index) }
        return index == machineDone ? nil : Int(index)
    }

    func ruleRejected(_ tc: TestCase) throws {
        try tc.call { hegel_state_machine_rule_rejected($0, tc.raw, raw, 0) }
    }

    func shouldCheckInvariant(_ tc: TestCase, index: Int) throws -> Bool {
        var check = false
        try tc.call {
            hegel_state_machine_should_check_invariant($0, tc.raw, raw, Int64(index), &check)
        }
        return check
    }
}

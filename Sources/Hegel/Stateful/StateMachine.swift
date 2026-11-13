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
/// Rules and invariants may be `async`. A machine with any async ones runs
/// with `try await machine.run(tc, from:)`, in an async property.
///
/// A rule that rejects its test case, with `assume`, `reject` or a draw
/// from an empty `Pool`, is skipped instead: the machine goes on to
/// another rule.
///
/// For rules that run at the same time on a shared model, use
/// `ConcurrentStateMachine`.
public struct StateMachine<Model>: Sendable {
    /// The number of steps the engine aims for in each test case.
    public var steps: Int

    var rules: [Rule] = []
    var invariants: [Invariant] = []

    struct Rule: Sendable {
        let name: String
        let weight: Double
        let body: Body

        enum Body: Sendable {
            case sync(@Sendable (inout Model, TestCase) throws -> Void)
            case async(@Sendable (inout Model, TestCase) async throws -> Void)
        }
    }

    struct Invariant: Sendable {
        let name: String
        let everyStep: Bool
        let pauseFaults: Bool
        let body: Body

        enum Body: Sendable {
            case sync(@Sendable (Model, TestCase) throws -> Void)
            case async(@Sendable (Model, TestCase) async throws -> Void)
        }
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
        adding(Rule(name: name, weight: weight, body: .sync(apply)))
    }

    /// Adds an async rule. A machine with async rules runs with
    /// `try await run(_:from:)`.
    public func rule(
        _ name: String,
        weight: Double = 1,
        _ apply: @escaping @Sendable (_ model: inout Model, _ tc: TestCase) async throws -> Void
    ) -> StateMachine {
        adding(Rule(name: name, weight: weight, body: .async(apply)))
    }

    /// Adds an invariant: a check of the model.
    ///
    /// Every invariant is checked on the initial state and on the final
    /// state. Between steps, the engine checks each one about once per test
    /// case, at a step it chooses, or after every step with `everyStep`.
    /// Checking after every step finds a failure at the step that causes it,
    /// at the cost of running the check `steps` times as often.
    ///
    /// With `pauseFaults`, fault injection is paused while the invariant
    /// runs, so that inside Antithesis no fault lands in the middle of the
    /// check. Outside Antithesis it changes nothing. See
    /// `TestCase.withFaultsPaused(_:)`.
    public func invariant(
        _ name: String,
        everyStep: Bool = false,
        pauseFaults: Bool = false,
        _ check: @escaping @Sendable (_ model: Model, _ tc: TestCase) throws -> Void
    ) -> StateMachine {
        adding(
            Invariant(
                name: name,
                everyStep: everyStep,
                pauseFaults: pauseFaults,
                body: .sync(check)
            )
        )
    }

    /// Adds an async invariant. A machine with async invariants runs with
    /// `try await run(_:from:)`.
    public func invariant(
        _ name: String,
        everyStep: Bool = false,
        pauseFaults: Bool = false,
        _ check: @escaping @Sendable (_ model: Model, _ tc: TestCase) async throws -> Void
    ) -> StateMachine {
        adding(
            Invariant(
                name: name,
                everyStep: everyStep,
                pauseFaults: pauseFaults,
                body: .async(check)
            )
        )
    }

    private func adding(_ rule: Rule) -> StateMachine {
        precondition(
            rule.weight.isFinite && rule.weight > 0,
            "a rule's weight must be finite and positive"
        )
        var machine = self
        machine.rules.append(rule)
        return machine
    }

    private func adding(_ invariant: Invariant) -> StateMachine {
        var machine = self
        machine.invariants.append(invariant)
        return machine
    }

    /// Whether any rule or invariant is async.
    var isAsync: Bool {
        rules.contains {
            if case .async = $0.body { true } else { false }
        }
            || invariants.contains {
                if case .async = $0.body { true } else { false }
            }
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
    ///
    /// A machine with async rules or invariants throws a usage error here;
    /// run it with `try await`.
    @discardableResult
    public func run(_ tc: TestCase, from model: Model) throws -> Model {
        guard !isAsync else {
            throw HegelError.usage(
                "this state machine has async rules or invariants; run it with `try await machine.run(tc, from:)`"
            )
        }
        let run = try SequentialRun(self, tc)
        var model = model
        try checkInvariants(model, run, sampling: false)
        while try run.beginRound() {
            while let (rule, block) = try run.nextStep() {
                guard case .sync(let apply) = rule.body else {
                    preconditionFailure("async rule in a sync run")
                }
                var failure: (any Error)?
                do {
                    try apply(&model, block)
                } catch {
                    failure = error
                }
                try run.finishStep(rule, block, failure)
            }
            try run.endRound()
            try checkInvariants(model, run, sampling: true)
        }
        try checkInvariants(model, run, sampling: false, final: true)
        return model
    }

    /// Runs the machine from `model` in test case `tc`, awaiting its async
    /// rules and invariants, and returns the final model.
    @discardableResult
    public func run(_ tc: TestCase, from model: Model) async throws -> Model {
        let run = try SequentialRun(self, tc)
        var model = model
        try await checkInvariants(model, run, sampling: false)
        while try run.beginRound() {
            while let (rule, block) = try run.nextStep() {
                var failure: (any Error)?
                do {
                    switch rule.body {
                        case .sync(let apply): try apply(&model, block)
                        case .async(let apply): try await apply(&model, block)
                    }
                } catch {
                    failure = error
                }
                try run.finishStep(rule, block, failure)
            }
            try run.endRound()
            try await checkInvariants(model, run, sampling: true)
        }
        try await checkInvariants(model, run, sampling: false, final: true)
        return model
    }

    private func checkInvariants(
        _ model: Model,
        _ run: SequentialRun<Model>,
        sampling: Bool,
        final: Bool = false
    ) throws {
        for invariant in try run.dueInvariants(sampling: sampling, final: final) {
            guard case .sync(let check) = invariant.body else {
                preconditionFailure("async invariant in a sync run")
            }
            let block = try run.tc.block(indent: 2)
            try run.startCheck(invariant)
            var failure: (any Error)?
            do {
                try check(model, block)
            } catch {
                failure = error
            }
            try run.finishCheck(invariant, block, failure)
        }
    }

    private func checkInvariants(
        _ model: Model,
        _ run: SequentialRun<Model>,
        sampling: Bool,
        final: Bool = false
    ) async throws {
        for invariant in try run.dueInvariants(sampling: sampling, final: final) {
            let block = try run.tc.block(indent: 2)
            try run.startCheck(invariant)
            var failure: (any Error)?
            do {
                switch invariant.body {
                    case .sync(let check): try check(model, block)
                    case .async(let check): try await check(model, block)
                }
            } catch {
                failure = error
            }
            try run.finishCheck(invariant, block, failure)
        }
    }
}

/// The bookkeeping of one sequential run, shared by the sync and async
/// runners: rounds, step headings, rejected steps, and failures.
final class SequentialRun<Model> {
    let tc: TestCase
    private let machine: MachineHandle
    private let rules: [StateMachine<Model>.Rule]
    private let invariants: [StateMachine<Model>.Invariant]
    private var step = 0
    private var roundRejected = false

    init(_ definition: StateMachine<Model>, _ tc: TestCase) throws {
        precondition(!definition.rules.isEmpty, "a state machine needs at least one rule")
        self.tc = tc
        rules = definition.rules
        invariants = definition.invariants
        machine = try MachineHandle(
            tc,
            concurrency: 1...1,
            steps: definition.steps,
            rules: rules.map { RuleDeclaration(name: $0.name, weight: $0.weight, groups: [0]) },
            invariants: invariants.map { ($0.name, $0.everyStep) }
        )
        if !invariants.isEmpty {
            tc.note("Checking invariants on the initial state.")
        }
    }

    /// Starts a round; false when the machine is done.
    func beginRound() throws -> Bool {
        try tc.startSpan(.stateMachineRule)
        guard try machine.nextRound(tc) != nil else {
            try tc.stopSpan()
            return false
        }
        roundRejected = false
        return true
    }

    /// The next rule of the round, with the block handle it runs on, or
    /// nil at the round's end. At concurrency 1 the engine hands out one
    /// rule per round, but that is its policy, not the protocol.
    func nextStep() throws -> (StateMachine<Model>.Rule, TestCase)? {
        guard let index = try machine.nextRule(tc) else {
            return nil
        }
        guard rules.indices.contains(index) else {
            throw HegelError.engine("libhegel chose rule \(index) of \(rules.count)")
        }
        let rule = rules[index]
        step += 1
        tc.note("Step \(step): \(rule.name) {")
        return (rule, try tc.block(indent: 2))
    }

    /// Closes a step that returned or threw `error`.
    func finishStep(_ rule: StateMachine<Model>.Rule, _ block: TestCase, _ error: (any Error)?)
        throws
    {
        switch error {
            case nil:
                tc.note("}")
                if tc.hasRecordedFailure() {
                    tc.note("Rule \(rule.name) failed:")
                    throw StopAfterRecordedFailure()
                }
            case TestCaseStop.rejected?:
                try machine.ruleRejected(tc)
                roundRejected = true
                block.note("Rule stopped early due to violated assumption.")
                tc.note("}")
            case let error?:
                tc.note("}")
                try rethrowStepError(
                    error,
                    trailer: "Rule \(rule.name) failed:",
                    root: tc,
                    block: block
                )
        }
    }

    func endRound() throws {
        try tc.stopSpan(discard: roundRejected)
    }

    func dueInvariants(sampling: Bool, final: Bool) throws -> [StateMachine<Model>.Invariant] {
        if final, !invariants.isEmpty {
            tc.note("Checking invariants on the final state.")
        }
        return try machine.dueInvariants(tc, count: invariants.count, sampling: sampling)
            .map { invariants[$0] }
    }

    /// Opens an invariant check: pauses fault injection for one declared
    /// with `pauseFaults`.
    func startCheck(_ invariant: StateMachine<Model>.Invariant) throws {
        if invariant.pauseFaults {
            try tc.pauseFaults()
        }
    }

    /// Closes an invariant check that returned or threw `error`. Resumes
    /// fault injection first; when the check failed, its failure is the
    /// one reported even if resuming fails too.
    func finishCheck(
        _ invariant: StateMachine<Model>.Invariant,
        _ block: TestCase,
        _ error: (any Error)?
    ) throws {
        if invariant.pauseFaults {
            if error == nil {
                try tc.unpauseFaults()
            } else {
                try? tc.unpauseFaults()
            }
        }
        let trailer = "Invariant \(invariant.name) failed:"
        if let error {
            try rethrowStepError(error, trailer: trailer, root: tc, block: block)
        }
        if tc.hasRecordedFailure() {
            tc.note(trailer)
            throw StopAfterRecordedFailure()
        }
    }
}

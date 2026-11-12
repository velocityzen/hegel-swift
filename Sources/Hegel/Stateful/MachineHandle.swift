import CHegel

/// `HEGEL_STATE_MACHINE_DONE`, which Swift can't import (`INT64_MIN`).
private let machineDone = Int64.min

/// A rule as the engine sees it.
struct RuleDeclaration {
    let name: String
    let weight: Double
    /// The concurrency groups the rule belongs to, as group ids.
    let groups: [Int64]
}

/// A `hegel_state_machine_t`: the engine's choice of rules, rounds and
/// invariant checks. Its state is shared by every handle of the test case,
/// so workers on other threads may ask it for their rules.
final class MachineHandle: @unchecked Sendable {
    let raw: OpaquePointer
    /// How many workers to run, each pulling rules with its own index.
    let concurrency: Int

    init(
        _ tc: TestCase,
        concurrency: ClosedRange<Int>,
        steps: Int,
        rules: [RuleDeclaration],
        invariants: [(name: String, everyStep: Bool)]
    ) throws {
        var handle: OpaquePointer?
        try tc.call {
            hegel_new_state_machine(
                $0,
                tc.raw,
                Int64(concurrency.lowerBound),
                Int64(concurrency.upperBound),
                Int64(steps),
                &handle
            )
        }
        guard let handle else {
            throw HegelError.engine("libhegel returned no state machine handle")
        }
        raw = handle
        for rule in rules {
            try rule.name.withHegelString { (name) throws in
                try rule.groups.withUnsafeBufferPointer { groups in
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
        var workers: Int64 = 0
        try tc.call { hegel_state_machine_start($0, tc.raw, handle, &workers) }
        self.concurrency = Int(workers)
    }

    deinit {
        hegel_state_machine_free(nil, raw)
    }

    /// Starts the next round, on the root handle: its group and how many
    /// workers are active in it, or nil when the machine is done.
    func nextRound(_ tc: TestCase) throws -> (group: Int64, level: Int)? {
        var group: Int64 = 0
        var level: Int64 = 0
        try tc.call { hegel_state_machine_next_group($0, tc.raw, raw, &group, &level) }
        return group == machineDone ? nil : (group, Int(level))
    }

    /// The next rule for `worker` this round, or nil at the round's end.
    func nextRule(_ tc: TestCase, worker: Int = 0) throws -> Int? {
        var index: Int64 = 0
        try tc.call { hegel_state_machine_next_rule($0, tc.raw, raw, Int64(worker), &index) }
        return index == machineDone ? nil : Int(index)
    }

    func ruleRejected(_ tc: TestCase, worker: Int = 0) throws {
        try tc.call { hegel_state_machine_rule_rejected($0, tc.raw, raw, Int64(worker)) }
    }

    /// Whether to check invariant `index` at this join point. Call on the
    /// root handle.
    func shouldCheckInvariant(_ tc: TestCase, index: Int) throws -> Bool {
        var check = false
        try tc.call {
            hegel_state_machine_should_check_invariant($0, tc.raw, raw, Int64(index), &check)
        }
        return check
    }

    /// The indices of the invariants to check at this join point: all of
    /// them for the guaranteed checks of the initial and final states, or
    /// the ones the engine picks between steps.
    func dueInvariants(_ tc: TestCase, count: Int, sampling: Bool) throws -> [Int] {
        guard sampling else {
            return Array(0..<count)
        }
        return try (0..<count).filter { try shouldCheckInvariant(tc, index: $0) }
    }
}

/// Ends a state machine run at the step where the test framework recorded
/// a failure. The recorded failure, not this error, is what gets reported.
struct StopAfterRecordedFailure: Error {}

/// Rethrows an error from a step or check, after naming the step in the
/// report, unless the error only ends the test case. A stop the block
/// handle saw becomes the root's, which reports the case.
func rethrowStepError(
    _ error: any Error,
    trailer: String,
    root: TestCase,
    block: TestCase
) throws -> Never {
    if let stop = block.stop {
        root.stop = stop
    }
    if !(error is TestCaseStop) {
        root.note(trailer)
    }
    throw error
}

/// Lets a value that is only ever used by one task at a time cross into
/// the task that uses it.
struct Handoff<Value>: @unchecked Sendable {
    let value: Value
}

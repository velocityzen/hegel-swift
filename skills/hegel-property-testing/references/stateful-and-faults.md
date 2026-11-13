# Stateful tests, injected faults, concurrency and cancellation

## Goal

Drive a stateful system through long, varied operation sequences — including failures,
interleavings and cancellation — while checking it continuously against a model. A `StateMachine`
does this on its own: one value that generates operations, applies them, tracks what happened and
checks the result, with the engine choosing the order and shrinking a failure to the fewest,
simplest steps.

## Designing a state machine

**The model holds the system and what it's checked against.** Create the system under test in the
model passed to `run`, so every test case starts fresh. Keep a reference model (a dictionary, an
array, a set of acknowledged writes) beside it.

**Rules cover the whole surface.** Every public operation gets a rule, including the easy-to-forget
ones — configuration changes, bulk operations, reset, close and reopen — which interact with
state and hide bugs.

**Rules check what they did.** Compare the operation's result with the model inside the rule.
Register cheap invariants with `everyStep: true`; the rest are sampled about once per case, and
always on the initial and final state.

**Rules don't over-assume.** A rule that rejects (`assume`, `reject`, a draw from an empty pool) is
skipped. That is right for a true precondition — the API traps, or the test can't express the call.
It is wrong for "the system probably handles this badly": then the rule should run and expect the
documented result.

```swift
.rule("pop") { s, tc in
    if s.model.isEmpty {
        #expect(s.real.pop() == nil)            // documented: empty pop returns nil
    } else {
        #expect(s.real.pop() == s.model.removeLast())
    }
}
```

**Draw the starting point and the configuration.** Starting empty every time misses bugs in
transitions out of populated or dirty states. Draw initial contents, capacities and thresholds into
the model:

```swift
try property { tc in
    let capacity = try tc.draw(.element(of: [1, 2, 16]), named: "capacity")
    let seed = try tc.draw(.array(of: .int(), count: 0...(capacity * 2)), named: "initial")
    try queue.run(tc, from: QueueModel(capacity: capacity, initial: seed))
}
```

**Handles go in pools.** IDs, keys, open handles and accounts that later rules act on belong in a
`Pool`, so the engine picks — and shrinks — which one a step uses. Also draw operations on handles
that don't exist or were already closed when the API promises to handle them.

**Weights and steps.** The engine swarms rules per worker and treats `weight:` as a hint. Use
weights for a real need (setup operations that must be rarer than reads), not to tune toward a
guessed bug. `steps:` sets the target length (50 by default); raise it for bugs that need
accumulated state.

## Faults by injection

Hegel can't kill processes or partition networks; it can drive a test double that fails exactly
when a drawn plan says so. Translate each fault into the dependency the code calls:

| Fault | In-process equivalent |
|---|---|
| Dependency unavailable | the double throws the dependency's error before acting |
| Lost acknowledgement | the double applies the call, then throws — the caller can't know it succeeded |
| Slow dependency, timeout | an injected clock the test advances; a drawn delay per call; never a real `sleep` |
| Crash and restart | a rule that rebuilds the system from its persisted state, dropping in-memory state |
| Clock skew | the injected clock jumps forward or back by drawn amounts |
| Partial failure | a separate plan per dependency, so some fail while others work |

**Draw the plan up front.** A `TestCase` belongs to the property body: don't hand it to the code
under test or to another thread. Draw a plan, give it to the double, and let the double consult it
by call number. The plan shrinks toward no faults, so the minimal example lists exactly which calls
had to fail:

```swift
struct FaultPlan: Sendable {
    var failBefore: Set<Int> = []  // calls that fail without effect
    var failAfter: Set<Int> = []   // calls that take effect, then report failure
}

let faultPlans = Gen<FaultPlan> { tc in
    FaultPlan(
        failBefore: try tc.draw(.set(of: .int(in: 0...40))),
        failAfter: try tc.draw(.set(of: .int(in: 0...40)))
    )
}

final class FlakyDisk: Disk {
    let base: Disk
    let plan: FaultPlan
    private var call = 0
    private var healed = false

    init(base: Disk, plan: FaultPlan) {
        self.base = base
        self.plan = plan
    }

    /// Stops injecting faults.
    func heal() { healed = true }

    func write(_ page: Page) throws {
        defer { call += 1 }
        if !healed, plan.failBefore.contains(call) { throw DiskError.unavailable }
        try base.write(page)
        if !healed, plan.failAfter.contains(call) { throw DiskError.unavailable }
    }
}
```

Swarm the plan too when it helps: `.oneOf(.just(FaultPlan()), faultPlans)` keeps a share of
fault-free cases, and a drawn rate band gives some cases rare faults and others constant ones.

**Track attempts and acknowledgements, and check bounds.** Under faults the test can't know whether
an unacknowledged write landed. Record both, and check that the system lies between them — see
"Bounds, not exact values" in [oracles.md](oracles.md):

```swift
let journalMachine = StateMachine<JournalModel>()
    .rule("append") { s, tc in
        let record = try tc.draw(records, named: "record")
        s.attempted.insert(record)
        do {
            try s.journal.append(record)
            s.acknowledged.insert(record)
            try tc.event("append acknowledged")
        } catch DiskError.unavailable {
            try tc.event("append failed")
        }
    }
    .rule("crash and restart") { s, _ in
        s.journal = try Journal(recoveringFrom: s.disk)  // memory lost, disk kept
    }
    .invariant("acknowledged ⊆ stored ⊆ attempted", everyStep: true) { s, _ in
        let stored = Set(s.journal.records())
        #expect(stored.isSuperset(of: s.acknowledged), "lost an acknowledged record")
        #expect(stored.isSubset(of: s.attempted), "stored a record never written")
    }
```

**Retries are inputs.** A retry after a lost acknowledgement can expose a real idempotency bug; a
retry of an operation the API never promised was safe to repeat creates false failures. Decide what
the code promises before the test retries anything.

**Design rules toward goals, not procedures.** Track progress against what the system acknowledged,
not how many times the test tried.

## Liveness: heal, then check

"Eventually converges" becomes: run under faults, stop the faults, give the system a bounded amount
of progress, and check. `run` returns the final model, so healing and the check go after it:

```swift
try property { tc in
    let disk = FlakyDisk(base: MemoryDisk(), plan: try tc.draw(faultPlans, named: "faults"))
    let model = try journalMachine.run(tc, from: JournalModel(disk: disk))
    disk.heal()                     // stop injecting faults
    try model.journal.recover()     // the bounded progress the system is promised
    #expect(Set(model.journal.records()).isSuperset(of: model.acknowledged))
}
```

Pair it with reach claims that faults actually happened and that recovery ran with work pending —
otherwise the liveness check passes on fault-free runs.

## Concurrency

- **`ConcurrentStateMachine`** runs rules on several workers at once against one shared `Sendable`
  model (an actor, or a class with its own locking). Rules that share a concurrency group may
  overlap; rules with no group in common never do. Put rules you suspect race into a shared group,
  and keep a group where readers run alone to separate read bugs from write bugs.
- **Invariants run between rounds**, while no rule runs: that is where exact checks belong. A value
  read *during* a round may legitimately reflect either side of a concurrent write — check it
  against a bound.
- **Actor reentrancy** is the classic Swift race: state read before an `await` inside an actor
  method can be stale after it. Rules that call methods with internal suspension points, in one
  group, are how to reach it.
- **`tc.concurrently(workers:)`** runs one body on several threads with independent choice streams.
  Draw the worker count, and give workers their own drawn policies and a drawn amount of key
  overlap.
- **Races don't reproduce every time.** Hegel controls the choices, not the scheduler. The engine
  confirms a failure that comes and goes and handles it as `nondeterminism` says (`.quiet` and
  `.warn` report it once confirmed; `.error` fails the run). Raise the case count for race hunting
  (`HEGEL_TEST_CASES=10000`), and expect a reproduce blob to need several replays.

## Cancellation

`tc.withRandomCancellation` cancels the body's task right after a drawn checkpoint. Place
`cancellation.checkpoint()` wherever a cancel is interesting — usually in callbacks you hand to the
code under test — and pass `checkpoints: 0...count` when the count is known, so every cancel lands
on one.

Properties worth checking after a cancelled run: everything acquired was released; state is either
fully applied or fully rolled back; the cancellation was observed by code after the cancel point
(`run.isCancelled(after: n)`); no work continued after the task finished. The body can't draw:
draw everything first. A failure shrinks to the earliest checkpoint that still fails, or to no
cancel at all when the bug doesn't need one.

## Stalls

A hang is how async code usually fails, and a test case that never returns can't be reported or
shrunk. Wrap async work under test in `tc.withStallDetection(after:)`, and call `heartbeat.beat()`
at each step of progress: a read, a finished transform, a delivered value. Beat from the code
under test's callbacks, not from a timer, or a stuck system still looks alive.

- A stall throws `Stalled` and cancels the work's task. There's no need for
  `#require(…, "stalled")` at the call site.
- Pick the limit for a busy CI machine, a few seconds for millisecond steps. Shrinking doesn't pay
  it per candidate: after the first stall, candidates get 4 times the longest beat gap of passing
  cases, so a generous limit is cheap.
- Beat at every step. If a passing case goes a long time without a beat, the shortened limit is
  long too, and so is shrinking.
- The body runs in its own task and can't draw. Draw inputs first.

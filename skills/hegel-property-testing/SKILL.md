---
name: hegel-property-testing
description: >-
  Best practices for designing, writing, reviewing and validating property-based tests with
  hegel-swift (Gen, property, TestCase, StateMachine, ConcurrentStateMachine, Pool, repeat,
  concurrently, withRandomCancellation, CancellationProbe, withStallDetection). Use when writing Hegel properties for a feature or type,
  choosing or reviewing generators, modeling a stateful, failing or concurrent API, reviewing an
  existing property suite for weak inputs or weak checks, investigating a shrunk counterexample,
  or checking that a property would actually catch a bug.
---

# Hegel property testing

A property test finds a bug only if two things hold: the generators drive the code into the state
where the bug lives, and a check notices when it happens. Hegel explores, shrinks and replays; it
can't widen a generator you narrowed or tighten a check you wrote loosely. This skill is about
those two levers — **exploration** (what gets drawn) and **the oracle** (what gets checked) — and
about proving both work instead of trusting a green run.

## Core principles

1. **Properties drive the test.** Every draw, generator and check serves a named property. A
   property is specific and checkable: not "test the cache" but "after `put(k, v)` with no later
   write to `k`, `get(k)` returns `v`". Ask: what exact condition would I `#expect`? If you can't
   answer, the property isn't ready.
2. **A green property is negative evidence.** It says nothing bad was observed — not that the
   check would have noticed. Confirm the test _reaches_ its interesting states (events, reach
   counters) and, for the properties that matter most, that a realistic bug makes it fail
   (mutation check).
3. **All randomness goes through `tc.draw`.** `Int.random`, `UUID()`, `Date()`, shuffles and
   unseeded generators break shrinking, replay and the failure database. Inject clocks, ID
   sources and random generators into the code under test, and drive them from draws.
4. **Randomize the policy per test case, not just the choices.** A fixed mix of operations
   explores the same macro behavior every time. Draw the policy itself — key-space size, fault
   rate, which operations exist, initial state size, capacity, worker count — at the top of the
   test case. Some cases go deep into one corner; the union covers the space (swarm testing).
5. **Draw from menus around the code's real limits.** Uniform ranges rarely hit `capacity`,
   `capacity + 1` or `pageSize`. Mix a menu of boundary values and configured-limit families
   with the full domain.
6. **Check continuously, not only at the end.** Bugs can cancel out before a final check, and a
   long history between cause and detection makes the minimal example harder to read. Check in
   the rule that acts, or with `invariant(..., everyStep: true)`.
7. **Each check site is its own bug.** Hegel groups failures by origin: the source location of
   the first issue, or the type of a thrown error. Distinct checks shrink and report separately;
   checks funneled through one helper `#expect` collapse into one bug.
8. **Claimed guarantees are claims to test; bug reports are leads.** Doc comments and READMEs
   become properties — never write that a guarantee holds. A bug report earns a property only
   after you confirm the defect from primary evidence.
9. **Test cases are deterministic and independent.** Same choices, same behavior: fresh system
   under test per case, no shared mutable state, no wall clock, no ordering that depends on
   per-process hash seeds.
10. **A failure is a candidate, not a conclusion.** Explain the minimal example step by step and
    classify it — real bug, oracle bug, test bug, or environment — before fixing anything.

## Picking the construct

| What you're testing                                                    | Use                                                                                    |
| ---------------------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| A function or value transform                                          | `property { tc in ... }` with named draws                                              |
| A sequence of operations with no state-dependent inputs                | `.array(of: op)` folded over the system and a model; `tc.repeat` only for a cheap body |
| Operations whose inputs depend on earlier results (handles, keys, IDs) | `StateMachine` with a model, plus `Pool`                                               |
| Thread safety, actor reentrancy, races                                 | `ConcurrentStateMachine`, or `tc.concurrently(workers:)`                               |
| Cancellation handling and cleanup                                      | `tc.withRandomCancellation(endsWithin:stallsAfter:)` and a `CancellationProbe`         |
| Async code that can hang: lost wakeups, deadlocks                      | `tc.withStallDetection(after:)` around the work, with `heartbeat.beat()` per step      |
| Failing dependencies, lost acknowledgements, crash and restart         | a test double driven by a drawn fault schedule, inside a `StateMachine`                |

Details and patterns: [references/stateful-and-faults.md](references/stateful-and-faults.md).

## Workflows

### Write properties for a feature or type

1. **Orient.** Read the code the feature touches: its public API, the state it keeps, its
   concurrency (actors, locks, `Sendable` boundaries), its error paths, the limits it is
   configured with (capacities, timeouts, batch sizes), and its recent fixes (`git log -p` on
   the files). Read doc comments for claimed guarantees.
2. **Discover properties** with the attention focuses in
   [references/property-discovery.md](references/property-discovery.md). Write each one down —
   a doc comment on its `@Test`, or a small catalog for a larger effort. For each property also
   name the reach claims: the states the test must visit for the property to be exercised.
3. **Choose the oracle** for each property: what is compared, at which site, as an invariant,
   an optional-path check, a forbidden path or a bound —
   [references/oracles.md](references/oracles.md).
4. **Build the generators**: menus, per-test-case policy, absent and empty values, related fields
   — [references/generators.md](references/generators.md).
5. **Write the test** following the conventions below.
6. **Check reach before trusting green.** Run with statistics
   (`HEGEL_STATISTICS=1 swift test --filter <TestName>`) and confirm every reach claim's event
   occurs in a healthy share of cases, then list those events in `property(reaching:)` so a
   regression fails the test. Fix generators first; a property that never reaches its state
   passes vacuously.
7. **Mutation-check** the properties that matter most —
   [references/mutation-check.md](references/mutation-check.md).
8. **Run deep once** before calling it done: `HEGEL_TEST_CASES=10000 swift test --filter <Suite>`.
   The variable wins over a test's own `.hegel(testCases:)`, so every property runs deep.

For a feature still in development, write properties for the planned behavior too and mark those
tests `.disabled("waiting on <part>")`. Enable each as its code lands; delete properties the
feature no longer has instead of leaving them disabled.

### Review an existing property suite

Read-only: produce a report, change nothing. Read the tests and their generators, then check two
axes:

- **Exploration** — the anti-pattern catalog in [references/generators.md](references/generators.md).
- **Oracle** — the anti-rules in [references/oracles.md](references/oracles.md).

Structure the report as: (1) what the suite does, in your words, so the user can correct your
model; (2) findings by tier — _high signal_ (a whole region is unreachable: hardcoded values, an
`assume` that excludes the error path, a fixed loop), _worth considering_, _observation_; (3) what
already works well. Make each finding concrete: "the `pop` rule assumes a non-empty stack, so
`pop` on an empty stack is never tested" — not "over-filtering". Frame findings as state space
not yet reached, not as defects. When severity depends on domain knowledge you don't have
("this range is 0...100; I don't know what the API accepts"), state the fact and ask.

### Investigate a failing property

[references/failures.md](references/failures.md): read the minimal example, explain the mechanism,
classify, fix, and keep a durable regression.

### Check that a property would catch a bug

[references/mutation-check.md](references/mutation-check.md): one realistic mutant per safety
property, a predicted kill chain, and a diagnosis for every survivor. The working tree must end
with no mutation in it.

## Conventions

- Put `.hegel` on the test or suite, after any other issue-handling trait. `@Suite(.hegel)`
  applies to every test in it; a test's own `.hegel(...)` overrides field by field.
- Give each `@Test` a doc comment stating its property in one sentence.
- Name every draw (`named:`, or `#draw` on Swift 6.4+, where it takes the binding's name): the
  report shows `let name = value`, and explicit examples are keyed by these names.
- Let draw errors propagate. `try?` or a catch-all around a draw swallows rejection and overrun
  and turns them into wrong values.
- Create the system under test inside the test case (or in the model passed to `run`). Never
  share it, a singleton, or a static cache across test cases.
- Keep the body cheap: a passing `repeat` runs until the budget is used, often thousands of
  iterations. Lower `testCases` for an expensive property rather than shrinking its domain;
  a deep run's `HEGEL_TEST_CASES` still overrides it.
- Keep generated inputs inside the API's trap contract. A `precondition`, `fatalError` or
  force-unwrap reached by a generated input kills the test process: Hegel can't catch it or
  shrink it. Inputs that should produce an error belong in the property; inputs documented to
  trap belong to a separate, non-property test.
- Use `tc.note(...)` for context that isn't a draw (model state, a debug dump). Use
  `printed(with:)` for values that print badly or are secret.
- Keep `.hegel/` in `.gitignore`. Commit a `hegel.toml` with a deeper profile for scheduled runs:

  ```toml
  [profiles.nightly]
  test_cases = 10_000
  derandomize = false
  ```

  Select it with `HEGEL_DEFAULT_PROFILE=nightly swift test`. The shipped `ci` profile is
  derandomized: CI sees the same inputs every run, so new inputs come only from local and
  scheduled runs.

- Don't suppress a health check to make a test pass. Fix the generator; suppress only with a
  comment saying why the check is wrong for this test.

## Self-review

Before calling the work done — with a fresh-context sub-agent if available — check:

- Every test states a specific property and checks it; no test only "runs the code".
- No randomness bypasses `tc.draw`. No range is narrower than the API's contract without a stated
  reason. Configured limits have menus. Policy is drawn per test case where the test has a policy.
  Empty, absent and boundary values are reachable.
- Every reach claim is an event listed in `property(reaching:)`, observed in a statistics run.
- Checks live at distinct sites; helpers forward `sourceLocation`; bounds are used wherever the
  test can't know the exact outcome; no reach claim is the negation of a check.
- State machine rules don't `assume` away inputs the system should handle; cheap invariants run
  `everyStep`.
- Test cases are independent and deterministic.
- The most important safety properties were mutation-checked, and the tree carries no mutant.
- Every fixed failure is kept as an explicit example.
- No health check is suppressed without a reason.

## Reference files

| Reference                                                              | Read when                                                   |
| ---------------------------------------------------------------------- | ----------------------------------------------------------- |
| [references/property-discovery.md](references/property-discovery.md)   | Finding and recording properties for a feature              |
| [references/generators.md](references/generators.md)                   | Building generators; reviewing a suite's inputs             |
| [references/oracles.md](references/oracles.md)                         | Writing checks and reach claims; reviewing a suite's checks |
| [references/stateful-and-faults.md](references/stateful-and-faults.md) | State machines, injected faults, concurrency, cancellation  |
| [references/failures.md](references/failures.md)                       | A property failed, flaked, or a health check fired          |
| [references/mutation-check.md](references/mutation-check.md)           | Proving a property catches a realistic bug                  |

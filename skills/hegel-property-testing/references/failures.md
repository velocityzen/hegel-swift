# Failures, flakiness and health checks

## Goal

Decide whether a failing property is a real bug in the code under test or a problem in the test,
fix the right thing, and keep a regression that survives libhegel upgrades. A failure is a
candidate, not a conclusion: oracle bugs, generator bugs and shared state all fail properties too.

## Read the minimal example

A report holds:

- the failed expectation, with the operands Swift Testing captured;
- `Falsifying example:` — every named draw as `let name = value`, state machine steps under
  `Step N: rule { ... }`, `repeat` iterations under `// Repetition #N`, concurrent lines prefixed
  `[worker N +Xms]`, and the `tc.note` lines;
- the trait that replays it: `.hegel(reproducing: "...")`.

A failing explicit example is reported under `Falsifying explicit example:` and has no blob.
Failures at different source locations, or thrown errors of different types, are different origins
and arrive as separate reports.

The example is already minimal: every draw is as simple as it can be while the failure persists.
Read it that way. A value that didn't shrink to zero or empty matters to the failure; a step that
survived shrinking is needed.

## Three questions

1. **Can I explain the mechanism step by step?** From the drawn values and steps to the wrong
   state, through the code. If not, add `tc.note` lines with the intermediate state and replay with
   the reproduce trait, or narrow by hand with an explicit example.
2. **Is the code actually wrong?** The report shows what happened, which isn't the same as wrong.
   Check the behavior against the documented contract, not against the test's expectation.
3. **Could the test have caused it?** Its generators, its model, its retries, its bookkeeping and
   its shared resources are code too.

## Classify

**Real bug in the code under test.** The mechanism is explained, the reproduce trait fails
consistently, and nothing in the test explains it. Fix it — or decide with the user to fix it later
and keep testing the other properties.

**Oracle bug.** The code is right; the check is wrong:

- exact equality where faults or concurrency make only a bound knowable;
- a check made mid-operation, on a state that is legitimately transient;
- a check that runs before the precondition it assumes;
- a wrong model — a model is an implementation too, often of the same misunderstanding.

Fix the check, and record what it got wrong.

**Test or generator bug.** The test produced an invalid scenario:

- an input outside the API's documented contract (an invalid combination the API is allowed to
  reject or trap on);
- a retry the API never promised was safe;
- the test's own bookkeeping — attempted/acknowledged sets, pool contents — is wrong;
- state shared between test cases, or between tests (Swift Testing runs tests in parallel: tests
  that share a directory, a port or a global need isolation or `.serialized`).

Fix the test. Constrain the generator only to the documented contract, never to dodge a real bug.

**Environment.** The verdict depends on something outside the choices: wall-clock time, the file
system, the network, hash seeds, scheduling. See "Determinism" below.

## Keep the regression

The reproduce blob only works with the libhegel version that produced it. Once the bug is fixed:

1. Remove the `.hegel(reproducing:)` trait.
2. Add the minimal example as an explicit example, keyed by draw names, so it runs first on every
   run and survives libhegel bumps:

   ```swift
   try property(examples: [["xs": [0, 0]]]) { tc in
       let xs = try tc.draw(.array(of: .int()), named: "xs")
       #expect(mySort(xs) == xs.sorted())
   }
   ```

   A value's type must match its draw exactly (`1.0` for a `Double`). Explicit examples can't
   drive pools or state machines; for a stateful regression, write a plain test that replays the
   reported steps.
3. Record the finding where the next reader will find it — the test's doc comment, or the fix's
   commit message: the sequence, the check that caught it, the mechanism, and the classification.

## Run errors

These end a run without a verdict on the property (`HegelError`):

| Error | Usual cause | Fix |
|---|---|---|
| `healthCheck(.filterTooMuch)` | `filter` or `assume` rejects most cases | construct valid values directly; move the constraint into the generator |
| `healthCheck(.tooSlow)` | the body is expensive | make it cheaper, lower `testCases` for this property, or shrink sizes |
| `healthCheck(.testCasesTooLarge)`, `.largeInitialTestCase` | huge collections or strings | bound `count:`; build large values from a few choices |
| `unsatisfiable` | every case was rejected | the generator and the assumptions contradict each other |
| `flaky` | same choices, different outcome | a determinism leak; see below |
| `nondeterministic` | same choices, different draws | the draws themselves depend on something outside the choices |
| `notReproduced` | the blob replayed without failing | the bug is fixed, or the failure was nondeterministic |
| `usage` | invalid settings, bounds, or an explicit example that doesn't match its draws | read the message |
| `versionMismatch` | the linked libhegel isn't the pinned one | rebuild against the pinned version |

Don't suppress a health check to get a green run. Suppress one only when it is wrong for this test,
with a comment saying why.

## Determinism

Hegel replays a failure by replaying its choices. Anything else that changes the outcome makes the
test flaky and the reproduction unreliable:

- **Shared state across test cases** — a singleton, a static cache, a reused instance, leftover
  files. Create everything inside the test case.
- **Time** — `Date()`, `ContinuousClock.now`, timeouts. Inject a clock the test controls.
- **Unseeded randomness** — `random`, `shuffled`, `UUID()`. Inject and drive from draws.
- **Hash seeds** — `Set` and `Dictionary` iteration order is stable within a process but changes
  between processes, so a failure that depends on it can shrink fine and then not replay from the
  blob or the database. Remove the dependence, or confirm the diagnosis by running with
  `SWIFT_DETERMINISTIC_HASHING=1`.
- **Scheduling** — real concurrency. Expected in concurrent tests; see "Concurrency" in
  [stateful-and-faults.md](stateful-and-faults.md).

## Crashes

A trap — `precondition`, `fatalError`, a force-unwrap, an out-of-bounds index — ends the test
process. Hegel can't catch it, shrink it, or print the example. Read the crash's stack trace for
the trap site, then decide: if the input is inside the documented contract, the code should have
thrown or returned an error, and that's the bug; if it's outside, the generator is wrong. Either
way, keep generated inputs away from documented traps, and make the code report errors through
`throws` or `Result` where you can.

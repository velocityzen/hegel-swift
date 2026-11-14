# Oracles: checks, reach claims and guidance

## Goal

Write checks that fail when the property is violated and only then, and prove the test reaches the
states where they could fail. A property test usually has three kinds of statement:

1. **Safety checks** — must hold every time they are evaluated.
2. **Reach claims** — the test reaches the states that exercise the property.
3. **Search guidance** (optional) — steer generation toward a rare state.

## Intent to code

| Intent | hegel-swift |
|---|---|
| Must hold on every evaluation | `#expect` / `#require` in the body, a rule, or an `invariant` |
| Must hold whenever an optional path runs | `#expect` inside the branch that took the path |
| Must never happen | `Issue.record("...")` in the forbidden branch |
| Must happen at least once, with a meaningful condition | `tc.event`, claimed with `property(reaching:)`; statistics to see how often |
| Must reach this outcome | the same, recording the outcome |
| A comparison with both operands in the report | `#expect(a < b)` written inline — Swift Testing prints both operands |
| Steer generation toward a rare state | `try tc.target(score, label:)` |

Every `#expect`, `#require` and `Issue.record` inside a property is held back while Hegel explores
and shrinks; only the minimal example's issues are reported.

## Safety checks

**Where.** Check right after the operation that could break the property — in the rule, or in the
`repeat` body — not only once at the end. In a state machine, register cheap invariants with
`everyStep: true` so a failure is reported at the step that caused it; leave expensive ones
sampled.

**`#expect` or `#require`.** `#expect` records and continues. `#require` records and ends the case;
use it when later code depends on the condition (unwrapping, an index that must exist).

**Optional paths.** Put the check inside the branch, so "never ran" is acceptable and "ran and was
wrong" fails. Pair it with a reach claim if the path matters:

```swift
if let snapshot = try store.compactIfNeeded() {
    #expect(snapshot.entries == model.liveEntries)
}
```

**Forbidden paths.**

```swift
switch decoder.decode(validEncoding) {
case .value(let v): #expect(v == original)
case .corrupt: Issue.record("valid encoding decoded as corrupt")
}
```

**Comparisons.** Write the comparison inline. `#expect(map.count == model.count)` reports both
sides; `#expect(countsMatch)` reports `false`. For several related values, check each one
separately rather than comparing a large struct, so the report points at the field that diverged.

**Bounds, not exact values.** When the test can't know the exact outcome — a dependency failed
after applying a write, a read raced a concurrent write, a timeout fired mid-operation — track what
was *attempted* and what was *acknowledged*, and check both sides of the bound with separate checks:

```swift
#expect(store.count >= model.acknowledged, "lost an acknowledged write")
#expect(store.count <= model.attempted, "applied a write that was never attempted")
```

`#expect(store.count == model.attempted)` would fail whenever an injected fault legitimately
dropped a write, burying real bugs in false failures. Two sites also mean two origins: each side
shrinks and reports on its own.

**Checks the test can't make from outside.** When the invariant is internal (a heap order, an
index consistent with its table), expose it to the test instead of asserting inside the code:
an `internal func checkInvariants() -> [String]` used through `@testable import`, called from an
`invariant`. Don't use `assert` or `precondition` as the oracle: a trap ends the test process and
Hegel can't shrink it.

## Failure origins: one site, one bug

Hegel groups failures by origin — the source location of the first issue, or the type of a thrown
error — and shrinks each origin separately. Use that:

- **Give distinct properties distinct sites.** Don't route every check through one helper
  `#expect`: all its failures become one bug, and one can shrink into another. Forward the
  caller's location:

  ```swift
  func expectSorted(_ xs: [Int], sourceLocation: SourceLocation = #_sourceLocation) {
      #expect(zip(xs, xs.dropFirst()).allSatisfy { $0 <= $1 }, sourceLocation: sourceLocation)
  }
  ```

- **Thrown errors group by type.** If one error type stands for several distinct failures,
  conform it to `FailureOrigin`:

  ```swift
  struct ModelMismatch: Error, FailureOrigin {
      let field: StaticString
      var failureOrigin: String { "ModelMismatch.\(field)" }
  }
  ```

- **Seeing every bug at once.** By default the run ends at the first failure. Turn on
  `reportMultipleFailures` when you want every distinct origin found in one run.

## Reach claims

A reach claim says the test got to the state where the property *can* fail. Without one, a green
property may only mean the interesting state never happened.

**Events and statistics** — the measuring tool. Record outcomes as they happen:

```swift
if cache.count == capacity { try tc.event("cache full") }
try tc.event("queue depth", value: Double(queue.count))
```

Run with `HEGEL_STATISTICS=1 swift test --filter <TestName>` (or `Settings(showStatistics: true)`)
and read the share of generated cases in which each event occurred, and the distribution of each
numeric observation. A share of 0% is a generator gap; a share of 1% means the property is barely
exercised.

**`property(reaching:)`** — the guard that keeps it from regressing. List the event labels the
property must record; the run fails when no passing generated case recorded one of them:

```swift
/// Eviction keeps the most recently written key.
@Test(.hegel)
func evictionKeepsMostRecent() throws {
    try property(reaching: ["filled past capacity"]) { tc in
        let capacity = try tc.draw(.int(in: 1...4), named: "capacity")
        let keys = try tc.draw(.array(of: .int(in: 0...9)), named: "keys")
        let cache = LRUCache<Int, Int>(capacity: capacity)
        for key in keys { cache.put(key, key) }
        if Set(keys).count > capacity {
            try tc.event("filled past capacity")
        }
        if let last = keys.last {
            #expect(cache.get(last) == last)
        }
    }
}
```

- The event is the claim, so the two can't drift apart. Events recorded by `concurrently`
  workers and by state machine rules and invariants count, so no counter has to live in a model.
- Only passing generated cases count: a rejected case's events don't, and neither do explicit
  examples', since the claim is about what generation reaches.
- A run that can't judge the claims doesn't: one that fails, replays a reproduce blob or a stored
  failure that still fails, or runs only explicit examples.
- Assert reach only for states your statistics show in a healthy share of cases. A claim on a
  1-in-500 state is flaky under a random seed; make the generator reach it more often instead.
  If a state is reliable only in deep runs, claim it with `reachingAfter: ["<label>": 1_000]`: the
  run judges it only once that many generated cases passed, however the count was set. Never
  guess a run's depth from `HEGEL_*` variables.
- `Property.run(reaching:)` does the same without Swift Testing: it throws `HegelError.unreached`.

**A reach claim asserts the precondition, never the violation.** Don't count the bad state that a
check forbids: on a correct system it never happens, and the claim fails. Count each part of the
precondition separately:

- Bad: `#expect(!(stale && served))` with a claimed event for `stale && served`.
- Good: the same check, with one claimed event for `stale` and one for `served`. Both occur on a
  correct system, and together they show the test reaches the window where a stale read could be
  served.

**Prefer outcome markers over entry markers.** "Eviction happened" says more than "`put` was
called". Don't stack a general marker before a specific one that already proves the path.

**Labels are constants.** Event and target labels name a condition, not a value: interpolating a
key or an ID makes one label per value. Use `event(_:value:)` for numbers; interpolate only small,
fixed vocabularies such as an enum case.

## Search guidance with `target`

`try tc.target(score, label:)` makes the engine prefer inputs that scored higher under that label.
Use it to climb toward a rare state a reach claim shows is under-visited: queue depth, tree height,
number of evictions, distinct keys in flight. Each label may be recorded once per test case, and it
has no effect when the target phase is off.

## Anti-rules

- A check that can't fail: comparing the system with itself, a model that calls the
  implementation, a tolerance that swallows the error.
- An exact-equality check on a value that injected faults or concurrency legitimately perturb.
- A reach claim that is the negation of a safety check at the same site.
- One helper `#expect` shared by unrelated properties without forwarding `sourceLocation`.
- `assert`/`precondition` in the code under test used as the oracle.
- Event or target labels built from unbounded runtime values.
- A check placed only after the run, when the state could have broken and recovered in between.
- A property with no reach claim for the state it exists to test.

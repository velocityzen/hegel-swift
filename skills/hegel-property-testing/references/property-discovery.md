# Property discovery

## Goal

Turn an understanding of the code into a set of concrete, checkable properties, each with the
states a test must reach to exercise it. Look at the same code through several lenses: one
unstructured pass finds the obvious properties and misses the rest.

## Orient first

Scope the reading to the feature's neighborhood, just enough to navigate it:

- **Surface** — the public API: what goes in, what comes out, what is thrown or returned as
  `nil`, what side effects happen.
- **State** — what the type or subsystem keeps, where it is persisted, what derived state
  (caches, indexes, counters) must stay consistent with it.
- **Concurrency** — actors, locks, atomics, `Sendable` boundaries, `await` points inside
  critical sections, work handed to other tasks.
- **Errors** — every `throw`, `try?`, `catch` that logs and continues, fallback path, retry.
- **Limits** — capacities, timeouts, batch and page sizes, retry counts, the constants that
  decide which branch runs.
- **Lifecycle** — setup, teardown, migration, cancellation, restart from persisted state.
- **History** — recent changes and fixes to these files. A fix often covers the reported case
  and misses its neighbors.

## Where properties come from

**Claimed guarantees.** Doc comments, DocC articles, READMEs, and type names claim behavior:
"thread-safe", "stable", "returns `nil` when the key is absent", "idempotent", "never exceeds
`capacity`". Each claim becomes a property. Write that the code *claims* it and the property
checks it — never that it holds. Docs drift.

**Bug reports and incidents.** A report is one person's guess about their own problem, and the
reporter is often wrong about the cause. Before building on one:

1. Name the competing explanation before you look — usually "the reporter's configuration or
   usage, not the code".
2. Read the part that carries evidence: the repro, logs, the fix and its discussion — not the
   title.
3. Record the detail that tells the two explanations apart. "The issue says the cache loses
   entries" is not validation; "eviction in `trim()` runs before the size check when
   `capacity == 1`" is.

If you can't settle it, record an open question; it doesn't become a property.

**Closed bugs.** A confirmed, fixed bug gives two things: an explicit example reproducing the
original case (`property(examples:)`), and a property that generalizes it. Ask what condition
triggered it and whether a slightly different condition bypasses the fix.

## Attention focuses

Make one deliberate pass per focus. Not every focus yields properties for every feature; when one
yields nothing, note why and move on. Resist skipping a focus because an earlier pass "already
covered" the code — the point is a different angle on the same code.

1. **Data integrity.** Nothing written is silently lost, truncated, reordered or corrupted.
   Round-trips (`decode(encode(x)) == x`, `parse(print(x)) == x`), persistence and restore,
   ordering guarantees.
2. **Model conformance.** The implementation agrees with a simple, obviously-correct model: a
   dictionary for a cache, an array for a queue, a brute-force search for an index.
3. **Structural invariants.** Sorted, balanced, unique, within bounds, counts consistent with
   contents, derived state consistent with source state — after every operation.
4. **Contracts and error handling.** Invalid input produces the documented error, not a wrong
   answer, a hang or a trap. Look for swallowed errors, `try?` that hides a failure, catch-alls
   that "can't happen".
5. **Resource boundaries.** Behavior at empty, one, capacity, capacity plus one; transitions
   between full and empty; overflow; off-by-one at configured limits.
6. **Idempotency and replay.** Operations that claim idempotency are idempotent; applying the
   same message twice, or retrying after a lost acknowledgement, leaves correct state.
7. **Concurrency.** Concurrent operations end in a state some serial order could produce; no
   lost updates; no interleaving across an actor's `await` breaks an invariant (actor
   reentrancy); no deadlock.
8. **Lifecycle and cancellation.** Work cancelled at any point releases what it acquired and
   leaves state consistent; operations during startup or shutdown behave as documented.
9. **Failure recovery.** A failing dependency, a lost acknowledgement, or a crash and restart from
   persisted state leaves the system correct, and it converges once the failures stop.
10. **Version compatibility.** Old encoded payloads still decode; missing keys get their
    documented defaults; migrations preserve data.
11. **Security boundaries.** Validation can't be bypassed by a sequence of individually valid
    operations; untrusted input can't reach privileged paths.
12. **Wildcard.** Last, knowing what the others covered: properties at their intersections
    (recovery that breaks idempotency, an eviction during cancellation), guarantees the code
    provides but never states, the property too obvious to assert. If something feels off but
    you can't state the invariant, write down the intuition.

## Making a property checkable

Every property needs an oracle. The common shapes:

| Shape | The check |
|---|---|
| Round-trip | `f⁻¹(f(x)) == x` |
| Model / differential | the system and a reference agree after every operation |
| Invariant | a predicate on state holds after every operation |
| Metamorphic | a known relation between two runs: adding an element never shrinks `count`; filtering never grows a result |
| Algebraic law | identity, associativity, commutativity, inverse |
| Idempotence | `f(f(x)) == f(x)` |
| Contract | only documented errors are thrown, and only for documented inputs |
| Bound | the observed value lies between what was acknowledged and what was attempted |

Classify each property:

- **Safety** — a bad thing never happens. Checked with `#expect`, `#require` or `Issue.record` on
  every evaluation.
- **Liveness** — a good thing eventually happens. In a bounded test: after the failures stop and
  the system gets a bounded amount of progress, it has converged.
- **Reachability** — a state or path is reached. Checked with events listed in
  `property(reaching:)`, not with `#expect` inside the property.

See [oracles.md](oracles.md) for how each becomes code.

## Is it worth a property test?

A property test pays off when the input space is large, or the bug needs a specific combination,
sequence, size or interleaving. If the invariant is fully checked by two fixed inputs, write an
example test or an explicit example instead and spend the property budget elsewhere. The inverse
also holds: "the happy path works" is not a reason to deprioritize a property whose unhappy paths
nobody has tested.

## Recording properties

For one or two properties, a doc comment on the test is enough:

```swift
/// Acknowledged writes survive a crash and restart.
/// Safety. Model: the writes the store acknowledged after its last successful sync.
/// Reach: at least one crash after an acknowledged, synced write.
@Test(.hegel)
func acknowledgedWritesSurviveRestart() throws { ... }
```

For a larger effort, keep a catalog next to the tests. Per property: a kebab-case slug (the test
name in camelCase), its type, the one-sentence property, the check and where it runs, the hegel
construct, its reach claims, and open questions.

Keep entries honest. Don't write a firm claim the open questions contradict: if "acknowledged" is
unresolved (returned without throwing? synced to disk?), keep the prose general and put the
question in the list. Tag a question `(needs human input)` only after the code and docs have been
searched and come up empty, and say what was searched.

## Reviewing the set

Once the properties exist, review them as a portfolio, ideally with a fresh-context sub-agent
that didn't write them:

- **Coverage balance** — does every risky area from orientation have a property? Is one area
  over-served? Are safety, liveness and reachability all represented where they apply?
- **Implementability** — can each check observe the state it needs, or does it need a test hook,
  an injected dependency, or a model? Can the generators construct the preconditions?
- **Fit** — which properties are really example tests? Which are underrated?
- **Wildcard** — what failure scenario did nobody model?

Apply refinements directly, fill gaps with another targeted discovery pass, and bring orientation
problems (the set guards writes but the real risk is reads) to the user to decide.

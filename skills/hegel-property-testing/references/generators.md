# Generators

## Goal

Generators set the ceiling on what Hegel can find. A property can only fail on inputs its
generators can produce, so a narrow, uniform or hardcoded generator hides whole regions of
behavior no matter how many test cases run.

The core principle: **randomize the policy per test case, not just the choices under a fixed
policy.** Each test case should be free to land in a different region of behavior.

## What the engine already does — don't fight it

- **Shrinks every draw.** A loop count, a value computed outside a draw, or randomness from
  anywhere but `tc.draw` can't shrink and doesn't replay.
- **Sizes collections, `repeat` loops and state machine runs.** It varies how many elements,
  iterations and steps a case gets, and shrinks toward fewer. Don't hardcode
  `for _ in 0..<100`; draw an `.array(of:)` of operations or use a `StateMachine` (or `tc.repeat`
  for a cheap body — a passing `repeat` runs until the case's budget is spent).
- **Swarm-tests state machine rules.** Each worker enables a random subset of the rules (at least
  one per concurrency group), with weights as hints, and the engine re-randomizes this as the run
  goes. Don't hand-roll a rule dispatcher with a fixed distribution on top.
- **Shrinks toward simple values.** Integers toward zero (or the bound nearest it), `oneOf` and
  `element(of:)` toward their first entry, `optional` toward `nil`, collections toward fewer,
  smaller elements. Put the simplest alternative first so minimal examples stay readable.
- **Rejects on filters.** `filter` tries three times, then rejects the case; `assume` rejects
  immediately. Rejected cases don't count, and too many trip the `filterTooMuch` health check.

What the engine can't know is your domain: which values are boundaries, which limits the code is
configured with, which operations suppress each other. That's what the rest of this file is for.

## Two axes

- **Menu** — which values can be drawn.
- **Shape** — how often each is drawn, and which operations exist at all in this case.

Both compose: the menu decides what exists; the shape decides how often.

## Menus: boundaries and configured-limit families

Uniform draws from `0...1000` land in the bulk and rarely touch a boundary. Build a menu:

1. **Type boundaries** — zero, one, `-1`, `.min`, `.max`, empty, a single element, NaN and the
   infinities for floating point, a string whose `count`, `unicodeScalars.count` and
   `utf8.count` all differ.
2. **Configured-limit families** — for each limit `N` on the code path (capacity, page size,
   timeout, batch size, retry count): `N - 1`, `N`, `N + 1`, and often `2N`.
3. **Values from fixes** — a boundary or off-by-one fixed recently in these files.

Then mix the menu with the full domain the API accepts, so the bulk is still explored:

```swift
func limits(pageSize n: Int) -> Gen<Int> {
    .oneOf(
        .element(of: [0, 1, n - 1, n, n + 1, 2 * n]),
        .int(in: 0...10_000),
        .int()  // negative and huge limits: does the contract hold?
    )
}
```

When the limit itself is configurable, draw it first and build the family around it, so the menu
moves with the configuration:

```swift
try property { tc in
    let pageSize = try tc.draw(.element(of: [1, 50, 1_000]), named: "pageSize")
    let store = PagedStore(pageSize: pageSize)
    let limit = try tc.draw(limits(pageSize: pageSize), named: "limit")
    // ...
}
```

Some properties have no menu worth building — a fixed vocabulary of operations, a pure
reachability check. Say so in a comment (`// menu: none, operations are {open, close}`) rather
than inventing values.

## Shape: policy per test case

Draw the policy at the top of the test case. Each policy value shrinks too, so the minimal example
reports the policy that triggers the bug.

**With a state machine**, the engine already omits and skews rules per worker. Draw the policy it
can't see — here, the size of the key space — into the model:

```swift
struct MapModel {
    let keySpace: Int
    let map = MyMap<Int, Int>()
    var model: [Int: Int] = [:]
}

let mapMachine = StateMachine<MapModel>()
    .rule("update") { s, tc in
        let key = try tc.draw(.int(in: 0..<s.keySpace), named: "key")
        let value = try tc.draw(.int(), named: "value")
        #expect(s.map.updateValue(value, forKey: key) == s.model.updateValue(value, forKey: key))
    }
    .rule("remove") { s, tc in
        let key = try tc.draw(.int(in: 0..<s.keySpace), named: "key")
        #expect(s.map.removeValue(forKey: key) == s.model.removeValue(forKey: key))
    }
    .invariant("count", everyStep: true) { s, _ in
        #expect(s.map.count == s.model.count)
    }

/// MyMap behaves like a Dictionary under any sequence of updates and removals.
@Test(.hegel)
func mapMatchesDictionary() throws {
    try property { tc in
        let keySpace = try tc.draw(.element(of: [1, 2, 8, 1_000]), named: "keySpace")
        try mapMachine.run(tc, from: MapModel(keySpace: keySpace))
    }
}
```

**Without a state machine**, draw the rates yourself and generate the operations as data:

```swift
enum MapOp: Sendable { case update(Int, Int), remove(Int) }

func mapOps(keySpace: Int, removeRate: Double) -> Gen<MapOp> {
    let key = Gen.int(in: 0..<keySpace)
    return Gen.bool(probability: removeRate).flatMap { remove in
        remove ? key.map(MapOp.remove) : zip(key, Gen.int()).map(MapOp.update)
    }
}

try property { tc in
    // This test case's policy.
    let keySpace = try tc.draw(.element(of: [1, 2, 8, 1_000]), named: "keySpace")
    let removeRate = try tc.draw(.element(of: [0.0, 0.05, 0.5, 0.95]), named: "removeRate")
    let ops = try tc.draw(
        .array(of: mapOps(keySpace: keySpace, removeRate: removeRate)), named: "ops")

    let map = MyMap<Int, Int>()
    var model: [Int: Int] = [:]
    for op in ops {
        switch op {
        case .update(let key, let value):
            #expect(map.updateValue(value, forKey: key) == model.updateValue(value, forKey: key))
        case .remove(let key):
            #expect(map.removeValue(forKey: key) == model.removeValue(forKey: key))
        }
        #expect(map.count == model.count)
    }
}
```

When this `MyMap` forgets the old value on an overwrite, the report reads
`let keySpace = 1`, `let removeRate = 0.0`, `let ops = [update(0, 0), update(0, 0)]`: the bug
needs a colliding key and no removals, and the shrunk policy says so.

What this buys:

- **A tiny key space** forces collisions, overwrites and removal of present keys; a large one
  forces growth. Neither happens much at a fixed middle size.
- **Omission** — with removals off (rate `0.0`), state only grows and crosses thresholds (rehash,
  resize, compaction) that removals would have prevented. Including an operation can suppress the
  behavior another one needs; there is no single best mix.
- **Skew** — a 95% removal rate drives the map toward empty and keeps it there; 5% lets it grow.

Prefer either form to a `tc.repeat` loop with per-iteration choices for anything but a trivially
cheap body: a passing `repeat` runs until the case's budget is spent — the `repeat` version of this
test took 47 seconds for 100 cases, against milliseconds for the two above.

Policy worth drawing, when the test has it: key or ID space size, operation enablement and rates,
fault rate, initial state size, configured capacities and timeouts, worker count, payload size
band, input validity mix.

## Anti-pattern catalog

Use this to build generators and to review existing ones. Each entry is a ceiling on what the
suite can reach, not necessarily a defect — a suite with several may still find bugs.

### Operation selection

- **Fixed sequence templates.** Always `create → use → delete`. Bugs need orders the template
  never produces: delete before create, use after delete, delete twice. Let the engine choose the
  order: operations as an array, `repeat`, or state machine rules.
- **Fixed, uniform mix with no omission.** Every case has the same operations in the same
  proportions, so every case has the same macro behavior. Draw enablement and rates per case, or
  use a state machine.
- **Hand-tuned distributions.** Weights tuned to one hypothesis about where the bug is. If the
  hypothesis is wrong, the suite is stuck in the wrong region. Prefer drawn skew over tuned
  weights; use `weight:` for genuine frequency needs only.
- **Fixed length.** A `for _ in 0..<N` loop: can't shrink, never short, never long. Short
  sequences find shallow bugs fast; long ones reach accumulated state.
- **A subset of the API.** Three operations of a type that has twelve. The untested ones —
  configuration, administration, bulk and reset operations especially — interact with state too.
- **Over-filtering on state.** `try tc.assume(!model.isEmpty)` in a `pop` rule means `pop` on an
  empty stack is never tested. Separate *physical* constraints (the API traps on that input, or
  the test literally can't express it) from *assumptions* about what the code handles. Relax the
  assumptions: test the empty case and expect the documented result.
- **Production-scale thresholds.** A cache that evicts after 10,000 entries or compacts every
  hour never does so in a test. Inject small, drawn thresholds.

### Data

- **Hardcoded values.** `"foo"`, `id: 1`, `size: 10` — one point in the input space. Draw them.
- **Ranges narrower than the contract.** `.int(in: 0...100)` for an API that accepts any `Int`.
  Narrow deliberately and keep a share of the full domain in a `oneOf`.
- **No boundary menu.** Values stay in the comfortable middle. See "Menus" above.
- **One size band.** Payloads always around the same size. Behavior changes at buffer and page
  boundaries and between small- and large-input algorithms. `.string()` and `.bytes()` stop at
  the engine's default maximum of 100 unless you give a `count:`. Large draws are slow and can trip
  the size health checks; when only size matters, build a large value from a few choices:

  ```swift
  let payloads: Gen<[UInt8]> = Gen.int(in: 0...1_000_000)
      .zip(Gen.bytes(count: 1...16)) { size, pattern in
          (0..<size).map { pattern[$0 % pattern.count] }
      }
      .printed { bytes, printer in printer.text("<\(bytes.count) bytes>") }
  ```

- **Small fixed pools.** Keys always from the same five strings. Draw the pool size and draw its
  contents.
- **Always complete data.** Optional fields always present, arrays never empty. Use `.optional`,
  allow `count: 0...`, and draw a per-case completeness rate when there are many optional fields.
- **Uniform structure.** Same nesting depth, same field count. Use `.recursive` with drawn
  `maxDepth`/`maxLeaves` bands, sparse and dense shapes.
- **Independent related fields.** `start` and `end` drawn independently are inconsistent about
  half the time, by accident rather than by choice. Control it:

  ```swift
  let spans: Gen<(Int, Int)> = .oneOf(
      Gen { tc in                                   // consistent: start <= end
          let start = try tc.draw(.int(in: 0...1_000))
          return (start, try tc.draw(.int(in: start...1_000)))
      },
      zip(Gen.int(in: 0...1_000), Gen.int(in: 0...1_000))  // anything, including start > end
  )
  ```

- **Only valid inputs.** Error paths never run. Mix valid, invalid and mixed per case:
  `oneOf(validRequests, malformedRequests)`, operations on IDs that were never created, closed
  handles.
- **One character set.** `.ascii` everywhere. `.string()` defaults to full Unicode; mix both, and
  add `.characters("ab")` alphabets when collisions matter. Bugs live in combining characters,
  multi-scalar graphemes, and length mismatches between `count`, scalars and UTF-8.
- **One representation.** If the input accepts several encodings or formats, draw which one.
- **Always the same initial state.** Every case starts empty. Draw the initial contents into the
  model passed to `run`, from empty to large.

### Structure and concurrency

- **Fixed concurrency.** `concurrently(workers: 4)` always. Draw it:
  `workers: try tc.draw(.int(in: 1...8), named: "workers")`. One worker checks sequential
  correctness; two find basic races; many find contention. `ConcurrentStateMachine` draws its
  level from `concurrency:`, weighted toward the top.
- **Disjoint workers.** Each worker writes its own key prefix, so nothing contends. Draw the
  overlap: shared keys, disjoint keys, or partial.
- **Identical workers.** Every worker runs the same mix, so they hit the same paths at the same
  time. Give each worker its own drawn policy.
- **Monotonic state.** State only grows or only shrinks, crossing each threshold once. Skewed
  rates per case give grow-then-shrink and oscillating runs.

### State tracking

- **The test doesn't remember what it did.** Random operations with no record of which keys exist
  can't deliberately target existing versus missing resources. Keep a model, and use a `Pool` for
  handles that later steps draw on (`pool.reusable` keeps the value, `pool.consumed` removes it,
  `consumed(where:)` removes only a match).

## Determinism checklist for generators

- No `Int.random`, `.shuffled()`, `randomElement()`, `UUID()`, `Date()` or `SystemRandomNumberGenerator`
  in the property or in code paths it exercises. Inject the source and drive it from draws. If an
  API takes a `RandomNumberGenerator`, pass one seeded from a drawn `UInt64` — it replays, though
  only the seed shrinks.
- Build constraints into the generator (`Gen { tc in ... }`, `flatMap`, `.int(in: lo...hi)`)
  instead of filtering. Reserve `filter` and `assume` for constraints that are rare to violate.
- Don't let iteration order of a `Set` or `Dictionary` decide what happens next; it depends on a
  per-process hash seed, so the failure may not replay in the next process.

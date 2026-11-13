# hegel-swift

Property-based testing for Swift, built on [Hegel](https://hegel.dev): the engine from the
Hypothesis developers, with its generation, shrinking and failure database, driven through
libhegel's C ABI. hegel-swift adds generators that are plain values, and Swift Testing
integration that shrinks `#expect` failures before they are reported.

```swift
import HegelTesting
import Testing

@Test(.hegel)
func sortMatchesBuiltin() throws {
    try property { tc in
        let xs = try tc.draw(.array(of: .int()), named: "xs")
        #expect(mySort(xs) == xs.sorted())
    }
}
```

When `mySort` drops duplicates, the test fails once, on the smallest input that shows it:

```
Expectation failed: mySort(xs) == xs.sorted()
  Falsifying example:
      let xs = [0, 0]

  To reproduce this failure, add this trait to the test:
      .hegel(reproducing: "AXicY2VgYGBkZOBiZEBhMAAAAd8AIQ==")
  mySort(xs) == xs.sorted() → false
    mySort(xs) → [0]
    xs.sorted() → [0, 0]
```

> [!IMPORTANT]
> hegel-swift is new, and libhegel is in beta: expect breaking changes. Each release of this
> package pins one libhegel version.

## Contents

- [Installation](#installation)
- [Writing properties](#writing-properties)
- [Generators](#generators)
- [Stateful testing](#stateful-testing)
- [Settings](#settings)
- [Reproducing a failure](#reproducing-a-failure)
- [Without Swift Testing](#without-swift-testing)
- [How it works](#how-it-works)
- [Following libhegel releases](#following-libhegel-releases)
- [Limitations and roadmap](#limitations-and-roadmap)
- [Development](#development)

## Installation

Requirements:

- Swift 6.3 or later
- macOS 26 or later on Apple silicon, Linux (x86_64 or arm64), or Windows (x86_64 or arm64)

Add the package to `Package.swift`, and its products to your **test** targets only:

```swift
dependencies: [
    .package(url: "https://github.com/velocityzen/hegel-swift.git", from: "0.1.0"),
],
targets: [
    .testTarget(
        name: "MyLibraryTests",
        dependencies: [
            "MyLibrary",
            .product(name: "HegelTesting", package: "hegel-swift"),
        ]
    ),
]
```

SwiftPM resolves dependencies per target, so packages that depend on your library never fetch
hegel-swift. The engine comes as a prebuilt static library that SwiftPM downloads; there is
nothing else to install.

Add `.hegel/` to your `.gitignore`. Hegel stores failing examples there and replays them first
on the next run.

## Writing properties

A property is a closure that draws inputs from a `TestCase` and checks something about them.
Put it in `property { }` inside a test that has the `.hegel` trait:

```swift
@Suite(.hegel)
struct ResultLaws {
    @Test
    func mapIdentity() throws {
        try property { tc in
            let r = try tc.draw(results, named: "r")
            #expect(r.map { $0 } == r)
        }
    }

    @Test(.hegel(testCases: 1_000))
    func flatMapAssociativity() throws {
        try property { tc in
            // ...
        }
    }
}
```

- The property fails when an `#expect` or `#require` fails, or when the closure throws.
- While Hegel explores and shrinks, failures are held back. Only the minimal example is
  reported, and its issues carry the drawn values and a reproduce trait.
- Failures at different source locations are different bugs. Each is shrunk and reported on its
  own.
- `try tc.assume(condition)` and `try tc.reject()` discard a test case that isn't valid input.
  Discarded cases don't count toward the budget.
- `tc.note("...")` adds a line to the report. `try tc.target(score)` steers generation toward
  higher scores. `try tc.event("label")` feeds the statistics report.
- Async works too: `try await property { tc in ... }`.

The trait is required. `property` needs it to see `#expect` failures before Swift Testing records
them. On a suite, it applies to every test in it, and a test's own `.hegel(...)` overrides the
suite's settings field by field. If you use other issue-handling traits on a test, list `.hegel`
after them.

Draws throw to end a test case early, when it is rejected or the engine has used up its budget.
Let those errors propagate.

### Naming draws with `#draw`

Reports show each draw as `let name = value`. `named:` sets the name; `#draw` takes it from the
`let` or `var` it initializes instead:

```swift
try property { tc in
    let xs = try #draw(.array(of: .int()), from: tc)   // tc.draw(.array(of: .int()), named: "xs")
    #expect(mySort(xs) == xs.sorted())
}
```

A draw that doesn't initialize a plain binding (inside a closure, in a tuple pattern, or after
`_ =`) is unnamed, and the report calls it `draw_1`, `draw_2`, and so on. A draw nested in a
larger initializer takes that binding's name: `let xs = [try #draw(.int(), from: tc)]` is reported
as `let xs = 0`. Use `tc.draw(_:named:)` there.

`#draw` comes with `HegelTesting` and builds with swift-syntax. It needs Swift 6.4 to name draws:
Swift 6.3 doesn't show a macro the binding it initializes, so there every `#draw` is unnamed.

### Explicit examples

`examples:` runs a property on values you choose, before any generated ones. It is the place
for the edge cases you know about, and for regressions you want checked on every run:

```swift
try property(examples: [["xs": [Int]()], ["xs": [3, 1, 2]]]) { tc in
    let xs = try tc.draw(.array(of: .int()), named: "xs")
    #expect(mySort(xs) == xs.sorted())
}
```

- Each value is keyed by the name its draw is reported under: `xs` for `named: "xs"`, `xs_2`
  for a second draw with that name, `draw_1`, `draw_2`, ... for unnamed draws. A `#draw` is
  named after its `let`.
- A value's type must be the draw's exactly. Give a `Double` draw `1.0`, not `1`.
- A failing example is reported under `Falsifying explicit example:` with its values, and has no
  reproduce blob. It ends the run, unless `reportMultipleFailures` is on. Then every example
  runs, generation follows, and a generated failure with the same origin as an example's is
  dropped.
- These are usage errors: a draw with no value, a value no draw took, and rejecting an example
  with `assume` or `reject`.
- An example makes no engine calls. `target` and `event` do nothing, `repeat` runs its body
  once, and `concurrently` runs its workers on the same values. Pools, state machines,
  `drawSilent` and spans are usage errors.
- Examples run only when the `explicit` phase is on, which it is by default. A run that replays
  a reproduce blob skips them.

### Reach claims

A property can pass because its generators never reach the state it exists to test. List the
event labels it must record, and the test fails when no passing generated case recorded one:

```swift
try await property(reaching: ["transforms overlapped"]) { tc in
    let jobs = try tc.draw(jobsGen, named: "jobs")
    let report = try await pool.run(jobs)
    if report.maxOverlap > 1 { try tc.event("transforms overlapped") }
    #expect(report.results == jobs.map(transform))
}
```

- Events from `concurrently` workers and from state machine rules and invariants count. Events
  from rejected cases and from explicit examples don't.
- A run that can't judge the claims doesn't: one that fails, replays a reproduce blob or a stored
  failure, or runs only explicit examples.
- Claim states that statistics (`HEGEL_STATISTICS=1`) show in a healthy share of cases; a claim on
  a rare state is flaky.
- `Property.run(reaching:)` throws `HegelError.unreached` instead.

### Repeating a body

`tc.repeat` runs a body again and again, for as long as the engine wants. A failure shrinks to
the fewest iterations that show it, the way an array shrinks to the fewest elements. It suits a
sequence of operations that doesn't need a full [state machine](#stateful-testing):

```swift
try property { tc in
    var stack = MyStack()
    try tc.repeat { tc in
        let x = try tc.draw(.int(), named: "x")
        stack.push(x)
        #expect(stack.top == x)
    }
}
```

In a report, each iteration's draws sit under a heading, and draw names carry on from one
iteration to the next:

```
// Repetition #1
  let x = 0
// Repetition #2
  let x_2 = 1
```

- An iteration that fails an assumption is skipped, and the loop goes on.
- `repeat` never returns. When the engine ends the loop, it throws to end the test case as
  passed, so put nothing after it and let the error propagate.
- A passing loop runs until the test case's budget is used up, often many thousands of
  iterations. Keep the body cheap, or run fewer test cases.
- Async bodies work too: `try await tc.repeat { tc in ... }`.

### Drawing from several threads

`tc.concurrently(workers:)` runs a body on that many tasks at once, each on its own thread and
its own clone of the test case, and returns their results in worker order:

```swift
try await property { tc in
    let counter = MyAtomicCounter()
    let added = try await tc.concurrently(workers: 4) { worker, tc in
        let n = try tc.draw(.int(in: 0...100), named: "n")
        counter.add(n)
        return n
    }
    #expect(counter.value == added.reduce(0, +))
}
```

- Each clone draws from its own stream of choices, so what a worker draws doesn't depend on
  scheduling, and failures replay and shrink as usual. Races in your own code may still not
  reproduce every time.
- Report lines are prefixed with the worker and the time, as in `[worker 1 +0.013ms] let n = 4`.
- The workers are one test case. A worker that is rejected rejects it; otherwise the
  lowest-numbered worker's failure fails it, and the other workers' failures are noted.

### Cancelling at random points

`tc.withRandomCancellation` runs a body in a task and cancels that task right after a drawn
checkpoint. Call `cancellation.checkpoint()` wherever a cancel is interesting, usually from the
closures you hand to the code under test:

```swift
try await property { tc in
    let run = try await tc.withRandomCancellation { cancellation in
        let log = EventLog(onEvent: { cancellation.checkpoint($0) })
        return await resource.use(log: log)
    }
    #expect(run.value.everythingReleased)
    #expect(run.cancelledAt == nil || run.value.sawCancellation)
}
```

- The drawn point N runs from 0, which cancels before the body starts, to the last checkpoint.
  The cancel happens inside the Nth `checkpoint()` call, so whatever runs after it sees
  `Task.isCancelled`. Sometimes the task isn't cancelled at all.
- Pass `checkpoints: 0...count` when you know how many there will be, so every cancel lands on
  one. Without it, N is drawn from any `Int`, mostly small ones, and a point past the last
  checkpoint means no cancel.
- Failures shrink to the earliest checkpoint that still fails, or to no cancel when the failure
  doesn't need one. The report says where the cancel landed:
  `// Cancelled after checkpoint 4 of 6 (dispose 2)`.
- `checkpoint()` works from any task, synchronous code included, and still cancels the body's
  task. When several tasks reach checkpoints at once, which one is the Nth depends on scheduling.
- The result carries `value`, `cancelledAt` and `checkpoints`; `run.isCancelled(after: n)` says
  whether code after the nth checkpoint saw the cancel. Cancelling the caller cancels the body
  too. The body can't draw: draw what it needs first.

### Detecting stalls

A lost wakeup or a deadlock makes async code wait forever, and Hegel can't report or shrink a test
case that never returns. `tc.withStallDetection(after:)` turns the hang into a failure. Call
`heartbeat.beat()` at each step of progress, so slow work that keeps beating isn't mistaken for
stuck work:

```swift
try await property { tc in
    let jobs = try tc.draw(.array(of: .int()), named: "jobs")
    let results = try await tc.withStallDetection(after: .seconds(5)) { heartbeat in
        try await pool.run(jobs, onEach: { _ in heartbeat.beat() })
    }
    #expect(results.count == jobs.count)
}
```

- When the heartbeat goes the limit without a beat, the body's task is cancelled and the call
  throws `Stalled`. Its origin is the call site, so stalls at different calls are different bugs.
  The body's value is returned and its error rethrown.
- The body runs in a task of its own, which is abandoned once it stalls: a hang that ignores
  cancellation would otherwise hang the test too. The body can't draw: draw what it needs first.
- Shrinking a stall would cost the full limit for every candidate that still hangs. So once a case
  has stalled, the cases tried while shrinking get a shorter limit: 4 times the longest gap between
  beats seen in passing cases, and at least 100 ms. The cases a report is built from still get the
  full limit, so a reported stall is always a full one.
- Allow for a busy CI machine: a few seconds for work whose steps take milliseconds.

## Generators

A `Gen<Value>` is a value. There is no `Arbitrary` protocol: you build generators with functions,
and give a type as many generators as you need.

| | |
|---|---|
| Booleans | `.bool(probability:)` |
| Integers | `.int(in:)`, `Gen<T>.integer(in:)` for any `FixedWidthInteger` up to 128 bits |
| Floating point | `.double(in:allowNaN:allowInfinity:)`, `.float(in:...)` |
| Text | `.string(of: Alphabet, count:)`, `.character(of:)`, `.matching(regex)`, `.email`, `.url`, `.domain(maxLength:)` |
| Grammars | `.grammar(lark, start:imports:terminals:alphabet:maxSize:maxDepth:)` |
| Dates and times | `.calendarDate(in:)`, `.timeOfDay(in:)`, `.localDateTime(in:)`, `.date(in:)` (Foundation `Date`, UTC) |
| Identifiers | `.uuid(version:)`, `.ipv4`, `.ipv6` |
| Bytes | `.bytes(count:)` |
| Collections | `.array(of:count:)`, `.set(of:count:)`, `.dictionary(keys:values:count:)` |
| Choices | `.just(value)`, `.element(of:)`, `.oneOf(...)`, `.optional(gen)`, `Gen<E>.allCases` |
| Recursion | `.recursive(maxDepth:maxLeaves:leaf:branch:)`, `.deferred { gen }` |
| Combinators | `map`, `flatMap`, `filter`, `zip(a, b, ...)`, `a.zip(b, combine)`, `printed(with:)` |

Text, regex and grammar generators follow the Unicode version of the Swift standard library the
tests run with, so their categories and character classes agree with `Character` and
`Unicode.Scalar.Properties`.

```swift
struct User { var name: String; var age: Int }

let users: Gen<User> = zip(.string(of: .ascii, count: 1...20), .int(in: 0...120))
    .map(User.init)

let sortedPairs = zip(Gen.int(), Gen.int()).filter { $0 <= $1 }
```

For anything that doesn't fit a combinator, write the generator as a closure. Draws inside it
are not printed; the value it returns is:

```swift
let intervals = Gen { tc in
    let lo = try tc.draw(.int(in: 0...100))
    let hi = try tc.draw(.int(in: lo...100))
    return lo...hi
}
```

`.grammar` draws strings of a language written in
[Lark's syntax](https://lark-parser.readthedocs.io/en/stable/grammar.html). A failing string
shrinks through its parse tree, so it stays in the language:

```swift
let arithmetic = Gen.grammar(#"""
    start: expr
    expr: NUMBER | expr OP expr | "(" expr ")"
    OP: "+" | "-" | "*"
    NUMBER: /[0-9]/
    """#)
```

- `imports:` maps the paths that `%import` needs to their text. Lark's bundled `common`,
  `lark`, `python` and `unicode` grammars need no entry.
- `terminals:` gives a generator for each terminal the grammar `%declare`s, or for any terminal
  you want to override.

The standard library has no calendar types, so dates and times come as plain values:
`CalendarDate`, `TimeOfDay` and `LocalDateTime`, which have no time zone and print in ISO 8601.
`.date(in:)` draws a Foundation `Date` through UTC. IP addresses come as `IPv4Address` and
`IPv6Address`; each has its network-order `bytes` and prints in its standard text form.

Recursive values, such as trees and expressions, come from `recursive`. You give it a leaf
generator and a function from a generator of sub-values to one level of structure. The engine
decides where a value branches, keeps it within `maxDepth` and `maxLeaves`, and shrinks a failing
value toward a single leaf:

```swift
indirect enum Tree { case leaf(Int), node([Tree]) }

let trees: Gen<Tree> = .recursive(leaf: Gen.int().map(Tree.leaf)) { subtree in
    Gen.array(of: subtree, count: 1...3).map(Tree.node)
}
```

Write `Gen.array` inside `branch`: a bare `.array` would be read as a `Gen<Tree>`. For
generators that refer to each other, wrap the reference in `.deferred { ... }`. It is built on
first use. Nothing bounds its depth but the engine's budget for a test case.

Every generator shrinks through the engine. Shrinking edits the choices a generator made and
runs the generator again, so a shrunk value always satisfies the generator's own invariants. You
never write a shrinker.

Values print in the report as Swift renders them (`String(describing:)`, with strings quoted).
To print something else, such as hiding a secret, use `printed(with:)`. A generator built
directly with `Gen(label:draw:)` prints through the `Printer` it is given: `text`, `group`,
`breakable`, `reflow`, `value`, `speculate`.

## Stateful testing

A `StateMachine` tests a sequence of operations. You give it a model, which holds the system
under test and whatever you check it against. Rules change the model and invariants check it.
The engine picks which rules run and in what order. A failure shrinks to the fewest, simplest
steps:

```swift
struct Stack {
    var model: [Int] = []
    let real = MyStack()
}

let stack = StateMachine<Stack>()
    .rule("push") { s, tc in
        let x = try tc.draw(.int(), named: "x")
        s.model.append(x)
        s.real.push(x)
    }
    .rule("pop") { s, tc in
        try tc.assume(!s.model.isEmpty)
        #expect(s.real.pop() == s.model.removeLast())
    }
    .invariant("count") { s, _ in
        #expect(s.real.count == s.model.count)
    }

@Test(.hegel)
func stackBehaves() throws {
    try property { tc in
        try stack.run(tc, from: Stack())
    }
}
```

If `MyStack.pop` returns the wrong element, the report lists the steps that show it:

```
Expectation failed: s.real.pop() == s.model.removeLast()
  Falsifying example:
      Step 1: push {
        let x = 0
      }
      Step 2: pop {
      }
      Rule pop failed:
```

- A machine is a value. Build it once and run it in as many properties as you need. Each test
  case starts from the model you pass to `run`, so create the system under test there.
- A rule that rejects, with `assume`, `reject` or a draw from an empty pool, is skipped. The test
  case goes on with another rule.
- Every invariant is checked on the initial and the final state. Between steps, the engine
  checks each one about once per test case. Pass `everyStep: true` to check it after every step,
  which finds the failure at the step that causes it.
- Under [Antithesis](https://antithesis.com/), pass `pauseFaults: true` to pause fault injection
  while an invariant runs, so no fault lands in the middle of the check. Outside Antithesis it
  changes nothing. `tc.withFaultsPaused { … }` does the same for any other check. Both work on a
  `ConcurrentStateMachine` too.
- The run stops at the first failing step, whether it threw or an `#expect` failed.
- `steps:` sets how many steps the engine aims for (50 by default). `weight:` makes a rule more
  or less likely.
- Rules and invariants may be `async`. A machine with any async ones runs with
  `try await machine.run(tc, from:)`; the sync `run` throws a usage error for it.

A `Pool` holds values that later steps draw on, such as accounts opened or keys inserted. The
engine picks which value a draw gets, and shrinks that choice:

```swift
struct Bank {
    var balances: [String: Int] = [:]
    var accounts: Pool<String>
}

let bank = StateMachine<Bank>()
    .rule("open") { bank, tc in
        let name = try tc.draw(.string(of: .ascii, count: 1...8), named: "name")
        try tc.assume(bank.balances[name] == nil)
        bank.balances[name] = 0
        try bank.accounts.add(name)
    }
    .rule("close") { bank, tc in
        let name = try tc.draw(bank.accounts.consumed, named: "account")
        bank.balances[name] = nil
    }

try property { tc in
    try bank.run(tc, from: Bank(accounts: try tc.pool()))
}
```

Pools have three draws:

- `pool.reusable` leaves the value in the pool.
- `pool.consumed` removes it.
- `pool.consumed(where:)` removes only a value that matches. Use it instead of
  `consumed.filter`, which would also remove the values it rejects.

### Concurrent state machines

A `ConcurrentStateMachine` runs rules at the same time, on several workers, against one shared
model, to find races. The model must be `Sendable`: an actor, or a class that does its own
locking. Rules and invariants are async and get the model itself, not a copy:

```swift
let cache = ConcurrentStateMachine<Cache>(concurrency: 2...4)
    .rule("put", groups: ["writes"]) { cache, tc in
        let key = try tc.draw(.string(of: .ascii, count: 1...3), named: "key")
        await cache.put(key, "value")
    }
    .rule("get", groups: ["writes", "reads"]) { cache, tc in
        let key = try tc.draw(.string(of: .ascii, count: 1...3), named: "key")
        _ = await cache.get(key)
    }
    .invariant("size within capacity") { cache, _ in
        #expect(await cache.count <= cache.capacity)
    }

@Test(.hegel)
func cacheIsThreadSafe() async throws {
    try await property { tc in
        try await cache.run(tc, from: Cache(capacity: 8))
    }
}
```

- The run is split into rounds. In each one, the engine picks a concurrency group, and every
  active worker runs a sequence of that group's rules, at the same time as the others.
- Rules in the same group may overlap; rules that share no group never do. A rule in several
  groups runs in the rounds of each. By default every rule is in one group.
- `concurrency:` bounds the number of workers. The engine picks a level in that range,
  favouring the top, and may change it between rounds.
- Invariants run between rounds, while no rule is running.
- Each worker draws from its own test case. In the report, every line a worker printed starts
  with the worker and the time, under the round it ran in:

  ```
  Concurrency level: 2
  ---------------- Round 1: group "writes" ----------------
  [worker 0 +0.012ms] Rule: put {
  [worker 0 +0.013ms]   let key = "a"
  [worker 0 +0.020ms] }
  ```
- Workers may share a `Pool`. Add to it with `pool.add(value, using: tc)`, passing the rule's
  own test case.
- When several workers fail in one round, the first worker's failure is reported and the others
  are noted under it.

A race doesn't happen on every run. The engine notices when a failure comes and goes, and
handles it as the `nondeterminism` setting says: `.quiet` and `.warn` report it once it has been
confirmed, and `.error` fails the run.

## Settings

A run starts from the settings the engine resolves, in this order:

1. its built-in profiles: `development` locally, and `ci` when it detects a CI server (database
   off, derandomized);
2. a `hegel.toml` in the package root or above;
3. `HEGEL_*` environment variables.

Settings given in Swift override that result field by field.

```swift
@Test(.hegel(testCases: 500, seed: 42))
@Test(.hegel(profile: "nightly"))
@Test(.hegel(Settings(database: .disabled, reportMultipleFailures: true)))
```

```toml
# hegel.toml
[profiles.ci]
test_cases = 1_000

[profiles.nightly]
test_cases = 10_000
```

The engine writes its own output to standard error: verbose logs, statistics from
`showStatistics`, health check messages. `output:` sends it somewhere else, one line at a time:

```swift
@Test(.hegel(Settings(showStatistics: true)) { line in logger.info("\(line)") })
```

`Property.run` and `Property.check` take `output:` and `examples:` too.

## Reproducing a failure

Every report ends with a trait that replays the minimal example:

```swift
@Test(.hegel(reproducing: "AXicY2VgYGBkZOBiZEBhMAAAAd8AIQ=="))
```

The blob only works with the libhegel version that produced it. Remove the trait once the bug is
fixed.

## Without Swift Testing

`Hegel` has no test-framework dependency. `Property.check` throws a `PropertyFailure` when the
property throws. `Property.run` returns the outcome instead:

```swift
import Hegel

struct Overflow: Error {}

let outcome = try Property.run(settings: Settings(testCases: 200)) { tc in
    let n = try tc.draw(.int(), named: "n")
    if n.magnitude > UInt(Int.max) {
        throw Overflow()
    }
}
if case .failed(let failure) = outcome {
    print(failure.report())   // let n = -9223372036854775808
}
```

Run errors that give no verdict on the property are `HegelError`s: a failed health check, an
unsatisfiable or flaky test, or invalid settings.

## How it works

libhegel is Hegel's engine, written in Rust, exposed through a C ABI. It owns generation,
shrinking, the failure database, health checks and the final report's layout. hegel-swift drives
it in-process:

1. `hegel_run_start`, then `hegel_next_test_case` until the engine says the run is over.
2. Each test case runs your closure. Every draw is a span (`hegel_start_span`) around engine
   draws (`hegel_generate_*`, collections). Generators print into the engine's printer as they
   draw.
3. `hegel_mark_complete` reports the case: valid, rejected, overrun, or failing, with an
   *origin* that groups failures into distinct bugs. A failing case's origin is the source
   location of its first issue, or the type of the error it threw.
4. `hegel_run_result` gives the verdict, and for each bug its minimal example's reproduce blob.
   In Swift Testing, `property` replays that blob once with issues let through, so the issues
   you see are the real ones from the minimal example, annotated.

The library follows the
[frontend consistency plan](https://github.com/hegeldev/hegel/blob/main/plans/frontend-consistency.md)
the Hegel team keeps for every language:

- settings resolve in the engine;
- labels come from `hegel_label_from_name` and `hegel_label_combine`;
- printing goes through the engine printer;
- run errors are typed;
- filters use `HEGEL_FILTER_ATTEMPTS`.

## Following libhegel releases

The libhegel version is pinned in [`LIBHEGEL_VERSION`](LIBHEGEL_VERSION), and the header it ships
is checked in at [`libhegel/hegel.h`](libhegel/hegel.h).

- **[`Scripts/package-libhegel.sh`](Scripts/package-libhegel.sh)** downloads a libhegel release
  and checks every file against upstream's `.sha256`. It repackages the library as
  `Artifacts/CHegel.xcframework` for macOS and `Artifacts/CHegel.artifactbundle` for Linux and
  Windows, a static-library bundle. While `Artifacts/` exists, `Package.swift` builds against it. Without
  it, `Package.swift` downloads the zips from this repository's `libhegel-<version>` release,
  checked against the checksums in `Package.swift`.
- **The [libhegel bump](.github/workflows/libhegel-bump.yml) workflow** runs daily. When
  `hegeldev/hegel` publishes a newer `libhegel/<version>`, it:
  1. packages that version;
  2. runs the tests on macOS and on Linux (amd64 and arm64);
  3. publishes the zips as the `libhegel-<version>` release;
  4. opens a PR that moves `Package.swift`, `LIBHEGEL_VERSION` and `libhegel/hegel.h`.

  The `hegel.h` diff in that PR is the engine's ABI change to review. Add a `BUMP_TOKEN` secret
  (a token that can write contents and pull requests) for CI to run on those PRs as well.
- **[CI](.github/workflows/ci.yml)** lints, then tests on macOS, on Linux (Swift 6.3 and 6.4,
  amd64 and arm64) and on Windows (amd64 and arm64) against the pinned version. On `main`, it also checks that the released
  binaries resolve.

**First setup.** The release assets don't exist until the bump workflow publishes them. Run it
once by hand with the version `0.51.1`. It publishes `libhegel-0.51.1` and opens a PR with the
release's checksums.

## Limitations and roadmap

- **Platforms.** upstream publishes libhegel for macOS on Apple silicon, Linux and Windows. There
  are no iOS, tvOS, watchOS or visionOS slices yet, so property tests run on macOS, Linux and Windows only.
  iOS simulator slices can be built from the Rust sources and added to the XCFramework; the other
  Apple platforms need nightly Rust.
- **Traps.** A `fatalError`, failed `precondition` or force-unwrap in the code under test ends the
  test process. Hegel can't catch it or shrink it. Code that reports errors through `Result` and
  `throws` works fully.
- **Not yet wrapped:**
  - Windows

## Development

```bash
Scripts/package-libhegel.sh   # package the pinned libhegel into Artifacts/
swift test
swift format lint --strict --recursive Sources Tests Package.swift
```

To move to another libhegel by hand:

```bash
Scripts/bump-libhegel.sh 0.52.0
```

## License

MIT. libhegel, which the binary targets contain, is MIT licensed by Antithesis; see
[hegeldev/hegel](https://github.com/hegeldev/hegel).

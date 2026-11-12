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
- macOS 26 or later on Apple silicon, or Linux (x86_64 or arm64)

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

## Generators

A `Gen<Value>` is a value. There is no `Arbitrary` protocol: you build generators with functions,
and give a type as many generators as you need.

| | |
|---|---|
| Booleans | `.bool(probability:)` |
| Integers | `.int(in:)`, `Gen<T>.integer(in:)` for any `FixedWidthInteger` up to 128 bits |
| Floating point | `.double(in:allowNaN:allowInfinity:)`, `.float(in:...)` |
| Text | `.string(of: Alphabet, count:)`, `.character(of:)`, `.matching(regex)`, `.email`, `.url`, `.domain(maxLength:)` |
| Bytes | `.bytes(count:)` |
| Collections | `.array(of:count:)`, `.set(of:count:)`, `.dictionary(keys:values:count:)` |
| Choices | `.just(value)`, `.element(of:)`, `.oneOf(...)`, `.optional(gen)`, `Gen<E>.allCases` |
| Recursion | `.recursive(maxDepth:maxLeaves:leaf:branch:)`, `.deferred { gen }` |
| Combinators | `map`, `flatMap`, `filter`, `zip(a, b, ...)`, `a.zip(b, combine)`, `printed(with:)` |

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
- The run stops at the first failing step, whether it threw or an `#expect` failed.
- `steps:` sets how many steps the engine aims for (50 by default). `weight:` makes a rule more
  or less likely.

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
  `Artifacts/CHegel.xcframework` for macOS and `Artifacts/CHegel.artifactbundle` for Linux, a
  static-library bundle. While `Artifacts/` exists, `Package.swift` builds against it. Without
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
- **[CI](.github/workflows/ci.yml)** lints, then tests on macOS and on Linux (Swift 6.3 and 6.4,
  amd64 and arm64) against the pinned version. On `main`, it also checks that the released
  binaries resolve.

**First setup.** The release assets don't exist until the bump workflow publishes them. Run it
once by hand with the version `0.51.1`. It publishes `libhegel-0.51.1` and opens a PR with the
release's checksums.

## Limitations and roadmap

- **Platforms.** upstream publishes libhegel for macOS on Apple silicon, Linux and Windows. There
  are no iOS, tvOS, watchOS or visionOS slices yet, so property tests run on macOS and Linux only.
  iOS simulator slices can be built from the Rust sources and added to the XCFramework; the other
  Apple platforms need nightly Rust.
- **Traps.** A `fatalError`, failed `precondition` or force-unwrap in the code under test ends the
  test process. Hegel can't catch it or shrink it. Code that reports errors through `Result` and
  `throws` works fully.
- **Not yet wrapped:**
  - concurrent state machines (several workers running rules at once)
  - async rules and invariants
  - Lark grammars
  - dates, times, UUIDs and IP addresses
  - drawing from several threads (`hegel_test_case_clone`)
  - explicit examples
  - the engine's output callback (engine messages go to stderr)
  - Windows
- **Draw names.** Names in reports come from `named:`. A macro could take them from the `let`
  binding, as Rust and OCaml do.

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

import Synchronization

/// Values for one explicit example: a test case that runs with values you
/// give instead of generated ones.
///
/// Each value is keyed by the name its draw is reported under: `n` for
/// `tc.draw(gen, named: "n")`, `n_2` for the second draw named `n`, and
/// `draw_1`, `draw_2`, ... for unnamed draws.
///
/// ```swift
/// let outcome = try Property.run(examples: [["n": 0], ["n": Int.max]]) { tc in
///     let n = try tc.draw(.int(), named: "n")
///     ...
/// }
/// ```
///
/// A value's type must be the draw's exactly: give a `Double` draw `1.0`,
/// not `1`.
public struct Example: Sendable, ExpressibleByDictionaryLiteral {
    public var values: [String: any Sendable]

    public init(_ values: [String: any Sendable]) {
        self.values = values
    }

    public init(dictionaryLiteral elements: (String, any Sendable)...) {
        self.init(Dictionary(elements) { _, last in last })
    }
}

/// Serves an explicit example's draws: what a `TestCase` draws from in
/// place of the engine, and the lines its report shows. Shared by the
/// handles of one example, which may draw from several threads.
final class ExplicitDraws: Sendable {
    let example: Example

    private struct State {
        var used: Set<String> = []
        var lines: [String] = []
    }

    private let state = Mutex(State())

    init(_ example: Example) {
        self.example = example
    }

    /// The value given for the draw reported as `name`.
    func take<Value>(_ name: String, as _: Value.Type, indent: String) throws -> Value {
        guard let given = example.values[name] else {
            let names = example.values.keys.sorted().map { "\"\($0)\"" }
            throw HegelError.usage(
                "The explicit example has no value for the draw \"\(name)\". It has: "
                    + (names.isEmpty ? "none" : names.joined(separator: ", "))
            )
        }
        guard let value = given as? Value else {
            throw HegelError.usage(
                "The explicit example's value for \"\(name)\" is a \(type(of: given)), "
                    + "but the draw makes a \(Value.self)"
            )
        }
        state.withLock { state in
            state.used.insert(name)
            state.lines.append("\(indent)let \(name) = \(String(reflecting: value))")
        }
        return value
    }

    func record(_ line: String) {
        state.withLock { $0.lines.append(line) }
    }

    var lines: [String] {
        state.withLock { $0.lines }
    }

    /// The names given values that no draw took.
    var unused: [String] {
        let used = state.withLock { $0.used }
        return example.values.keys.filter { !used.contains($0) }.sorted()
    }
}

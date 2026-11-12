/// A generator of `Value`s: a plain value, built and combined with
/// functions instead of conformances.
///
/// A generator draws its value from a test case, printing it into the
/// failure report as it goes. There is no `Arbitrary` protocol: a type can
/// have as many generators as it needs, and generators for types you don't
/// own need no retroactive conformances.
///
/// ```swift
/// let user: Gen<User> = zip(.int(in: 0...120), .string()).map { User(age: $0, name: $1) }
/// ```
public struct Gen<Value>: Sendable {
    /// The label of the span every draw from this generator runs in.
    public let label: Label
    let body: @Sendable (TestCase, Printer) throws -> Value

    /// A generator that draws with `draw`, printing as it goes.
    ///
    /// `draw` should draw its components through
    /// `tc.draw(_:printer:)`, so each runs in its own span, and print what
    /// it produces into the printer it is given.
    public init(
        label: Label,
        draw: @escaping @Sendable (_ tc: TestCase, _ printer: Printer) throws -> Value
    ) {
        self.label = label
        self.body = draw
    }

    /// A generator written as a closure that draws from other generators.
    ///
    /// Draws inside the closure are not printed; the value it returns is,
    /// as `Printer.value(_:)` renders it. The closure's source location
    /// identifies the generator to the shrinker.
    public init(
        fileID: StaticString = #fileID,
        line: UInt = #line,
        column: UInt = #column,
        _ draw: @escaping @Sendable (_ tc: TestCase) throws -> Value
    ) {
        self.label = Label.composite.combined(with: .named("\(fileID):\(line):\(column)"))
        self.body = { tc, printer in
            let value = try draw(tc)
            printer.value(value)
            return value
        }
    }
}

// MARK: - Combinators

extension Gen {
    /// Transforms every value this generator produces. A thrown error fails
    /// the test case like an error thrown from the property.
    ///
    /// The report shows the transformed value.
    public func map<NewValue>(
        _ transform: @escaping @Sendable (Value) throws -> NewValue
    ) -> Gen<NewValue> {
        Gen<NewValue>(label: Label.map.combined(with: label)) { tc, printer in
            let value = try transform(body(tc, .disabled))
            printer.value(value)
            return value
        }
    }

    /// Draws a value, then draws from the generator `transform` makes of it.
    ///
    /// The report shows the value of the second draw.
    public func flatMap<NewValue>(
        _ transform: @escaping @Sendable (Value) throws -> Gen<NewValue>
    ) -> Gen<NewValue> {
        Gen<NewValue>(label: Label.flatMap.combined(with: label)) { tc, printer in
            let value = try tc.drawSilent(self)
            return try tc.draw(transform(value), printer: printer)
        }
    }

    /// Keeps only the values for which `isIncluded` holds.
    ///
    /// A few attempts are made per test case; when all of them fail the case
    /// is rejected. Prefer building the constraint into the generator, since
    /// a filter that rejects most values makes the run slow and trips the
    /// `filterTooMuch` health check.
    public func filter(_ isIncluded: @escaping @Sendable (Value) throws -> Bool) -> Gen<Value> {
        Gen(label: Label.filter.combined(with: label)) { tc, printer in
            for _ in 0..<filterAttempts {
                try tc.startSpan(.filterAttempt)
                do {
                    let value = try printer.speculate {
                        let value = try tc.draw(self, printer: printer)
                        guard try isIncluded(value) else {
                            throw FilterMiss()
                        }
                        return value
                    }
                    try tc.stopSpan()
                    return value
                } catch is FilterMiss {
                    try tc.stopSpan(discard: true)
                }
            }
            try tc.reject()
        }
    }

    /// The same generator with values printed by `print` instead of how this
    /// generator prints them. Use it for values with no useful
    /// representation, or to hide a secret.
    public func printed(with print: @escaping @Sendable (Value, Printer) -> Void) -> Gen<Value> {
        Gen(label: label) { tc, printer in
            let value = try body(tc, .disabled)
            print(value, printer)
            return value
        }
    }
}

/// The number of attempts a filter makes before rejecting the test case,
/// the engine's `HEGEL_FILTER_ATTEMPTS`, so filters reject equally often in
/// every Hegel library.
let filterAttempts = 3

private struct FilterMiss: Error {}

/// Combines generators into a generator of tuples.
///
/// ```swift
/// let point = zip(Gen.int(), Gen.int())   // Gen<(Int, Int)>
/// ```
public func zip<each Value>(_ generators: repeat Gen<each Value>) -> Gen<(repeat each Value)> {
    var labels: [Label] = []
    for generator in repeat each generators {
        labels.append(generator.label)
    }
    return Gen(label: Label.zip.combined(with: labels)) { tc, printer in
        try printer.group(indent: 1, open: "(", close: ")") {
            var first = true
            func next<V>(_ generator: Gen<V>) throws -> V {
                if !first {
                    printer.text(",")
                    printer.breakable(" ")
                }
                first = false
                return try tc.draw(generator, printer: printer)
            }
            return (repeat try next(each generators))
        }
    }
}

extension Gen {
    /// Draws from this generator and `other`, then combines the values.
    public func zip<Other, Result>(
        _ other: Gen<Other>,
        _ combine: @escaping @Sendable (Value, Other) throws -> Result
    ) -> Gen<Result> {
        Hegel.zip(self, other).map(combine)
    }

    /// Always produces `value`.
    public static func just(_ value: Value) -> Gen<Value> where Value: Sendable {
        Gen(label: .just) { _, printer in
            printer.value(value)
            return value
        }
    }

    /// Draws from one of `generators`. Shrinks toward the first.
    public static func oneOf(_ generators: Gen<Value>...) -> Gen<Value> {
        oneOf(generators)
    }

    /// Draws from one of `generators`. Shrinks toward the first.
    public static func oneOf(_ generators: [Gen<Value>]) -> Gen<Value> {
        precondition(!generators.isEmpty, "oneOf needs at least one generator")
        return Gen(label: Label.oneOf.combined(with: generators.map(\.label))) { tc, printer in
            let index = try tc.generateInteger(0, Int64(generators.count - 1))
            return try tc.draw(generators[Int(index)], printer: printer)
        }
    }

    /// One of `elements`. Shrinks toward the first.
    public static func element(of elements: [Value]) -> Gen<Value> where Value: Sendable {
        precondition(!elements.isEmpty, "element(of:) needs at least one element")
        return Gen(label: .element) { tc, printer in
            let index = try tc.generateInteger(0, Int64(elements.count - 1))
            let value = elements[Int(index)]
            printer.value(value)
            return value
        }
    }

    /// `nil` or a value from `wrapped`. Shrinks toward `nil`.
    public static func optional<Wrapped>(_ wrapped: Gen<Wrapped>) -> Gen<Value>
    where Value == Wrapped? {
        Gen(label: Label.optional.combined(with: wrapped.label)) { tc, printer in
            guard try tc.generateBool(probability: 0.5) else {
                printer.text("nil")
                return nil
            }
            return try tc.draw(wrapped, printer: printer)
        }
    }
}

extension Gen where Value: CaseIterable & Sendable {
    /// One of the type's cases. Shrinks toward the first.
    public static var allCases: Gen<Value> {
        element(of: Array(Value.allCases))
    }
}

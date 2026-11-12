public import Hegel

/// Draws a value from `generator`, named in reports after the `let` or `var`
/// it initializes.
///
/// ```swift
/// try property { tc in
///     let xs = try #draw(.array(of: .int()), from: tc)
///     #expect(mySort(xs) == xs.sorted())
/// }
/// ```
///
/// is `tc.draw(.array(of: .int()), named: "xs")`. A draw that doesn't
/// initialize a plain binding, such as one inside a closure, a tuple
/// pattern or `_ =`, is unnamed: the report calls it `draw_1`, `draw_2`, and
/// so on. A draw nested in a larger initializer takes that binding's name,
/// so for `let xs = [try #draw(.int(), from: tc)]` the report shows
/// `let xs = 0`; use `tc.draw(_:named:)` there.
@freestanding(expression)
public macro draw<Value>(_ generator: Gen<Value>, from testCase: TestCase) -> Value =
    #externalMacro(module: "HegelMacros", type: "DrawMacro")

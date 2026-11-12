import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// Expands `#draw(generator, from: tc)` to
/// `tc.draw(generator, named: "<name>")`, taking the name from the `let`
/// or `var` the macro initializes.
///
/// The macro sees its enclosing declarations through the lexical context,
/// which skips over expressions other than `try`, `await` and closures. So
/// `let n = try #draw(...)` is named `n`, a draw inside a closure or a
/// destructuring pattern is unnamed (`draw_1`, ...), and a draw nested in a
/// larger initializer, as in `let xs = [try #draw(...)]`, takes that
/// binding's name.
public struct DrawMacro: ExpressionMacro {
    public static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) throws -> ExprSyntax {
        let arguments = Array(node.arguments)
        guard arguments.count == 2 else {
            throw DrawMacroError("#draw takes a generator and `from:` a test case")
        }
        let generator = arguments[0].expression
        let testCase = arguments[1].expression
        let name: ExprSyntax =
            bindingName(in: context).map { "\(literal: $0)" } ?? "nil"
        return "\(testCase).draw(\(generator), named: \(name))"
    }

    /// The name of the single-identifier binding that encloses the macro, if
    /// the nearest enclosing context other than `try` or `await` is one.
    static func bindingName(in context: some MacroExpansionContext) -> String? {
        let enclosing = context.lexicalContext.first {
            !$0.is(TryExprSyntax.self) && !$0.is(AwaitExprSyntax.self)
        }
        // The compiler hands over the enclosing declaration with only the
        // binding the macro is in first, and without its initializer. (In
        // `let a = ..., b = ...`, `a` keeps its trailing comma, followed by
        // an empty binding.)
        guard let variable = enclosing?.as(VariableDeclSyntax.self),
            let pattern = variable.bindings.first?.pattern.as(IdentifierPatternSyntax.self)
        else {
            return nil
        }
        return pattern.identifier.text
    }
}

struct DrawMacroError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

@main
struct HegelMacrosPlugin: CompilerPlugin {
    let providingMacros: [any Macro.Type] = [DrawMacro.self]
}

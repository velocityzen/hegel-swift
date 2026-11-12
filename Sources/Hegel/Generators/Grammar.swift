import CHegel

extension Gen where Value == String {
    /// Strings a grammar accepts, written in
    /// [Lark's syntax](https://lark-parser.readthedocs.io/en/stable/grammar.html).
    ///
    /// ```swift
    /// let arithmetic = Gen.grammar(#"""
    ///     start: expr
    ///     expr: NUMBER | expr OP expr | "(" expr ")"
    ///     OP: "+" | "-" | "*"
    ///     %import common.NUMBER
    ///     """#)
    /// ```
    ///
    /// A failing string shrinks through its parse tree, so it stays in the
    /// language. The grammar is compiled once, when the generator is made; a
    /// grammar that doesn't compile fails each test that draws from it with
    /// the engine's explanation.
    ///
    /// - Parameters:
    ///   - lark: The grammar.
    ///   - start: The rule whose strings to draw; `start` when nil.
    ///   - imports: The text of files the grammar `%import`s, by path:
    ///     `%import a.b.X` needs `"a/b.lark"`. Lark's bundled `common`,
    ///     `lark`, `python` and `unicode` grammars need no entry.
    ///   - terminals: Generators for terminals whose values you supply: every
    ///     terminal the grammar `%declare`s, and any you want to override.
    ///     Their values are spliced in as drawn, so draw ones that read as
    ///     that terminal where they land.
    ///   - alphabet: The characters terminals' patterns may draw.
    ///   - maxSize: The most characters a string may have; 8192 when nil.
    ///   - maxDepth: How deeply rules may nest; 200 when nil.
    public static func grammar(
        _ lark: String,
        start: String? = nil,
        imports: [String: String] = [:],
        terminals: [String: Gen<String>] = [:],
        alphabet: Alphabet? = nil,
        maxSize: Int? = nil,
        maxDepth: Int? = nil
    ) -> Gen<String> {
        let names = terminals.keys.sorted()
        let handle = GrammarHandle(
            lark,
            start: start,
            imports: imports,
            explicitNames: names,
            alphabet: alphabet,
            maxSize: UInt64(max(maxSize ?? 0, 0)),
            maxDepth: UInt32(clamping: max(maxDepth ?? 0, 0))
        )
        let generators = names.map { terminals[$0]! }
        let label = Label.grammar.combined(with: generators.map(\.label))
        return Gen(label: label) { tc, printer in
            guard let grammar = handle.raw else {
                throw HegelError.usage(handle.failure ?? "invalid grammar")
            }
            let value =
                generators.isEmpty
                ? try generate(grammar, tc)
                : try generate(grammar, tc, terminals: generators)
            printer.text(String(reflecting: value))
            return value
        }
    }
}

private func generate(_ grammar: OpaquePointer, _ tc: TestCase) throws -> String {
    var result = hegel_owned_string_t()
    try tc.call { hegel_generate_grammar($0, tc.raw, grammar, 0, &result) }
    defer { hegel_owned_string_free(nil, &result) }
    return String(hegelString: result)
}

/// Draws a string whose explicit terminals take values from `terminals`,
/// indexed like the names the grammar was compiled with.
private func generate(
    _ grammar: OpaquePointer,
    _ tc: TestCase,
    terminals: [Gen<String>]
) throws -> String {
    var handle: OpaquePointer?
    try tc.call { hegel_grammar_draw_new($0, grammar, 0, &handle) }
    guard let draw = handle else {
        throw HegelError.engine("libhegel returned no grammar draw handle")
    }
    defer { hegel_grammar_draw_free(nil, draw) }
    var index = 0
    while try tc.call(
        allowing: HEGEL_E_NOT_FOUND,
        { hegel_grammar_draw_next($0, tc.raw, draw, &index) }
    ) {
        guard terminals.indices.contains(index) else {
            throw HegelError.engine("libhegel asked for terminal \(index) of \(terminals.count)")
        }
        let value = try tc.draw(terminals[index], printer: .disabled)
        try value.withHegelString { (view) throws in
            try tc.call { hegel_grammar_draw_provide($0, draw, view) }
        }
    }
    var result = hegel_owned_string_t()
    try tc.call { hegel_grammar_draw_result($0, draw, &result) }
    defer { hegel_owned_string_free(nil, &result) }
    return String(hegelString: result)
}

/// A compiled `hegel_grammar_t`, or why it didn't compile.
private final class GrammarHandle: @unchecked Sendable {
    let raw: OpaquePointer?
    let failure: String?

    init(
        _ lark: String,
        start: String?,
        imports: [String: String],
        explicitNames: [String],
        alphabet: Alphabet?,
        maxSize: UInt64,
        maxDepth: UInt32
    ) {
        unicodeVersionSet
        let context = EngineContext()
        do {
            let builder = try Self.gather(lark, imports: imports, context)
            defer { hegel_grammar_builder_free(nil, builder) }
            let characters = alphabet.map {
                StringGeneratorHandle.text($0, minCount: 0, maxCount: maxSizeDefault)
            }
            if let characters, characters.raw == nil {
                throw EngineError(code: HEGEL_E_INVALID_ARG, message: characters.failure ?? "")
            }
            var grammar: OpaquePointer?
            try withOptionalHegelString(start) { start throws(EngineError) in
                try withHegelStrings(explicitNames) { names, count throws(EngineError) in
                    try context.call {
                        hegel_grammar_new(
                            $0,
                            builder,
                            start,
                            maxSize,
                            maxDepth,
                            characters?.raw,
                            names,
                            count,
                            &grammar
                        )
                    }
                }
            }
            raw = grammar
            failure = grammar == nil ? "libhegel returned no grammar" : nil
        } catch {
            raw = nil
            failure = (error as? EngineError)?.message ?? "\(error)"
        }
    }

    deinit {
        hegel_grammar_free(nil, raw)
    }

    /// A builder holding `lark` and every file it imports, transitively.
    private static func gather(
        _ lark: String,
        imports: [String: String],
        _ context: EngineContext
    ) throws(EngineError) -> OpaquePointer {
        var handle: OpaquePointer?
        try lark.withHegelString { (text) throws(EngineError) in
            try context.call { hegel_grammar_builder_new($0, text, &handle) }
        }
        guard let builder = handle else {
            throw EngineError(
                code: HEGEL_E_INVALID_ARG,
                message: "libhegel returned no grammar builder"
            )
        }
        var index = 0
        while true {
            var pathView = hegel_string_t()
            guard hegel_grammar_builder_file(context.raw, builder, index, &pathView) == HEGEL_OK
            else {
                // `HEGEL_E_NOT_FOUND`: every file is provided.
                break
            }
            let path = String(hegelString: pathView)
            do {
                // A missing file falls back to Lark's bundled grammar there.
                try withOptionalHegelString(imports[path]) { (text) throws(EngineError) in
                    try context.call { hegel_grammar_builder_provide($0, builder, index, text) }
                }
            } catch {
                hegel_grammar_builder_free(nil, builder)
                throw error
            }
            index += 1
        }
        return builder
    }
}

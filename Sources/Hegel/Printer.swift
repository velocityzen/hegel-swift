import CHegel

/// Lays out drawn values in a failure report.
///
/// Each generator prints the values it draws, as it draws them, into the
/// engine's printer, which fits them to the line: a group prints on one line
/// when it fits and breaks at every `breakable` when it does not. Printing
/// only happens on the test cases a report can be built from; elsewhere the
/// printer is disabled and every call is a no-op.
public final class Printer {
    private let raw: OpaquePointer?
    private let context: EngineContext?

    init(raw: OpaquePointer, context: EngineContext) {
        self.raw = raw
        self.context = context
    }

    private init() {
        raw = nil
        context = nil
    }

    /// A printer that prints nothing.
    public static var disabled: Printer { Printer() }

    deinit {
        if let raw {
            hegel_printer_free(nil, raw)
        }
    }

    /// Whether anything printed here can appear in a report.
    public var isEnabled: Bool { raw != nil }

    private func call(_ body: (OpaquePointer, OpaquePointer) -> hegel_result_t) {
        guard let raw, let context else {
            return
        }
        // Printing is best effort: a region whose document was already read
        // reports an error that only means the output is no longer wanted.
        _ = body(context.raw, raw)
    }

    private func call(
        _ text: String,
        _ body: (OpaquePointer, OpaquePointer, hegel_string_t) -> hegel_result_t
    ) {
        guard raw != nil else {
            return
        }
        text.withHegelString { view in
            call { body($0, $1, view) }
        }
    }

    /// Literal text, which must not contain newlines.
    public func text(_ text: String) {
        call(text, hegel_printer_text)
    }

    /// A break point: `separator` when the group fits on one line, a newline
    /// when it does not.
    public func breakable(_ separator: String = " ") {
        call(separator, hegel_printer_breakable)
    }

    /// Text printed only when the enclosing group breaks.
    public func ifBreak(_ text: String) {
        call(text, hegel_printer_if_break)
    }

    /// An unconditional newline.
    public func hardBreak() {
        call { hegel_printer_hard_break($0, $1) }
    }

    /// A comment at the end of the current line, such as `"  // shrunk"`.
    public func comment(_ text: String) {
        call(text, hegel_printer_comment)
    }

    /// Prints `open`, then `body` indented by `indent` at break points, then
    /// `close`.
    public func group<R, E: Error>(
        indent: Int = 4,
        open: String,
        close: String,
        _ body: () throws(E) -> R
    ) throws(E) -> R {
        open.withHegelString { view in
            call { hegel_printer_begin_group($0, $1, UInt64(max(indent, 0)), view) }
        }
        defer { call(close, hegel_printer_end_group) }
        return try body()
    }

    /// Prints a sequence as `open a, b, c close`, one item per line when it
    /// does not fit.
    public func sequence<Item, E: Error>(
        open: String,
        close: String,
        _ items: some Sequence<Item>,
        _ printItem: (Item) throws(E) -> Void
    ) throws(E) {
        try group(indent: 4, open: open, close: close) { () throws(E) in
            breakable("")
            var first = true
            for item in items {
                if !first {
                    text(",")
                    breakable(" ")
                }
                first = false
                try printItem(item)
            }
            ifBreak(",")
            breakable("")
        }
    }

    /// Prints a flat representation of a value, re-wrapped through groups at
    /// its brackets so a long one breaks like structured output.
    public func reflow(_ representation: String) {
        call(representation) { context, raw, view in
            hegel_printer_reflow(context, raw, nil, view)
        }
    }

    /// Prints a value as Swift renders it: strings and characters quoted,
    /// everything else as `String(describing:)` does, which leaves type names
    /// unqualified.
    public func value(_ value: some Any) {
        guard isEnabled else {
            return
        }
        reflow(Self.representation(of: value))
    }

    static func representation(of value: some Any) -> String {
        switch value {
            case let value as String: String(reflecting: value)
            case let value as Substring: String(reflecting: value)
            case let value as Character: String(reflecting: value)
            default: String(describing: value)
        }
    }

    /// Runs `body` with its output held back: kept if `body` returns, and
    /// discarded if it throws. This is how a rejected attempt leaves no trace
    /// in the report.
    public func speculate<R, E: Error>(_ body: () throws(E) -> R) throws(E) -> R {
        call { hegel_printer_begin_speculative($0, $1) }
        do {
            let result = try body()
            call { hegel_printer_commit_speculative($0, $1) }
            return result
        } catch {
            call { hegel_printer_abort_speculative($0, $1) }
            throw error
        }
    }

    /// Reads the document. Only valid on a test case's root printer, and
    /// seals it: later writes are ignored.
    func read() -> [String]? {
        guard let raw, let context else {
            return nil
        }
        var result = hegel_printer_value_result_t()
        guard hegel_printer_value(context.raw, raw, &result) == HEGEL_OK else {
            return ["Failed to render this test case's drawn values: \(context.lastError)"]
        }
        defer { hegel_printer_value_result_free(nil, &result) }
        let text = String(hegelString: hegel_string_t(data: result.data, len: result.len))
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while lines.last?.isEmpty == true {
            lines.removeLast()
        }
        return lines
    }
}

import CHegel
import Synchronization

/// One execution of a property, and the values drawn for it.
///
/// A property draws its inputs from generators through the test case:
///
/// ```swift
/// let xs = try tc.draw(.array(of: .int()), named: "xs")
/// ```
///
/// Draws throw to end the test case early when the engine rejects it or has
/// used up its budget. Let those errors propagate: a property that catches
/// them and carries on is still ended, but does extra work for nothing.
///
/// A test case belongs to the property body it was passed to. Don't keep it
/// after the body returns or hand it to another thread.
public final class TestCase {
    /// The engine's handle, or nil for an explicit example.
    let raw: OpaquePointer?
    let context: EngineContext
    /// Where an explicit example's draws come from, instead of the engine.
    let explicit: ExplicitDraws?
    /// How far an explicit example's lines from this handle are indented.
    private let explicitIndent: String
    /// Whether this case prints its draws: only the cases a failure report
    /// can be built from do.
    let printsOutput: Bool

    private var rootPrinter: Printer?
    /// The names this handle's draws are shown under. Shared with clones
    /// and with the iterations of `repeat`, fresh for a state machine step.
    private let names: DrawNames
    private var nesting = 0
    /// The number of spans this handle has open.
    private(set) var spanDepth = 0
    var stop: TestCaseStop?
    /// Whether the test framework has recorded a failure for this case
    /// without a thrown error, as `#expect` does. State machines check it
    /// to stop at the failing step.
    package var hasRecordedFailure: () -> Bool = { false }

    init(
        raw: OpaquePointer,
        context: EngineContext,
        printsOutput: Bool,
        names: DrawNames = DrawNames()
    ) {
        self.raw = raw
        self.context = context
        self.printsOutput = printsOutput
        self.names = names
        explicit = nil
        explicitIndent = ""
    }

    /// A test case for an explicit example: it draws `example`'s values and
    /// makes no engine calls.
    init(example: ExplicitDraws, indent: String = "", names: DrawNames = DrawNames()) {
        raw = nil
        context = EngineContext()
        printsOutput = false
        explicit = example
        explicitIndent = indent
        self.names = names
    }

    deinit {
        rootPrinter = nil
        if let raw {
            hegel_test_case_free(nil, raw)
        }
    }

    /// A handle onto an independent choice stream of this test case, for
    /// concurrent worker `worker`: its output lines are prefixed with the
    /// worker and the time. It has its own engine context, so it can be
    /// driven from another thread while this handle waits.
    func clone(worker: Int) throws -> TestCase {
        if let explicit {
            let clone = TestCase(example: explicit, indent: explicitIndent, names: names)
            clone.hasRecordedFailure = hasRecordedFailure
            return clone
        }
        var handle: OpaquePointer?
        try call { hegel_test_case_clone($0, raw, &handle) }
        guard let handle else {
            throw HegelError.engine("libhegel returned no test case clone")
        }
        let clone = TestCase(
            raw: handle,
            context: EngineContext(),
            printsOutput: printsOutput,
            names: names
        )
        clone.hasRecordedFailure = hasRecordedFailure
        try clone.call { hegel_test_case_set_worker($0, handle, Int64(worker)) }
        return clone
    }

    /// A handle onto this case's choices whose output is an indented block
    /// at the current position of this one's: the body of a state machine
    /// step or a `repeat` iteration under its heading. A step's draws are
    /// named afresh; an iteration's carry on from this handle's.
    func block(indent: Int, sharingNames: Bool = false) throws -> TestCase {
        if let explicit {
            let block = TestCase(
                example: explicit,
                indent: explicitIndent + String(repeating: " ", count: indent),
                names: sharingNames ? names : DrawNames()
            )
            block.hasRecordedFailure = hasRecordedFailure
            return block
        }
        var handle: OpaquePointer?
        try call { hegel_test_case_block($0, raw, UInt64(indent), &handle) }
        guard let handle else {
            throw HegelError.engine("libhegel returned no block handle")
        }
        let block = TestCase(
            raw: handle,
            context: context,
            printsOutput: printsOutput,
            names: sharingNames ? names : DrawNames()
        )
        block.hasRecordedFailure = hasRecordedFailure
        return block
    }

    private var printer: Printer {
        if let rootPrinter {
            return rootPrinter
        }
        var handle: OpaquePointer?
        guard printsOutput, hegel_test_case_printer(context.raw, raw, nil, &handle) == HEGEL_OK,
            let handle
        else {
            let disabled = Printer.disabled
            rootPrinter = disabled
            return disabled
        }
        let printer = Printer(raw: handle, context: context)
        rootPrinter = printer
        return printer
    }

    /// The lines printed for this case: its drawn values and notes.
    func readOutput() -> [String] {
        if let explicit {
            return explicit.lines
        }
        guard printsOutput else {
            return []
        }
        return printer.read() ?? []
    }

    // MARK: - Drawing

    /// Draws a value from `generator`.
    ///
    /// On a failing example the report shows it as `let name = value`. An
    /// unnamed draw is called `draw_1`, `draw_2`, and so on; a name used
    /// twice gets a numbered suffix.
    public func draw<Value>(_ generator: Gen<Value>, named name: String? = nil) throws -> Value {
        if let explicit {
            return try explicit.take(names.allocate(name), as: Value.self, indent: explicitIndent)
        }
        guard printsOutput, nesting == 0 else {
            return try drawSilent(generator)
        }
        let displayName = names.allocate(name)
        let printer = self.printer
        return try printer.speculate {
            printer.text("let \(displayName) = ")
            let value = try draw(generator, printer: printer)
            printer.hardBreak()
            return value
        }
    }

    /// Draws a value from `generator` without showing it in the report.
    public func drawSilent<Value>(_ generator: Gen<Value>) throws -> Value {
        if explicit != nil {
            throw HegelError.usage(
                "drawSilent isn't supported in explicit examples: draw with tc.draw(_:named:)"
            )
        }
        return try draw(generator, printer: .disabled)
    }

    /// Draws from `generator` inside a span labelled with its label,
    /// printing the value into `printer` as it is drawn.
    ///
    /// This is how a generator built from other generators draws its
    /// components: the span groups each component's choices for the
    /// shrinker.
    public func draw<Value>(_ generator: Gen<Value>, printer: Printer) throws -> Value {
        try startSpan(generator.label)
        nesting += 1
        defer { nesting -= 1 }
        let value = try generator.body(self, printer)
        try stopSpan()
        return value
    }

    // MARK: - Control

    /// Rejects this test case unless `condition` holds. A rejected case does
    /// not count against the test-case budget.
    public func assume(_ condition: Bool) throws {
        if !condition {
            try reject()
        }
    }

    /// Rejects this test case.
    public func reject() throws -> Never {
        stop = .rejected
        throw TestCaseStop.rejected
    }

    /// Adds a line to the report of a failing example.
    public func note(_ message: String) {
        if let explicit {
            explicit.record(explicitIndent + message)
            return
        }
        guard printsOutput else {
            return
        }
        message.withHegelString { view in
            _ = hegel_note(context.raw, raw, view)
        }
    }

    /// Steers generation toward test cases that score higher on `label`.
    /// Each label may be recorded once per test case.
    public func target(_ score: Double, label: String = "") throws {
        guard explicit == nil else {
            return
        }
        try label.withHegelString { (view) throws in
            try call { hegel_target($0, raw, score, view) }
        }
    }

    /// Records that `label` happened in this test case, for the statistics
    /// report.
    public func event(_ label: String) throws {
        guard explicit == nil else {
            return
        }
        try label.withHegelString { (view) throws in
            try call { hegel_event($0, raw, view) }
        }
    }

    /// Records a numeric observation under `label`, for the statistics
    /// report.
    public func event(_ label: String, value: Double) throws {
        guard explicit == nil else {
            return
        }
        try label.withHegelString { (view) throws in
            try call { hegel_event_value($0, raw, value, view) }
        }
    }

    // MARK: - Engine primitives

    /// Calls libhegel on this test case, turning a stop into the error that
    /// ends the case and any other failure into a usage error.
    func call(_ body: (OpaquePointer) -> hegel_result_t) throws {
        // `HEGEL_OK` is never thrown, so no other result is let through.
        _ = try call(allowing: HEGEL_OK, body)
    }

    /// Like `call`, but returns false instead of throwing when the engine
    /// answers `HEGEL_E_RETRY`.
    func callAllowingRetry(_ body: (OpaquePointer) -> hegel_result_t) throws -> Bool {
        try call(allowing: HEGEL_E_RETRY, body)
    }

    /// Like `call`, but returns false instead of throwing when the engine
    /// answers `expected`.
    func call(
        allowing expected: hegel_result_t,
        _ body: (OpaquePointer) -> hegel_result_t
    ) throws -> Bool {
        if explicit != nil {
            throw HegelError.usage(
                """
                Explicit examples make no engine calls, so they support draw(_:named:), \
                note, assume, reject, target, event, repeat and concurrently, but not \
                pools, state machines, spans or a generator's own draws
                """
            )
        }
        do {
            try context.call(body)
            return true
        } catch {
            if error.code == expected {
                return false
            }
            if error.isStopTest {
                stop = .overrun
                throw TestCaseStop.overrun
            }
            if error.isAssume {
                stop = .rejected
                throw TestCaseStop.rejected
            }
            throw HegelError.usage(error.message)
        }
    }

    /// Opens a span: the draws until the matching `stopSpan` are one unit to
    /// the shrinker.
    public func startSpan(_ label: Label) throws {
        try call { hegel_start_span($0, raw, label.rawValue) }
        spanDepth += 1
    }

    /// Closes the most recent span. `discard` tells the shrinker its draws
    /// did not contribute to the value, as for a rejected filter attempt.
    public func stopSpan(discard: Bool = false) throws {
        try call { hegel_stop_span($0, raw, discard) }
        spanDepth -= 1
    }

    /// Forgets the spans above `depth`, after the engine has closed them
    /// itself, as it does for a discarded recursion attempt.
    func resetSpanDepth(to depth: Int) {
        precondition(spanDepth >= depth, "span depth below the recursion's start")
        spanDepth = depth
    }

    func generateBool(probability: Double) throws -> Bool {
        var value = false
        try call { hegel_generate_boolean($0, raw, probability, false, false, &value) }
        return value
    }

    func generateInteger(_ min: Int64, _ max: Int64) throws -> Int64 {
        var value: Int64 = 0
        try call { hegel_generate_integer($0, raw, min, max, &value) }
        return value
    }

    /// Draws an integer whose bounds may not fit in 64 bits, as
    /// two's-complement little-endian bytes.
    func generateBigInteger(_ min: [UInt8], _ max: [UInt8], capacity: Int) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: capacity)
        var length = 0
        try min.withUnsafeBufferPointer { minBuffer in
            try max.withUnsafeBufferPointer { maxBuffer in
                try out.withUnsafeMutableBufferPointer { outBuffer in
                    try call {
                        hegel_generate_integer_big(
                            $0,
                            raw,
                            minBuffer.baseAddress,
                            minBuffer.count,
                            maxBuffer.baseAddress,
                            maxBuffer.count,
                            outBuffer.baseAddress,
                            outBuffer.count,
                            &length
                        )
                    }
                }
            }
        }
        return out
    }

    func generateFloat(
        width: UInt32,
        min: Double,
        max: Double,
        allowNaN: Bool,
        allowInfinity: Bool,
        excludeMin: Bool,
        excludeMax: Bool,
        smallestNonzeroMagnitude: Double
    ) throws -> Double {
        var value = 0.0
        try call {
            hegel_generate_float(
                $0,
                raw,
                width,
                min,
                max,
                allowNaN,
                allowInfinity,
                excludeMin,
                excludeMax,
                smallestNonzeroMagnitude,
                &value
            )
        }
        return value
    }

    func generateBytes(minCount: UInt64, maxCount: UInt64) throws -> [UInt8] {
        var result = hegel_generate_bytes_result_t()
        try call { hegel_generate_bytes($0, raw, minCount, maxCount, &result) }
        defer { hegel_generate_bytes_result_free(nil, &result) }
        return Array(UnsafeBufferPointer(start: result.data, count: result.len))
    }

    func generateString(_ generator: OpaquePointer) throws -> String {
        var result = hegel_owned_string_t()
        try call { hegel_generate_string($0, raw, generator, &result) }
        defer { hegel_owned_string_free(nil, &result) }
        return String(hegelString: result)
    }

    func newCollection(minCount: UInt64, maxCount: UInt64) throws -> Collection {
        var handle: OpaquePointer?
        try call { hegel_new_collection($0, raw, minCount, maxCount, &handle) }
        guard let handle else {
            throw HegelError.engine("libhegel returned no collection handle")
        }
        return Collection(raw: handle, testCase: self)
    }

    /// An engine-sized collection: the engine decides how many elements to
    /// draw, so the length shrinks.
    final class Collection {
        let raw: OpaquePointer
        unowned let testCase: TestCase

        init(raw: OpaquePointer, testCase: TestCase) {
            self.raw = raw
            self.testCase = testCase
        }

        deinit {
            hegel_collection_free(nil, raw)
        }

        func more() throws -> Bool {
            var more = false
            try testCase.call { hegel_collection_more($0, testCase.raw, raw, &more) }
            return more
        }

        /// Tells the engine the last element was invalid, such as a
        /// duplicate in a set.
        func reject() throws {
            try testCase.call { hegel_collection_reject($0, testCase.raw, raw, nil) }
        }
    }
}

/// Why a test case ended before its body finished.
public enum TestCaseStop: Error, Sendable {
    /// An assumption failed; the case is discarded.
    case rejected
    /// The engine used up its choice budget for the case.
    case overrun
}

/// The names draws are shown under in a report: `draw_1`, `draw_2`, ... for
/// unnamed ones, and a numbered suffix for a name used again. Clones on
/// other threads share it, hence the lock.
final class DrawNames: Sendable {
    private struct State {
        var drawNumber = 0
        var used: [String: Int] = [:]
    }

    private let state = Mutex(State())

    func allocate(_ name: String?) -> String {
        state.withLock { state in
            guard let name else {
                state.drawNumber += 1
                return "draw_\(state.drawNumber)"
            }
            let count = state.used[name, default: 0] + 1
            state.used[name] = count
            return count == 1 ? name : "\(name)_\(count)"
        }
    }
}

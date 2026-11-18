import CHegel

/// Runs properties: functions of a `TestCase` that should hold for every
/// value they draw.
///
/// ```swift
/// try Property.check { tc in
///     let xs = try tc.draw(.array(of: .int()), named: "xs")
///     guard xs.reversed().reversed() == xs else { throw Mismatch() }
/// }
/// ```
///
/// A property fails by throwing. The engine then shrinks the failing input
/// to a minimal one and the run ends with a `PropertyFailure` describing it.
/// In Swift Testing, use `property` from `HegelTesting` instead, which also
/// treats `#expect` failures as property failures.
public enum Property {
    /// Runs `body` against generated test cases and returns the outcome.
    ///
    /// - Parameters:
    ///   - settings: Overrides for the engine's resolved settings.
    ///   - databaseKey: Scopes stored failing examples, and seeds
    ///     derandomized runs. Give each property a stable, distinct key.
    ///   - location: Where the property is defined.
    ///   - blob: A reproduce blob from a failure report: replay that example
    ///     instead of exploring. The explicit examples don't run.
    ///   - examples: Explicit examples, run first, in order, with the values
    ///     they give. A failing one ends the run, unless the
    ///     `reportMultipleFailures` setting is on. They run only when the
    ///     `explicit` phase is enabled.
    ///   - reaching: Reach claims: event labels that some passing generated
    ///     case must record with `tc.event`, or the run throws
    ///     `HegelError.unreached`. They show that the property tested the
    ///     states it exists for. A run that fails, replays a blob or doesn't
    ///     generate doesn't judge them.
    ///   - reachingAfter: Reach claims for states too rare for a short run,
    ///     each with the number of generated cases that must pass before the
    ///     run judges it: `["boundary": 1_000]` claims `"boundary"` on runs
    ///     of 1,000 passing cases or more, however that count was set.
    ///   - output: Receives the engine's output, one line at a time, instead
    ///     of standard error: statistics, health check messages and, in a
    ///     verbose run, each test case's draws and notes as it runs. It can
    ///     be called on any thread that runs the property's test case, such
    ///     as a concurrent worker's, and must not use the test case.
    /// - Throws: `HegelError` when the run ends without a verdict, such as a
    ///   failed health check.
    public static func run(
        settings: Settings = Settings(),
        databaseKey: String? = nil,
        location: TestLocation? = nil,
        reproducing blob: String? = nil,
        examples: [Example] = [],
        reaching: [String] = [],
        reachingAfter: [String: Int] = [:],
        output: (@Sendable (String) -> Void)? = nil,
        _ body: (TestCase) throws -> Void
    ) throws(HegelError) -> PropertyOutcome {
        let driver = try RunDriver(
            settings: settings,
            databaseKey: databaseKey,
            location: location,
            blob: blob,
            output: output
        )
        var explicitFailures: [PropertyFailure.Counterexample] = []
        for example in driver.examplesToRun(examples) {
            let tc = TestCase(example: ExplicitDraws(example))
            let outcome = Result { try body(tc) }
            if let failure = try finishExample(tc, outcome) {
                explicitFailures.append(failure)
                if !driver.settings.reportMultipleFailures {
                    return .failed(PropertyFailure(counterexamples: explicitFailures))
                }
            }
        }
        while let tc = try driver.nextTestCase() {
            let outcome = Result { try body(tc) }
            try driver.finish(tc, outcome)
        }
        let outcome = try driver.outcome().adding(explicitFailures)
        try driver.checkReaching(reaching, after: reachingAfter, outcome)
        return outcome
    }

    /// Runs the asynchronous `body` against generated test cases and returns
    /// the outcome. See
    /// `run(settings:databaseKey:location:reproducing:examples:output:_:)`.
    public static func run(
        settings: Settings = Settings(),
        databaseKey: String? = nil,
        location: TestLocation? = nil,
        reproducing blob: String? = nil,
        examples: [Example] = [],
        reaching: [String] = [],
        reachingAfter: [String: Int] = [:],
        output: (@Sendable (String) -> Void)? = nil,
        _ body: (TestCase) async throws -> Void
    ) async throws(HegelError) -> PropertyOutcome {
        let driver = try RunDriver(
            settings: settings,
            databaseKey: databaseKey,
            location: location,
            blob: blob,
            output: output
        )
        var explicitFailures: [PropertyFailure.Counterexample] = []
        for example in driver.examplesToRun(examples) {
            let tc = TestCase(example: ExplicitDraws(example))
            let outcome = await result { try await body(tc) }
            if let failure = try finishExample(tc, outcome) {
                explicitFailures.append(failure)
                if !driver.settings.reportMultipleFailures {
                    return .failed(PropertyFailure(counterexamples: explicitFailures))
                }
            }
        }
        while let tc = try driver.nextTestCase() {
            let outcome = await result { try await body(tc) }
            try driver.finish(tc, outcome)
        }
        let outcome = try driver.outcome().adding(explicitFailures)
        try driver.checkReaching(reaching, after: reachingAfter, outcome)
        return outcome
    }

    /// Runs `body` against generated test cases, throwing a
    /// `PropertyFailure` if it fails.
    public static func check(
        settings: Settings = Settings(),
        databaseKey: String? = nil,
        location: TestLocation? = nil,
        reproducing blob: String? = nil,
        examples: [Example] = [],
        reaching: [String] = [],
        reachingAfter: [String: Int] = [:],
        output: (@Sendable (String) -> Void)? = nil,
        _ body: (TestCase) throws -> Void
    ) throws {
        let outcome = try run(
            settings: settings,
            databaseKey: databaseKey,
            location: location,
            reproducing: blob,
            examples: examples,
            reaching: reaching,
            reachingAfter: reachingAfter,
            output: output,
            body
        )
        if case .failed(let failure) = outcome {
            throw failure
        }
    }

    /// Runs the asynchronous `body` against generated test cases, throwing a
    /// `PropertyFailure` if it fails.
    public static func check(
        settings: Settings = Settings(),
        databaseKey: String? = nil,
        location: TestLocation? = nil,
        reproducing blob: String? = nil,
        examples: [Example] = [],
        reaching: [String] = [],
        reachingAfter: [String: Int] = [:],
        output: (@Sendable (String) -> Void)? = nil,
        _ body: (TestCase) async throws -> Void
    ) async throws {
        let outcome = try await run(
            settings: settings,
            databaseKey: databaseKey,
            location: location,
            reproducing: blob,
            examples: examples,
            reaching: reaching,
            reachingAfter: reachingAfter,
            output: output,
            body
        )
        if case .failed(let failure) = outcome {
            throw failure
        }
    }

    private static func result(
        _ body: () async throws -> Void
    ) async -> Result<Void, any Error> {
        do {
            try await body()
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    /// The failure an explicit example ended with, if it failed.
    private static func finishExample(
        _ tc: TestCase,
        _ outcome: Result<Void, any Error>
    ) throws(HegelError) -> PropertyFailure.Counterexample? {
        guard let explicit = tc.explicit else {
            preconditionFailure("not an explicit example")
        }
        switch outcome {
            case .failure(TestCaseStop.rejected), .failure(TestCaseStop.overrun):
                throw .usage("Explicit examples must not be rejected")
            case .failure(let error as HegelError):
                throw error
            case .success, .failure(is RepeatFinished):
                let unused = explicit.unused
                guard unused.isEmpty else {
                    throw .usage(
                        "The explicit example gives values that no draw took: "
                            + unused.map { "\"\($0)\"" }.joined(separator: ", ")
                    )
                }
                return nil
            case .failure(let error):
                return PropertyFailure.Counterexample(
                    origin: origin(of: error),
                    error: error,
                    drawn: explicit.lines,
                    example: explicit.example
                )
        }
    }
}

/// How a property run ended.
public enum PropertyOutcome {
    /// The property held for every test case.
    case passed
    /// The property failed; the failure holds every distinct minimal
    /// counterexample.
    case failed(PropertyFailure)

    public var failure: PropertyFailure? {
        if case .failed(let failure) = self {
            return failure
        }
        return nil
    }

    /// This outcome with the explicit examples' failures first. A generated
    /// failure with the same origin as one of them is the same bug, and is
    /// dropped.
    func adding(_ explicitFailures: [PropertyFailure.Counterexample]) -> PropertyOutcome {
        guard !explicitFailures.isEmpty else {
            return self
        }
        let origins = Set(explicitFailures.map(\.origin))
        let generated = failure?.counterexamples.filter { !origins.contains($0.origin) } ?? []
        return .failed(PropertyFailure(counterexamples: explicitFailures + generated))
    }
}

/// Drives one libhegel run: hands out the test cases the engine schedules,
/// reports how each ended, and keeps the report material of failing ones.
final class RunDriver {
    private let context = EngineContext()
    let settings: EngineSettings
    private let run: OpaquePointer
    /// Kept alive for the run, which calls back into it until it is freed.
    private let output: OutputSink?
    private let blob: String?
    private let verbosity: Settings.Verbosity
    /// The error each failure's report shows, by origin: the one from the
    /// latest failing case of that origin whose output the engine used,
    /// which is the case the engine reports.
    private var errors: [String: any Error] = [:]
    /// What this run's cases have shown about their stalls.
    private let stallLog = StallLog()
    /// How many passing generated cases recorded each event label.
    private var reached: [String: Int] = [:]
    /// How many generated cases passed.
    private var passingCases = 0

    init(
        settings: Settings,
        databaseKey: String?,
        location: TestLocation?,
        blob: String?,
        output: (@Sendable (String) -> Void)?
    ) throws(HegelError) {
        let version = engineVersion
        guard version == expectedEngineVersion else {
            throw .versionMismatch(expected: expectedEngineVersion, actual: version)
        }
        self.settings = try EngineSettings(settings, databaseKey: databaseKey, location: location)
        self.blob = blob
        verbosity = self.settings.verbosity
        let output = output.map(OutputSink.init)
        self.output = output
        // Without a handler the engine writes to standard error: a NULL
        // callback would mean no destination at all.
        let callback = output == nil ? hegel_output_stderr_callback() : OutputSink.callback
        let userData = output.map { Unmanaged.passUnretained($0).toOpaque() }
        var handle: OpaquePointer?
        let engineSettings = self.settings.raw
        let context = self.context
        do {
            if let blob {
                try blob.withHegelString { (view) throws(EngineError) in
                    try context.call {
                        hegel_run_start_blob($0, engineSettings, view, callback, userData, &handle)
                    }
                }
            } else {
                try context.call {
                    hegel_run_start($0, engineSettings, callback, userData, &handle)
                }
            }
        } catch {
            throw .usage(error.message)
        }
        guard let handle else {
            throw .engine("libhegel returned no run handle")
        }
        run = handle
    }

    deinit {
        hegel_run_free(nil, run)
    }

    /// The explicit examples this run runs: none when it replays a blob or
    /// the `explicit` phase is off.
    func examplesToRun(_ examples: [Example]) -> [Example] {
        blob == nil && settings.phases.contains(.explicit) ? examples : []
    }

    func nextTestCase() throws(HegelError) -> TestCase? {
        var handle: OpaquePointer?
        do {
            try context.call { hegel_next_test_case($0, run, &handle) }
        } catch {
            throw .engine(error.message)
        }
        guard let handle else {
            return nil
        }
        var wantsOutput = false
        var wantsDetail = false
        do {
            try context.call { hegel_test_case_wants_output($0, handle, &wantsOutput) }
            try context.call { hegel_test_case_wants_detail($0, handle, &wantsDetail) }
        } catch {
            hegel_test_case_free(nil, handle)
            throw .engine(error.message)
        }
        let reported = Self.isStamped(
            verbosity: verbosity,
            wantsOutput: wantsOutput,
            wantsDetail: wantsDetail
        )
        return TestCase(
            raw: handle,
            context: context,
            printsOutput: wantsOutput,
            run: CaseRun(
                stalls: CaseStalls(log: stallLog, reported: reported),
                wantsDetail: wantsDetail
            )
        )
    }

    /// Whether the engine stamped a test case for capture: whether its
    /// failure can become the report. The engine doesn't expose the stamp,
    /// but at quiet and normal verbosity a case wants its output only when
    /// stamped, and at verbose it wants its detail only when stamped. At
    /// debug every case wants both, so every case counts as stamped.
    static func isStamped(
        verbosity: Settings.Verbosity,
        wantsOutput: Bool,
        wantsDetail: Bool
    ) -> Bool {
        switch verbosity {
            // A quiet run's stamped cases still want output; a normal run
            // uses only theirs.
            case .quiet, .normal: wantsOutput
            // A verbose run streams every case, but wants the detail of
            // only the stamped ones.
            case .verbose: wantsDetail
            case .debug: true
        }
    }

    func finish(_ tc: TestCase, _ outcome: Result<Void, any Error>) throws(HegelError) {
        var status = HEGEL_STATUS_VALID
        var failure: (origin: String, error: any Error)?
        var usageError: HegelError?

        switch (outcome, tc.stop) {
            case (_, .rejected?):
                status = HEGEL_STATUS_INVALID
            case (_, .overrun?):
                status = HEGEL_STATUS_OVERRUN
            case (.success, nil), (.failure(is RepeatFinished), nil):
                break
            // A stop thrown from a block handle, such as a state machine
            // step's, that the root handle did not see.
            case (.failure(TestCaseStop.rejected), nil):
                status = HEGEL_STATUS_INVALID
            case (.failure(TestCaseStop.overrun), nil):
                status = HEGEL_STATUS_OVERRUN
            case (.failure(let error as HegelError), nil):
                usageError = error
            case (.failure(let error), nil):
                status = HEGEL_STATUS_INTERESTING
                failure = (origin(of: error), error)
        }

        // The engine reports the latest failing case of each origin whose
        // output it used; until one is seen, keep any.
        if let failure, tc.printsOutput || errors[failure.origin] == nil {
            errors[failure.origin] = failure.error
        }
        if status == HEGEL_STATUS_VALID, usageError == nil, let run = tc.run {
            run.stalls.commitPassing()
            passingCases += 1
            for label in run.events {
                reached[label, default: 0] += 1
            }
        }

        // C enums import as UInt32 with Clang's defaults and as Int32 on
        // Windows, where MSVC makes them `int`.
        let completionStatus = UInt32(truncatingIfNeeded: status.rawValue)
        // A failure says what the engine prints of it: a summary when it
        // uses the case's output, the full detail when it uses that too.
        let summary = failure.flatMap { tc.printsOutput ? failureSummary(of: $0.error) : nil }
        let detail = failure.flatMap {
            tc.run?.wantsDetail == true ? failureDetail(of: $0.error) : nil
        }
        let code = withOptionalHegelString(failure?.origin) { origin in
            withOptionalHegelString(summary) { summary in
                withOptionalHegelString(detail) { detail in
                    hegel_mark_complete(
                        context.raw,
                        tc.raw,
                        completionStatus,
                        origin,
                        summary,
                        detail
                    )
                }
            }
        }
        if let usageError {
            throw usageError
        }
        if code != HEGEL_OK {
            throw .engine(context.lastError)
        }
    }

    /// Checks a passing run's reach claims: each label in `labels` was
    /// recorded with `event` by at least one passing generated case.
    ///
    /// A run that can't judge them doesn't: one that failed, replays a
    /// reproduce blob, or doesn't generate.
    ///
    /// A label in `after` is judged only when at least its value's number
    /// of generated cases passed.
    func checkReaching(
        _ labels: [String],
        after gated: [String: Int],
        _ outcome: PropertyOutcome
    ) throws(HegelError) {
        let labels = Property.reachClaims(labels, after: gated, passingCases: passingCases)
        guard !labels.isEmpty, outcome.failure == nil, blob == nil,
            settings.phases.contains(.generate)
        else {
            return
        }
        let unreached = labels.filter { reached[$0, default: 0] == 0 }
        if !unreached.isEmpty {
            throw .unreached(unreached, testCases: passingCases)
        }
    }

    func outcome() throws(HegelError) -> PropertyOutcome {
        var result: OpaquePointer?
        do {
            try context.call { hegel_run_result($0, run, &result) }
        } catch {
            throw .engine(error.message)
        }
        guard let result else {
            throw .engine("libhegel returned no run result")
        }
        defer { hegel_run_result_free(nil, result) }

        var status = HEGEL_RUN_STATUS_PASSED
        hegel_run_result_status(nil, result, &status)
        switch status {
            case HEGEL_RUN_STATUS_PASSED:
                if let blob {
                    throw .notReproduced(blob: blob)
                }
                return .passed
            case HEGEL_RUN_STATUS_ERROR:
                throw runError(result)
            default:
                return .failed(PropertyFailure(counterexamples: counterexamples(result)))
        }
    }

    private func runError(_ result: OpaquePointer) -> HegelError {
        var messagePointer: UnsafePointer<hegel_string_t>?
        hegel_run_result_error(nil, result, &messagePointer)
        let message = messagePointer.map { String(hegelString: $0.pointee) } ?? "the run failed"
        var kind = HEGEL_RUN_ERROR_NONE
        var check: UInt32 = 0
        hegel_run_result_error_kind(nil, result, &kind, &check)
        switch kind {
            case HEGEL_RUN_ERROR_HEALTH_CHECK:
                return .healthCheck(HealthCheck(rawValue: check), message: message)
            case HEGEL_RUN_ERROR_FLAKY:
                return .flaky(message)
            case HEGEL_RUN_ERROR_NONDETERMINISTIC:
                return .nondeterministic(message)
            case HEGEL_RUN_ERROR_UNSATISFIABLE:
                return .unsatisfiable(message)
            case HEGEL_RUN_ERROR_USAGE:
                return .usage(message)
            default:
                return .engine(message)
        }
    }

    private func counterexamples(_ result: OpaquePointer) -> [PropertyFailure.Counterexample] {
        var count = 0
        hegel_run_result_failure_count(nil, result, &count)
        let printBlob = settings.printBlob
        return (0..<count).compactMap { index in
            var failure: OpaquePointer?
            hegel_run_result_failure(nil, result, index, &failure)
            guard let failure else {
                return nil
            }
            defer { hegel_failure_free(nil, failure) }

            var originView = hegel_string_t()
            hegel_failure_origin(nil, failure, &originView)
            let origin = String(hegelString: originView)

            var blobPointer: UnsafePointer<hegel_string_t>?
            hegel_failure_reproduction_blob(nil, failure, &blobPointer)
            let blob = blobPointer.map { String(hegelString: $0.pointee) }

            var caveatPointer: UnsafePointer<hegel_string_t>?
            hegel_failure_caveat(nil, failure, &caveatPointer)
            let caveat = caveatPointer.map { String(hegelString: $0.pointee) }

            // What the reported case printed: its draws and notes.
            var outputPointer: UnsafePointer<hegel_string_t>?
            hegel_failure_output(nil, failure, &outputPointer)
            let drawn = outputPointer.map { Self.lines(String(hegelString: $0.pointee)) } ?? []

            var diagnosticPointer: UnsafePointer<hegel_string_t>?
            hegel_failure_diagnostic(nil, failure, &diagnosticPointer)
            let diagnostic = diagnosticPointer.map { String(hegelString: $0.pointee) }

            return PropertyFailure.Counterexample(
                origin: origin,
                error: errors[origin] ?? UncapturedFailure(origin: origin, diagnostic: diagnostic),
                drawn: drawn,
                caveat: caveat,
                reproductionBlob: blob,
                printsReproduction: printBlob
            )
        }
    }

    /// `text` split into lines, without the empty ones at its end.
    static func lines(_ text: String) -> [String] {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while lines.last?.isEmpty == true {
            lines.removeLast()
        }
        return lines
    }
}

/// Runs `body` with a view of `text`, or with nil when there is no text.
private func withOptionalHegelString<R>(
    _ text: String?,
    _ body: (UnsafePointer<hegel_string_t>?) -> R
) -> R {
    guard let text else {
        return body(nil)
    }
    return text.withHegelString { view in
        withUnsafePointer(to: view) { body($0) }
    }
}

/// A failure the engine reported from a test case this run did not see
/// fail, such as one replayed from the database by an earlier version.
struct UncapturedFailure: Error, CustomStringConvertible {
    let origin: String
    /// The diagnostic the engine kept for the failure, if it kept one.
    var diagnostic: String?
    var description: String { diagnostic ?? origin }
}

/// Where a run sends the engine's output lines.
final class OutputSink: Sendable {
    let handler: @Sendable (String) -> Void

    init(_ handler: @escaping @Sendable (String) -> Void) {
        self.handler = handler
    }

    /// The C callback: `userData` is an unretained `OutputSink` that the
    /// run's driver keeps alive.
    static let callback: hegel_output_callback_t = { userData, line, length in
        guard let userData else {
            return
        }
        let sink = Unmanaged<OutputSink>.fromOpaque(userData).takeUnretainedValue()
        let bytes = UnsafeRawBufferPointer(start: line, count: line == nil ? 0 : length)
        sink.handler(String(decoding: bytes, as: UTF8.self))
    }
}

extension Property {
    /// The reach claims a run that passed `passingCases` generated cases
    /// judges: every label in `labels`, then the labels in `gated` whose
    /// threshold is at most `passingCases`, ordered by threshold and then
    /// label, each label once.
    static func reachClaims(
        _ labels: [String],
        after gated: [String: Int],
        passingCases: Int
    ) -> [String] {
        var seen = Set<String>()
        let due = gated.filter { $0.value <= passingCases }
            .sorted { ($0.value, $0.key) < ($1.value, $1.key) }
            .map(\.key)
        return (labels + due).filter { seen.insert($0).inserted }
    }
}

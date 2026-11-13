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
    ///   - output: Receives the engine's output, one line at a time, instead
    ///     of standard error: statistics, verbose logs and health check
    ///     messages. It is called on the thread that runs the property.
    /// - Throws: `HegelError` when the run ends without a verdict, such as a
    ///   failed health check.
    public static func run(
        settings: Settings = Settings(),
        databaseKey: String? = nil,
        location: TestLocation? = nil,
        reproducing blob: String? = nil,
        examples: [Example] = [],
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
        return try driver.outcome().adding(explicitFailures)
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
        return try driver.outcome().adding(explicitFailures)
    }

    /// Runs `body` against generated test cases, throwing a
    /// `PropertyFailure` if it fails.
    public static func check(
        settings: Settings = Settings(),
        databaseKey: String? = nil,
        location: TestLocation? = nil,
        reproducing blob: String? = nil,
        examples: [Example] = [],
        output: (@Sendable (String) -> Void)? = nil,
        _ body: (TestCase) throws -> Void
    ) throws {
        let outcome = try run(
            settings: settings,
            databaseKey: databaseKey,
            location: location,
            reproducing: blob,
            examples: examples,
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
        output: (@Sendable (String) -> Void)? = nil,
        _ body: (TestCase) async throws -> Void
    ) async throws {
        let outcome = try await run(
            settings: settings,
            databaseKey: databaseKey,
            location: location,
            reproducing: blob,
            examples: examples,
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
                    drawn: tc.readOutput(),
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
    /// Kept alive for the run, which calls back into it.
    private let output: OutputSink?
    private let blob: String?
    private let verbosity: Settings.Verbosity
    private var captures: [String: Capture] = [:]
    /// What this run's cases have shown about their stalls.
    private let stallLog = StallLog()

    /// What a failing test case leaves for its report.
    private struct Capture {
        var drawn: [String]
        var error: any Error
    }

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
        let callback: hegel_output_callback_t? = output == nil ? nil : OutputSink.callback
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
        var stamped = false
        hegel_test_case_should_capture(nil, handle, &stamped)
        let printsOutput =
            switch verbosity {
                case .quiet: false
                case .normal: stamped
                case .verbose, .debug: true
            }
        return TestCase(
            raw: handle,
            context: context,
            printsOutput: printsOutput,
            stalls: CaseStalls(log: stallLog, reported: stamped)
        )
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

        if let failure {
            store(origin: failure.origin, Capture(drawn: tc.readOutput(), error: failure.error))
        }
        if status == HEGEL_STATUS_VALID, usageError == nil {
            tc.stalls?.commitPassing()
        }

        // C enums import as UInt32 with Clang's defaults and as Int32 on
        // Windows, where MSVC makes them `int`.
        let completionStatus = UInt32(truncatingIfNeeded: status.rawValue)
        let code: hegel_result_t =
            if let origin = failure?.origin {
                origin.withHegelString { view in
                    var view = view
                    return hegel_mark_complete(context.raw, tc.raw, completionStatus, &view)
                }
            } else {
                hegel_mark_complete(context.raw, tc.raw, completionStatus, nil)
            }
        if let usageError {
            throw usageError
        }
        if code != HEGEL_OK {
            throw .engine(context.lastError)
        }
    }

    /// Keeps the newest capture for an origin unless it has less to show
    /// than the one already stored.
    private func store(origin: String, _ capture: Capture) {
        if let stored = captures[origin], !stored.drawn.isEmpty, capture.drawn.isEmpty {
            return
        }
        captures[origin] = capture
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

            let capture = captures[origin]
            return PropertyFailure.Counterexample(
                origin: origin,
                error: capture?.error ?? UncapturedFailure(origin: origin),
                drawn: capture?.drawn ?? [],
                caveat: caveat,
                reproductionBlob: blob,
                printsReproduction: printBlob
            )
        }
    }
}

/// A failure the engine reported from a test case this run did not see
/// fail, such as one replayed from the database by an earlier version.
struct UncapturedFailure: Error, CustomStringConvertible {
    let origin: String
    var description: String { origin }
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

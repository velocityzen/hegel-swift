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
    ///     instead of exploring.
    /// - Throws: `HegelError` when the run ends without a verdict, such as a
    ///   failed health check.
    public static func run(
        settings: Settings = Settings(),
        databaseKey: String? = nil,
        location: TestLocation? = nil,
        reproducing blob: String? = nil,
        _ body: (TestCase) throws -> Void
    ) throws(HegelError) -> PropertyOutcome {
        let driver = try RunDriver(
            settings: settings,
            databaseKey: databaseKey,
            location: location,
            blob: blob
        )
        while let tc = try driver.nextTestCase() {
            let outcome = Result { try body(tc) }
            try driver.finish(tc, outcome)
        }
        return try driver.outcome()
    }

    /// Runs the asynchronous `body` against generated test cases and returns
    /// the outcome. See `run(settings:databaseKey:location:reproducing:_:)`.
    public static func run(
        settings: Settings = Settings(),
        databaseKey: String? = nil,
        location: TestLocation? = nil,
        reproducing blob: String? = nil,
        _ body: (TestCase) async throws -> Void
    ) async throws(HegelError) -> PropertyOutcome {
        let driver = try RunDriver(
            settings: settings,
            databaseKey: databaseKey,
            location: location,
            blob: blob
        )
        while let tc = try driver.nextTestCase() {
            let outcome: Result<Void, any Error>
            do {
                try await body(tc)
                outcome = .success(())
            } catch {
                outcome = .failure(error)
            }
            try driver.finish(tc, outcome)
        }
        return try driver.outcome()
    }

    /// Runs `body` against generated test cases, throwing a
    /// `PropertyFailure` if it fails.
    public static func check(
        settings: Settings = Settings(),
        databaseKey: String? = nil,
        location: TestLocation? = nil,
        reproducing blob: String? = nil,
        _ body: (TestCase) throws -> Void
    ) throws {
        let outcome = try run(
            settings: settings,
            databaseKey: databaseKey,
            location: location,
            reproducing: blob,
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
        _ body: (TestCase) async throws -> Void
    ) async throws {
        let outcome = try await run(
            settings: settings,
            databaseKey: databaseKey,
            location: location,
            reproducing: blob,
            body
        )
        if case .failed(let failure) = outcome {
            throw failure
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
}

/// Drives one libhegel run: hands out the test cases the engine schedules,
/// reports how each ended, and keeps the report material of failing ones.
final class RunDriver {
    private let context = EngineContext()
    private let settings: EngineSettings
    private let run: OpaquePointer
    private let blob: String?
    private let verbosity: Settings.Verbosity
    private var captures: [String: Capture] = [:]

    /// What a failing test case leaves for its report.
    private struct Capture {
        var drawn: [String]
        var error: any Error
    }

    init(
        settings: Settings,
        databaseKey: String?,
        location: TestLocation?,
        blob: String?
    ) throws(HegelError) {
        let version = engineVersion
        guard version == expectedEngineVersion else {
            throw .versionMismatch(expected: expectedEngineVersion, actual: version)
        }
        self.settings = try EngineSettings(settings, databaseKey: databaseKey, location: location)
        self.blob = blob
        verbosity = self.settings.verbosity
        var handle: OpaquePointer?
        let engineSettings = self.settings.raw
        let context = self.context
        do {
            if let blob {
                try blob.withHegelString { (view) throws(EngineError) in
                    try context.call {
                        hegel_run_start_blob($0, engineSettings, view, nil, nil, &handle)
                    }
                }
            } else {
                try context.call { hegel_run_start($0, engineSettings, nil, nil, &handle) }
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
        return TestCase(raw: handle, context: context, printsOutput: printsOutput)
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
            case (.success, nil):
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

        let code: hegel_result_t =
            if let origin = failure?.origin {
                origin.withHegelString { view in
                    var view = view
                    return hegel_mark_complete(context.raw, tc.raw, status.rawValue, &view)
                }
            } else {
                hegel_mark_complete(context.raw, tc.raw, status.rawValue, nil)
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

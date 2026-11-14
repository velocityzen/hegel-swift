import CHegel

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Overrides for one property run.
///
/// Every field is optional. A run starts from the settings the engine
/// resolves (its built-in profiles, `hegel.toml`, and the `HEGEL_*`
/// environment variables, as described in the libhegel reference), and only
/// the fields set here replace what that resolution produced.
///
/// The one exception is `testCases`: a `HEGEL_TEST_CASES` environment
/// variable wins over it, so `HEGEL_TEST_CASES=10000 swift test` runs every
/// property deeper, including those whose test count is set in Swift.
/// `HEGEL_TEST_CASES_SCALE=50` multiplies whatever count a property
/// resolves to instead, so expensive properties stay cheaper than cheap
/// ones in a deep run.
public struct Settings: Sendable, Equatable {
    /// The profile to start from instead of the default one: `development`,
    /// `ci`, `workload`, `base`, or one defined in `hegel.toml`.
    public var profile: String?
    /// The number of valid test cases to run before the property is
    /// considered to hold. Rejected cases do not count.
    ///
    /// This is the property's own count, so it wins over `hegel.toml`
    /// profiles: a profile's `test_cases` applies only to properties that
    /// don't set one. A `HEGEL_TEST_CASES` environment variable, chosen for
    /// one run, wins over it, and `HEGEL_TEST_CASES_SCALE` multiplies it.
    public var testCases: Int?
    /// A fixed seed for generation.
    public var seed: UInt64?
    /// Derive the seed from the test's database key instead of fresh
    /// randomness, so repeated runs of one test see the same inputs.
    public var derandomize: Bool?
    /// Where failing examples are stored and replayed from.
    public var database: Database?
    /// How much the engine reports while it runs.
    public var verbosity: Verbosity?
    /// Which phases of the run are enabled.
    public var phases: Phases?
    /// Health checks that are switched off.
    public var suppressedHealthChecks: HealthCheck?
    /// Whether a failure report includes the blob that reproduces it.
    public var printBlob: Bool?
    /// Keep looking for distinct failures after the first one.
    public var reportMultipleFailures: Bool?
    /// Stop generating once a failure is found.
    public var stopOnFirstFailure: Bool?
    /// Print statistics for `event` calls at the end of the run.
    public var showStatistics: Bool?
    /// Lift the limit on the number of choices one test case may make.
    public var unboundedChoices: Bool?
    /// How the run reacts to a test that behaves differently when replayed.
    public var nondeterminism: Nondeterminism?
    /// The source of randomness.
    public var backend: Backend?

    public init(
        profile: String? = nil,
        testCases: Int? = nil,
        seed: UInt64? = nil,
        derandomize: Bool? = nil,
        database: Database? = nil,
        verbosity: Verbosity? = nil,
        phases: Phases? = nil,
        suppressedHealthChecks: HealthCheck? = nil,
        printBlob: Bool? = nil,
        reportMultipleFailures: Bool? = nil,
        stopOnFirstFailure: Bool? = nil,
        showStatistics: Bool? = nil,
        unboundedChoices: Bool? = nil,
        nondeterminism: Nondeterminism? = nil,
        backend: Backend? = nil
    ) {
        self.profile = profile
        self.testCases = testCases
        self.seed = seed
        self.derandomize = derandomize
        self.database = database
        self.verbosity = verbosity
        self.phases = phases
        self.suppressedHealthChecks = suppressedHealthChecks
        self.printBlob = printBlob
        self.reportMultipleFailures = reportMultipleFailures
        self.stopOnFirstFailure = stopOnFirstFailure
        self.showStatistics = showStatistics
        self.unboundedChoices = unboundedChoices
        self.nondeterminism = nondeterminism
        self.backend = backend
    }

    /// These settings with every field `other` sets replaced by its value.
    public func merging(_ other: Settings) -> Settings {
        Settings(
            profile: other.profile ?? profile,
            testCases: other.testCases ?? testCases,
            seed: other.seed ?? seed,
            derandomize: other.derandomize ?? derandomize,
            database: other.database ?? database,
            verbosity: other.verbosity ?? verbosity,
            phases: other.phases ?? phases,
            suppressedHealthChecks: other.suppressedHealthChecks ?? suppressedHealthChecks,
            printBlob: other.printBlob ?? printBlob,
            reportMultipleFailures: other.reportMultipleFailures ?? reportMultipleFailures,
            stopOnFirstFailure: other.stopOnFirstFailure ?? stopOnFirstFailure,
            showStatistics: other.showStatistics ?? showStatistics,
            unboundedChoices: other.unboundedChoices ?? unboundedChoices,
            nondeterminism: other.nondeterminism ?? nondeterminism,
            backend: other.backend ?? backend
        )
    }
}

extension Settings {
    /// The environment variable that sets the number of test cases for a run.
    static let testCasesVariable = "HEGEL_TEST_CASES"

    /// These settings with the fields an explicit run-time choice in
    /// `environment` wins over left to the engine: `testCases`, when
    /// `HEGEL_TEST_CASES` is set. The engine ignores an empty variable, so
    /// this does too.
    func yieldingTo(environment: [String: String]) -> Settings {
        guard let value = environment[Self.testCasesVariable], !value.isEmpty else {
            return self
        }
        var settings = self
        settings.testCases = nil
        return settings
    }

    /// The environment variable that multiplies every property's test count.
    static let testCasesScaleVariable = "HEGEL_TEST_CASES_SCALE"

    /// The test count a run uses once `HEGEL_TEST_CASES_SCALE` in
    /// `environment` multiplies `resolved`, or `nil` when nothing scales
    /// it: the variable is unset or empty, or `HEGEL_TEST_CASES` is set and
    /// wins outright.
    ///
    /// The scale is a positive, finite number, so `0.1` makes a quick run
    /// as well as `50` a deep one. The result rounds up, is at least 1, and
    /// saturates at `UInt64.max`.
    static func scaledTestCases(
        _ resolved: UInt64,
        environment: [String: String]
    ) throws(HegelError) -> UInt64? {
        guard let value = environment[testCasesScaleVariable], !value.isEmpty,
            (environment[testCasesVariable] ?? "").isEmpty
        else {
            return nil
        }
        guard let scale = Double(value), scale.isFinite, scale > 0 else {
            throw .usage(
                "\(testCasesScaleVariable) must be a positive number, got \"\(value)\""
            )
        }
        let scaled = (Double(resolved) * scale).rounded(.up)
        guard scaled < Double(UInt64.max) else { return .max }
        return max(1, UInt64(scaled))
    }
}

extension Settings {
    /// Where failing examples are stored.
    public enum Database: Sendable, Equatable {
        /// The engine's default location, `.hegel/examples/`.
        case `default`
        /// No database: failures are not stored or replayed.
        case disabled
        /// A database rooted at this directory.
        case path(String)
    }

    public enum Verbosity: UInt32, Sendable, Equatable {
        case normal = 0
        case quiet = 1
        case verbose = 2
        case debug = 3
    }

    public enum Nondeterminism: UInt32, Sendable, Equatable {
        /// Confirm failures by replaying them, silently.
        case quiet = 0
        /// As quiet, with a one-line notice.
        case warn = 1
        /// Fail the run.
        case error = 2
    }

    public enum Backend: UInt32, Sendable, Equatable {
        case `default` = 1
        /// Fresh entropy on every draw; meant for running under Antithesis.
        case urandom = 2
    }

    public struct Phases: OptionSet, Sendable, Hashable {
        public let rawValue: UInt32

        public init(rawValue: UInt32) {
            self.rawValue = rawValue
        }

        public static let explicit = Phases(rawValue: 1 << 0)
        public static let reuse = Phases(rawValue: 1 << 1)
        public static let generate = Phases(rawValue: 1 << 2)
        public static let target = Phases(rawValue: 1 << 3)
        public static let shrink = Phases(rawValue: 1 << 4)
        public static let all: Phases = [.explicit, .reuse, .generate, .target, .shrink]
    }
}

/// A health check the engine runs, or a set of them.
public struct HealthCheck: OptionSet, Sendable, Hashable, CustomStringConvertible {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// Too many test cases were rejected by assumptions or filters.
    public static let filterTooMuch = HealthCheck(rawValue: 1 << 0)
    /// Test cases take too long.
    public static let tooSlow = HealthCheck(rawValue: 1 << 1)
    /// Generated values are too large.
    public static let testCasesTooLarge = HealthCheck(rawValue: 1 << 2)
    /// The first test case is already very large.
    public static let largeInitialTestCase = HealthCheck(rawValue: 1 << 3)
    public static let all: HealthCheck = [
        .filterTooMuch, .tooSlow, .testCasesTooLarge, .largeInitialTestCase,
    ]

    public var description: String {
        let names: [(HealthCheck, String)] = [
            (.filterTooMuch, "filterTooMuch"),
            (.tooSlow, "tooSlow"),
            (.testCasesTooLarge, "testCasesTooLarge"),
            (.largeInitialTestCase, "largeInitialTestCase"),
        ]
        let present = names.filter { contains($0.0) }.map(\.1)
        return present.isEmpty ? "none" : present.joined(separator: ", ")
    }
}

/// Where a property test is defined. Hegel uses it for reports inside
/// Antithesis.
public struct TestLocation: Sendable, Equatable {
    public var file: String
    public var line: Int
    public var container: String
    public var function: String

    public init(file: String, line: Int, container: String, function: String) {
        self.file = file
        self.line = line
        self.container = container
        self.function = function
    }
}

/// A libhegel settings handle: the engine's resolved settings with the
/// overrides of a `Settings` applied.
final class EngineSettings {
    let raw: OpaquePointer
    let context = EngineContext()

    init(_ settings: Settings, databaseKey: String?, location: TestLocation?) throws(HegelError) {
        var handle: OpaquePointer?
        let context = self.context
        do {
            if let profile = settings.profile {
                try profile.withHegelString { (name) throws(EngineError) in
                    try context.call { hegel_settings_new_for_profile($0, name, &handle) }
                }
            } else {
                try context.call { hegel_settings_new($0, &handle) }
            }
        } catch {
            throw .usage(error.message)
        }
        guard let handle else {
            throw .engine("libhegel returned no settings handle")
        }
        raw = handle
        let environment = ProcessInfo.processInfo.environment
        do {
            try apply(
                settings.yieldingTo(environment: environment),
                databaseKey: databaseKey,
                location: location
            )
        } catch {
            throw .usage(error.message)
        }
        var resolved: UInt64 = 0
        hegel_settings_get_test_cases(nil, raw, &resolved)
        if let scaled = try Settings.scaledTestCases(resolved, environment: environment) {
            do {
                try context.call { hegel_settings_set_test_cases($0, handle, scaled) }
            } catch {
                throw .usage(error.message)
            }
        }
    }

    deinit {
        hegel_settings_free(nil, raw)
    }

    private func apply(
        _ settings: Settings,
        databaseKey: String?,
        location: TestLocation?
    ) throws(EngineError) {
        let raw = self.raw
        if let testCases = settings.testCases {
            try context.call { hegel_settings_set_test_cases($0, raw, UInt64(max(testCases, 0))) }
        }
        if let seed = settings.seed {
            try context.call { hegel_settings_set_seed($0, raw, seed, true) }
        }
        if let derandomize = settings.derandomize {
            try context.call { hegel_settings_set_derandomize($0, raw, derandomize) }
        }
        if let database = settings.database {
            let path: String? =
                switch database {
                    case .default: nil
                    case .disabled: ""
                    case .path(let path): path
                }
            try withOptionalHegelString(path) { (view) throws(EngineError) in
                try context.call { hegel_settings_set_database($0, raw, view) }
            }
        }
        if let verbosity = settings.verbosity {
            try context.call { hegel_settings_set_verbosity($0, raw, verbosity.rawValue) }
        }
        if let phases = settings.phases {
            try context.call { hegel_settings_set_phases($0, raw, phases.rawValue) }
        }
        if let checks = settings.suppressedHealthChecks {
            try context.call { hegel_settings_set_suppress_health_check($0, raw, checks.rawValue) }
        }
        if let printBlob = settings.printBlob {
            try context.call { hegel_settings_set_print_blob($0, raw, printBlob) }
        }
        if let yes = settings.reportMultipleFailures {
            try context.call { hegel_settings_set_report_multiple_failures($0, raw, yes) }
        }
        if let yes = settings.stopOnFirstFailure {
            try context.call { hegel_settings_set_stop_on_first_failure($0, raw, yes) }
        }
        if let yes = settings.showStatistics {
            try context.call { hegel_settings_set_show_statistics($0, raw, yes) }
        }
        if let yes = settings.unboundedChoices {
            try context.call { hegel_settings_set_unbounded_choices($0, raw, yes) }
        }
        if let strictness = settings.nondeterminism {
            try context.call {
                hegel_settings_set_nondeterminism_strictness($0, raw, strictness.rawValue)
            }
        }
        if let backend = settings.backend {
            try context.call { hegel_settings_set_backend($0, raw, backend.rawValue) }
        }
        try withOptionalHegelString(databaseKey) { (key) throws(EngineError) in
            try context.call { hegel_settings_set_database_key($0, raw, key) }
        }
        if let location {
            try location.file.withHegelString { (file) throws(EngineError) in
                try location.container.withHegelString { (container) throws(EngineError) in
                    try location.function.withHegelString { (function) throws(EngineError) in
                        try context.call {
                            hegel_settings_set_test_location(
                                $0,
                                raw,
                                file,
                                UInt32(clamping: location.line),
                                container,
                                function
                            )
                        }
                    }
                }
            }
        }
    }

    var verbosity: Settings.Verbosity {
        var value = HEGEL_VERBOSITY_NORMAL
        hegel_settings_get_verbosity(nil, raw, &value)
        // C enums import as UInt32 with Clang's defaults and as Int32 on
        // Windows, where MSVC makes them `int`.
        return Settings.Verbosity(rawValue: UInt32(truncatingIfNeeded: value.rawValue)) ?? .normal
    }

    var printBlob: Bool {
        var value = true
        hegel_settings_get_print_blob(nil, raw, &value)
        return value
    }

    var phases: Settings.Phases {
        var value = Settings.Phases.all.rawValue
        hegel_settings_get_phases(nil, raw, &value)
        return Settings.Phases(rawValue: value)
    }

    var reportMultipleFailures: Bool {
        var value = false
        hegel_settings_get_report_multiple_failures(nil, raw, &value)
        return value
    }
}

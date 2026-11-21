public import Hegel
public import Testing

/// Runs the `property` calls in a test or suite with Hegel.
///
/// The trait does two things a `property` call can't do alone: it catches
/// `#expect` failures while the engine explores and shrinks, so only the
/// minimal failing example is reported, and it carries settings that apply
/// to every property under it.
///
/// ```swift
/// @Test(.hegel(testCases: 500))
/// func reverseTwice() throws {
///     try property { tc in
///         let xs = try tc.draw(.array(of: .int()), named: "xs")
///         #expect(Array(xs.reversed().reversed()) == xs)
///     }
/// }
/// ```
///
/// On a suite the trait applies to every test in it; a test's own trait
/// overrides the suite's settings field by field.
///
/// List `.hegel` after any other trait that handles issues, such as
/// `.compactMapIssues`, so that Hegel sees a property's issues first.
public struct HegelTrait: TestTrait, SuiteTrait, TestScoping {
    public var settings: Settings
    /// A reproduce blob to replay instead of exploring.
    public var reproducing: String?
    /// The arguments of the one test case of a parameterized test that
    /// replays `reproducing`, as its failure report named them. Nil replays
    /// it in every test case.
    public var reproducingArguments: String?
    /// Receives the engine's output lines instead of standard error.
    public var output: (@Sendable (String) -> Void)?

    public init(
        settings: Settings = Settings(),
        reproducing: String? = nil,
        reproducingArguments: String? = nil,
        output: (@Sendable (String) -> Void)? = nil
    ) {
        self.settings = settings
        self.reproducing = reproducing
        self.reproducingArguments = reproducingArguments
        self.output = output
    }

    public var isRecursive: Bool { true }

    public func scopeProvider(for test: Test, testCase: Test.Case?) -> HegelTrait? {
        test.isSuite ? nil : self
    }

    @concurrent
    public func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @concurrent @Sendable () async throws -> Void
    ) async throws {
        let outer = HegelScope.current
        let arguments = testCase.flatMap(TestCaseArguments.init)
        let replaying = reproducing == nil ? outer?.reproducing : blob(for: arguments)
        // Paths resolve from the test's package, as they do under
        // `swift test`, wherever the run started.
        let package = PackageDirectory.of(test.sourceLocation.filePath)
        if let package {
            PackageDirectory.warnIfConfigUnseen(
                package: package,
                sourceLocation: test.sourceLocation
            )
        }
        let scope = HegelScope(
            settings: Settings(projectDirectory: package)
                .merging(outer?.settings ?? Settings())
                .merging(settings),
            reproducing: replaying,
            output: output ?? outer?.output,
            test: test,
            arguments: arguments
        )
        // Every scope installs the interceptor, so the innermost `.hegel`
        // sees a property's issues before any other issue-handling trait on
        // the test does.
        try await HegelScope.$current.withValue(scope) {
            try await Self.preferringPropertyThreads {
                try await IssueInterceptor.trait.provideScope(
                    for: test,
                    testCase: testCase,
                    performing: function
                )
            }
        }
    }

    /// Runs `operation` on Hegel's own threads, so that a synchronous
    /// property blocks one of them rather than a thread of Swift's
    /// cooperative pool. A task that already prefers an executor, its own or
    /// an outer `.hegel`'s, keeps it.
    static func preferringPropertyThreads(
        _ operation: () async throws -> Void
    ) async throws {
        guard PropertyThreads.currentPreference == nil else {
            try await operation()
            return
        }
        try await withTaskExecutorPreference(PropertyThreads.shared) {
            try await operation()
        }
    }

    /// The blob to replay in the test case with `arguments`: none if the
    /// trait names other arguments. A test case whose arguments are unknown
    /// replays it.
    func blob(for arguments: TestCaseArguments?) -> String? {
        guard let reproducingArguments, let arguments else {
            return reproducing
        }
        return arguments.label == reproducingArguments ? reproducing : nil
    }
}

extension Trait where Self == HegelTrait {
    /// Runs the test's properties with Hegel and the engine's settings.
    public static var hegel: HegelTrait { HegelTrait() }

    /// Runs the test's properties with Hegel, overriding the given settings.
    public static func hegel(
        testCases: Int? = nil,
        seed: UInt64? = nil,
        profile: String? = nil,
        database: Settings.Database? = nil,
        verbosity: Settings.Verbosity? = nil,
        suppressHealthChecks: HealthCheck? = nil
    ) -> HegelTrait {
        HegelTrait(
            settings: Settings(
                profile: profile,
                testCases: testCases,
                seed: seed,
                database: database,
                verbosity: verbosity,
                suppressedHealthChecks: suppressHealthChecks
            )
        )
    }

    /// Runs the test's properties with Hegel and these settings.
    public static func hegel(_ settings: Settings) -> HegelTrait {
        HegelTrait(settings: settings)
    }

    /// Runs the test's properties with Hegel and these settings, sending
    /// the engine's output to `output` one line at a time instead of to
    /// standard error: statistics, health check messages and, in a verbose
    /// run, each test case's draws and notes as it runs. `output` can be
    /// called on any thread that runs a test case, such as a concurrent
    /// worker's.
    public static func hegel(
        _ settings: Settings = Settings(),
        output: @escaping @Sendable (String) -> Void
    ) -> HegelTrait {
        HegelTrait(settings: settings, output: output)
    }

    /// Replays the failing example a failure report printed, instead of
    /// exploring. Remove it once the failure is fixed.
    ///
    /// In a parameterized test, `arguments` names the test case that failed,
    /// as its report printed them: only that test case replays the blob,
    /// and the others explore as usual.
    ///
    /// ```swift
    /// @Test(
    ///     .hegel(reproducing: "AXicY2VgYGBkZOBiZEBhMAAAAd8AIQ==", arguments: "mode: .fast"),
    ///     arguments: Mode.allCases
    /// )
    /// ```
    public static func hegel(reproducing blob: String, arguments: String? = nil) -> HegelTrait {
        HegelTrait(reproducing: blob, reproducingArguments: arguments)
    }
}

/// What the `.hegel` trait set up for the test that is running.
struct HegelScope: Sendable {
    var settings: Settings
    var reproducing: String?
    var output: (@Sendable (String) -> Void)?
    var test: Test
    /// The running test case's arguments, if the test is parameterized.
    var arguments: TestCaseArguments?

    @TaskLocal static var current: HegelScope?

    /// The test's ID, followed by the test case's argument IDs in a
    /// parameterized test, so that each test case keeps its own failures.
    var databaseKey: String {
        guard let arguments else {
            return test.id.description
        }
        return "\(test.id.description)/\(arguments.key)"
    }

    var location: TestLocation {
        TestLocation(
            file: test.sourceLocation.fileID,
            line: test.sourceLocation.line,
            container: test.id.parent?.description ?? test.id.moduleName,
            function: test.name
        )
    }
}

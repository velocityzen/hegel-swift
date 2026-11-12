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
    /// Receives the engine's output lines instead of standard error.
    public var output: (@Sendable (String) -> Void)?

    public init(
        settings: Settings = Settings(),
        reproducing: String? = nil,
        output: (@Sendable (String) -> Void)? = nil
    ) {
        self.settings = settings
        self.reproducing = reproducing
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
        let scope = HegelScope(
            settings: (outer?.settings ?? Settings()).merging(settings),
            reproducing: reproducing ?? outer?.reproducing,
            output: output ?? outer?.output,
            test: test
        )
        // Every scope installs the interceptor, so the innermost `.hegel`
        // sees a property's issues before any other issue-handling trait on
        // the test does.
        try await HegelScope.$current.withValue(scope) {
            try await IssueInterceptor.trait.provideScope(
                for: test,
                testCase: testCase,
                performing: function
            )
        }
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
    /// standard error: statistics, verbose logs and health check messages.
    public static func hegel(
        _ settings: Settings = Settings(),
        output: @escaping @Sendable (String) -> Void
    ) -> HegelTrait {
        HegelTrait(settings: settings, output: output)
    }

    /// Replays the failing example a failure report printed, instead of
    /// exploring. Remove it once the failure is fixed.
    public static func hegel(reproducing blob: String) -> HegelTrait {
        HegelTrait(reproducing: blob)
    }
}

/// What the `.hegel` trait set up for the test that is running.
struct HegelScope: Sendable {
    var settings: Settings
    var reproducing: String?
    var output: (@Sendable (String) -> Void)?
    var test: Test

    @TaskLocal static var current: HegelScope?

    var databaseKey: String {
        test.id.description
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

public import Hegel
public import Testing
import Synchronization

/// Checks that `body` holds for every value it draws.
///
/// Use it inside a test that has the `.hegel` trait. The property fails when
/// an `#expect` or `#require` fails or when `body` throws. Hegel then shrinks
/// the failing input and reports only the minimal example: its expectation
/// failures, annotated with the values drawn and how to replay it.
///
/// ```swift
/// @Test(.hegel)
/// func sortIsIdempotent() throws {
///     try property { tc in
///         let xs = try tc.draw(.array(of: .int()), named: "xs")
///         #expect(xs.sorted().sorted() == xs.sorted())
///     }
/// }
/// ```
///
/// `examples` are explicit examples, run first with the values they give,
/// keyed by draw name. See `Example`.
///
/// `reaching` lists reach claims: event labels that some passing generated
/// case must record with `tc.event`. They show the property tested the
/// states it exists for, and not only easy inputs:
///
/// ```swift
/// try await property(reaching: ["transforms overlapped"]) { tc in
///     let jobs = try tc.draw(jobsGen, named: "jobs")
///     let report = try await pool.run(jobs)
///     if report.maxOverlap > 1 { try tc.event("transforms overlapped") }
///     #expect(report.results == jobs.map(transform))
/// }
/// ```
///
/// An unreached claim is a test issue. A run that fails, replays a blob,
/// or doesn't generate doesn't judge the claims.
public func property(
    examples: [Example] = [],
    reaching: [String] = [],
    sourceLocation: SourceLocation = #_sourceLocation,
    _ body: (TestCase) throws -> Void
) throws {
    guard let scope = HegelScope.current else {
        Issue.record(PropertyRunner.missingTrait, sourceLocation: sourceLocation)
        return
    }
    let runner = PropertyRunner(scope: scope, sourceLocation: sourceLocation)
    if let blob = scope.reproducing {
        try runner.finish(replaying: blob) { recorder in
            try Property.run(
                settings: scope.settings,
                reproducing: blob,
                output: scope.output,
                { tc in try runner.runCase(tc, recorder, body) }
            )
        }
        return
    }
    // A helper rather than a catch here: Swift 6.3's compiler crashes on a
    // catch around a closure that captures `body`.
    let judged = try runner.judgingClaims { () throws(HegelError) in
        try Property.run(
            settings: scope.settings,
            databaseKey: scope.databaseKey,
            location: scope.location,
            examples: examples,
            reaching: reaching,
            output: scope.output,
            { tc in try runner.runCase(tc, nil, body) }
        )
    }
    guard let outcome = judged else {
        return
    }
    try runner.report(outcome) { replay, recorder in
        try Property.run(
            settings: replay.settings(scope.settings),
            reproducing: replay.blob,
            examples: replay.examples,
            output: scope.output,
            { tc in try runner.runCase(tc, recorder, body) }
        )
    }
}

/// Checks that the asynchronous `body` holds for every value it draws. See
/// `property(examples:sourceLocation:_:)`.
public func property(
    examples: [Example] = [],
    reaching: [String] = [],
    sourceLocation: SourceLocation = #_sourceLocation,
    _ body: (TestCase) async throws -> Void
) async throws {
    guard let scope = HegelScope.current else {
        Issue.record(PropertyRunner.missingTrait, sourceLocation: sourceLocation)
        return
    }
    let runner = PropertyRunner(scope: scope, sourceLocation: sourceLocation)
    if let blob = scope.reproducing {
        try await runner.finish(replaying: blob) { recorder in
            try await Property.run(
                settings: scope.settings,
                reproducing: blob,
                output: scope.output
            ) { tc in
                try await runner.runCase(tc, recorder, body)
            }
        }
        return
    }
    // A helper rather than a catch here: Swift 6.3's compiler crashes on a
    // catch around a closure that captures `body`.
    let judged = try await runner.judgingClaims { () async throws(HegelError) in
        try await Property.run(
            settings: scope.settings,
            databaseKey: scope.databaseKey,
            location: scope.location,
            examples: examples,
            reaching: reaching,
            output: scope.output,
            { tc in try await runner.runCase(tc, nil, body) }
        )
    }
    guard let outcome = judged else {
        return
    }
    try await runner.report(outcome) { replay, recorder in
        try await Property.run(
            settings: replay.settings(scope.settings),
            reproducing: replay.blob,
            examples: replay.examples,
            output: scope.output
        ) { tc in
            try await runner.runCase(tc, recorder, body)
        }
    }
}

/// How a counterexample is run again for its report: by its reproduce blob,
/// or, for a failing explicit example, by running that example alone.
enum Replay {
    case blob(String)
    case example(Example)

    init?(_ counterexample: PropertyFailure.Counterexample) {
        if let example = counterexample.example {
            self = .example(example)
        } else if let blob = counterexample.reproductionBlob {
            self = .blob(blob)
        } else {
            return nil
        }
    }

    var blob: String? {
        if case .blob(let blob) = self { blob } else { nil }
    }

    var examples: [Example] {
        if case .example(let example) = self { [example] } else { [] }
    }

    /// An example runs alone: only the explicit phase.
    func settings(_ settings: Settings) -> Settings {
        guard case .example = self else {
            return settings
        }
        return settings.merging(Settings(phases: .explicit))
    }
}

/// Runs a property under Swift Testing: turns recorded issues into failing
/// test cases while exploring, then replays each minimal example with its
/// issues reported for real.
struct PropertyRunner {
    let scope: HegelScope
    let sourceLocation: SourceLocation

    static let missingTrait: Comment = """
        property needs the .hegel trait on its test or suite, as in @Test(.hegel), \
        so that Hegel can shrink failures before Swift Testing reports them.
        """

    static func reproduceHint(_ blob: String) -> String {
        """
        To reproduce this failure, add this trait to the test:
            .hegel(reproducing: "\(blob)")
        """
    }

    /// Runs `body` as one test case of the property: the issues it records
    /// fail the case.
    ///
    /// While exploring (`recorder` nil) each case gets a recorder that
    /// swallows its issues; when replaying for the report, `recorder` lets
    /// them through.
    func runCase(
        _ tc: TestCase,
        _ recorder: CaseRecorder?,
        _ body: (TestCase) throws -> Void
    ) throws {
        let recorder = recorder?.fresh() ?? CaseRecorder(annotation: nil)
        tc.hasRecordedFailure = { recorder.sawFailure }
        do {
            try IssueInterceptor.$recorder.withValue(recorder) {
                try body(tc)
            }
        } catch {
            // `#require` records its issue, then throws: the issue is the
            // failure.
            try recorder.throwIfFailed()
            throw error
        }
        try recorder.throwIfFailed()
    }

    func runCase(
        _ tc: TestCase,
        _ recorder: CaseRecorder?,
        _ body: (TestCase) async throws -> Void
    ) async throws {
        let recorder = recorder?.fresh() ?? CaseRecorder(annotation: nil)
        tc.hasRecordedFailure = { recorder.sawFailure }
        do {
            try await IssueInterceptor.$recorder.withValue(recorder) {
                try await body(tc)
            }
        } catch {
            try recorder.throwIfFailed()
            throw error
        }
        try recorder.throwIfFailed()
    }

    /// Reports a failed run: each counterexample whose failure was recorded
    /// issues is replayed so the issues are recorded again, now annotated;
    /// thrown errors are rethrown together with their report.
    func report(
        _ outcome: PropertyOutcome,
        replay: (Replay, CaseRecorder) throws -> PropertyOutcome
    ) throws {
        guard let failure = outcome.failure else {
            return
        }
        var thrown: [PropertyFailure.Counterexample] = []
        for counterexample in failure.counterexamples {
            guard let issues = counterexample.error as? RecordedIssues else {
                thrown.append(counterexample)
                continue
            }
            let recorder = CaseRecorder(annotation: annotation(for: counterexample))
            if let how = Replay(counterexample) {
                _ = try? replay(how, recorder)
            }
            if !recorder.sawFailure {
                recordFallback(issues, counterexample)
            }
        }
        try throwIfAny(thrown)
    }

    func report(
        _ outcome: PropertyOutcome,
        replay: (Replay, CaseRecorder) async throws -> PropertyOutcome
    ) async throws {
        guard let failure = outcome.failure else {
            return
        }
        var thrown: [PropertyFailure.Counterexample] = []
        for counterexample in failure.counterexamples {
            guard let issues = counterexample.error as? RecordedIssues else {
                thrown.append(counterexample)
                continue
            }
            let recorder = CaseRecorder(annotation: annotation(for: counterexample))
            if let how = Replay(counterexample) {
                _ = try? await replay(how, recorder)
            }
            if !recorder.sawFailure {
                recordFallback(issues, counterexample)
            }
        }
        try throwIfAny(thrown)
    }

    /// Replays a blob the `.hegel(reproducing:)` trait gave.
    /// Records a run's unmet reach claims as an issue at the property.
    /// Runs a property, recording an unmet reach claim as an issue: the
    /// result is then nil.
    func judgingClaims(
        _ run: () throws(HegelError) -> PropertyOutcome
    ) throws(HegelError) -> PropertyOutcome? {
        do {
            return try run()
        } catch {
            return try recordUnreached(error)
        }
    }

    /// Runs a property, recording an unmet reach claim as an issue: the
    /// result is then nil.
    func judgingClaims(
        _ run: () async throws(HegelError) -> PropertyOutcome
    ) async throws(HegelError) -> PropertyOutcome? {
        do {
            return try await run()
        } catch {
            return try recordUnreached(error)
        }
    }

    /// Records `error` as an issue if it is an unmet reach claim, and
    /// rethrows it otherwise.
    private func recordUnreached(_ error: HegelError) throws(HegelError) -> PropertyOutcome? {
        guard error.isUnreached else {
            throw error
        }
        Issue.record(Comment(rawValue: error.description), sourceLocation: sourceLocation)
        return nil
    }

    func finish(replaying blob: String, _ run: (CaseRecorder) throws -> PropertyOutcome) throws {
        let recorder = CaseRecorder(
            annotation: Comment(rawValue: "Replayed from a reproduce blob.")
        )
        do {
            try reportReplay(run(recorder), recorder)
        } catch HegelError.notReproduced {
            Issue.record(
                Comment(rawValue: HegelError.notReproduced(blob: blob).description),
                sourceLocation: sourceLocation
            )
        }
    }

    func finish(
        replaying blob: String,
        _ run: (CaseRecorder) async throws -> PropertyOutcome
    ) async throws {
        let recorder = CaseRecorder(
            annotation: Comment(rawValue: "Replayed from a reproduce blob.")
        )
        do {
            try reportReplay(await run(recorder), recorder)
        } catch HegelError.notReproduced {
            Issue.record(
                Comment(rawValue: HegelError.notReproduced(blob: blob).description),
                sourceLocation: sourceLocation
            )
        }
    }

    private func reportReplay(_ outcome: PropertyOutcome, _ recorder: CaseRecorder) throws {
        guard let failure = outcome.failure else {
            return
        }
        try throwIfAny(failure.counterexamples.filter { !($0.error is RecordedIssues) })
    }

    private func annotation(for counterexample: PropertyFailure.Counterexample) -> Comment {
        var lines = [
            counterexample.example == nil ? "Falsifying example:" : "Falsifying explicit example:"
        ]
        lines.append(contentsOf: counterexample.drawn.map { "    " + $0 })
        lines.append(contentsOf: counterexample.notes(reproduce: Self.reproduceHint))
        return Comment(rawValue: lines.joined(separator: "\n"))
    }

    /// Records a failure that did not reproduce on replay, as can happen for
    /// a nondeterministic one: its issues as they were seen while exploring.
    private func recordFallback(
        _ issues: RecordedIssues,
        _ counterexample: PropertyFailure.Counterexample
    ) {
        let report = counterexample.report(reproduce: Self.reproduceHint)
        Issue.record(
            Comment(rawValue: report),
            sourceLocation: issues.issues.first?.sourceLocation ?? sourceLocation
        )
    }

    private func throwIfAny(_ counterexamples: [PropertyFailure.Counterexample]) throws {
        guard !counterexamples.isEmpty else {
            return
        }
        throw HegelTestFailure(failure: PropertyFailure(counterexamples: counterexamples))
    }
}

/// A property that failed by throwing, reported with the trait's reproduce
/// hint.
public struct HegelTestFailure: Error, CustomStringConvertible {
    public let failure: PropertyFailure

    public var description: String {
        failure.report(reproduce: PropertyRunner.reproduceHint)
    }
}

/// The failing issues a test case recorded.
struct RecordedIssues: Error, FailureOrigin, CustomStringConvertible {
    let issues: [Issue]

    var failureOrigin: String {
        guard let location = issues.first?.sourceLocation else {
            return "Issue"
        }
        return "Issue at \(location.fileID):\(location.line):\(location.column)"
    }

    var description: String {
        issues.map(\.description).joined(separator: "\n")
    }
}

/// Collects the issues one test case records.
final class CaseRecorder: Sendable {
    /// Added to every issue that passes through; nil while exploring, when
    /// issues are swallowed instead.
    let annotation: Comment?
    private let issues = Mutex<[Issue]>([])
    private let failed = Atomic<Bool>(false)
    private let parent: CaseRecorder?

    init(annotation: Comment?, parent: CaseRecorder? = nil) {
        self.annotation = annotation
        self.parent = parent
    }

    /// A recorder for the next test case of a replay, reporting to this one.
    func fresh() -> CaseRecorder {
        CaseRecorder(annotation: annotation, parent: self)
    }

    /// Whether any test case of a replay recorded a failure.
    var sawFailure: Bool {
        failed.load(ordering: .relaxed)
    }

    func intercept(_ issue: Issue) -> Issue? {
        if let annotation, issue.comments.contains(where: { $0.rawValue == annotation.rawValue }) {
            // Already handled by a nested `.hegel` scope.
            return issue
        }
        issues.withLock { $0.append(issue) }
        failed.store(true, ordering: .relaxed)
        parent?.failed.store(true, ordering: .relaxed)
        guard let annotation else {
            return nil
        }
        var issue = issue
        issue.comments.append(annotation)
        return issue
    }

    func throwIfFailed() throws {
        let recorded = issues.withLock { $0 }
        if !recorded.isEmpty {
            throw RecordedIssues(issues: recorded)
        }
    }
}

/// Routes issues recorded inside a property to the running test case's
/// recorder.
enum IssueInterceptor {
    @TaskLocal static var recorder: CaseRecorder?

    static let trait = IssueHandlingTrait.compactMapIssues { issue in
        guard issue.isFailure, let recorder = IssueInterceptor.recorder else {
            return issue
        }
        return recorder.intercept(issue)
    }
}

extension HegelError {
    var isUnreached: Bool {
        if case .unreached = self {
            return true
        }
        return false
    }
}

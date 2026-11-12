import Hegel
import Synchronization
import Testing

@testable import HegelTesting

/// Collects the issues recorded inside `capture`, keeping them from failing
/// the test, so a test can check what a failing property reports.
final class IssueSink: Sendable {
    @TaskLocal static var current: IssueSink?

    private let issues = Mutex<[Issue]>([])

    var recorded: [Issue] {
        issues.withLock { $0 }
    }

    func append(_ issue: Issue) {
        issues.withLock { $0.append(issue) }
    }
}

extension Trait where Self == IssueHandlingTrait {
    /// Lets `capture` collect issues. List it before `.hegel`, so that it
    /// sees what Hegel reports after shrinking.
    static var capturingIssues: Self {
        .compactMapIssues { issue in
            guard let sink = IssueSink.current else {
                return issue
            }
            sink.append(issue)
            return nil
        }
    }
}

func capture(_ body: () throws -> Void) rethrows -> [Issue] {
    let sink = IssueSink()
    try IssueSink.$current.withValue(sink) {
        try body()
    }
    return sink.recorded
}

func capture(_ body: () async throws -> Void) async rethrows -> [Issue] {
    let sink = IssueSink()
    try await IssueSink.$current.withValue(sink) {
        try await body()
    }
    return sink.recorded
}

extension Issue {
    var commentText: String {
        comments.map(\.rawValue).joined(separator: "\n")
    }
}

struct Failed: Error {}

@Suite("property", .hegel(database: .disabled))
struct HegelPropertyTests {
    @Test(.capturingIssues, .hegel)
    func holds() throws {
        let issues = try capture {
            try property { tc in
                let xs = try tc.draw(.array(of: .int()), named: "xs")
                #expect(Array(xs.reversed().reversed()) == xs)
            }
        }
        #expect(issues.isEmpty)
    }

    @Test(.capturingIssues, .hegel)
    func reportsOnlyTheMinimalExpectationFailure() throws {
        let issues = try capture {
            try property { tc in
                let n = try tc.draw(.int(), named: "n")
                #expect(n < 10)
            }
        }
        try #require(issues.count == 1)
        let issue = issues[0]
        #expect(issue.description.contains("n < 10"))
        #expect(issue.commentText.contains("let n = 10"))
        #expect(issue.commentText.contains(".hegel(reproducing: \""))
    }

    @Test(.capturingIssues, .hegel)
    func reportsRequireFailures() throws {
        let issues = try capture {
            try property { tc in
                let xs = try tc.draw(.array(of: .int(in: 0...9)), named: "xs")
                try #require(xs.count < 3)
            }
        }
        try #require(issues.count == 1)
        #expect(issues[0].commentText.contains("let xs = [0, 0, 0]"))
    }

    @Test(.capturingIssues, .hegel)
    func reportsEachDistinctExpectation() throws {
        let issues = try capture {
            try property { tc in
                let n = try tc.draw(.int(in: -100...100), named: "n")
                #expect(n >= 0)
                #expect(n <= 50)
            }
        }
        let comments = Set(
            issues.map(\.commentText).map { $0.contains("let n = -1") || $0.contains("let n = 51") }
        )
        #expect(issues.count >= 1)
        #expect(comments == [true])
    }

    @Test(.capturingIssues, .hegel)
    func thrownErrorsAreRethrownWithTheReport() throws {
        let failure = #expect(throws: HegelTestFailure.self) {
            try property { tc in
                let n = try tc.draw(.int(in: 0...100), named: "n")
                if n > 20 {
                    throw Failed()
                }
            }
        }
        let report = failure?.description ?? ""
        #expect(report.contains("let n = 21"))
        #expect(report.contains(".hegel(reproducing: \""))
    }

    @Test(.capturingIssues, .hegel)
    func asyncProperties() async throws {
        let issues = try await capture {
            try await property { tc in
                let n = try tc.draw(.int(in: 0...1000), named: "n")
                await Task.yield()
                #expect(n < 100)
            }
        }
        try #require(issues.count == 1)
        #expect(issues[0].commentText.contains("let n = 100"))
    }

    @Test(.capturingIssues, .hegel)
    func reproducingReplaysTheBlob() throws {
        let issues = try capture {
            try property { tc in
                let n = try tc.draw(.int(in: 0...1000), named: "n")
                #expect(n < 300)
            }
        }
        let comment = try #require(issues.first?.commentText)
        let blob = try #require(comment.firstMatch(of: /reproducing: "([^"]+)"/)?.output.1)

        let scope = try #require(HegelScope.current)
        var replaying = scope
        replaying.reproducing = String(blob)
        let replayed = try HegelScope.$current.withValue(replaying) {
            try capture {
                try property { tc in
                    let n = try tc.draw(.int(in: 0...1000), named: "n")
                    #expect(n < 300)
                }
            }
        }
        try #require(replayed.count == 1)
        #expect(replayed[0].commentText.contains("Replayed from a reproduce blob."))
    }

    @Test(.hegel(testCases: 7))
    func testSettingsOverrideTheSuite() throws {
        let scope = try #require(HegelScope.current)
        #expect(scope.settings.testCases == 7)
        #expect(scope.settings.database == .disabled)
        var cases = 0
        try property { tc in
            cases += 1
            _ = try tc.draw(.bool())
        }
        #expect(cases <= 7)
    }
}

@Suite("property without the trait")
struct MissingTraitTests {
    @Test(.capturingIssues)
    func recordsAnIssue() throws {
        let issues = try capture {
            try property { _ in }
        }
        try #require(issues.count == 1)
        #expect(issues[0].commentText.contains("needs the .hegel trait"))
    }
}

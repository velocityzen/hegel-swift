import Foundation
import Hegel
import Synchronization
import Testing

@testable import HegelTesting

enum Mode: String, CaseIterable, Codable, Sendable {
    case fast, slow
}

/// A value Swift Testing can't encode, so its ID is its description.
struct Point: Sendable {
    var x: Int
}

/// The database key each parameterized test case ran with, by its label.
private let keysSeen = Mutex<[String: String]>([:])

@Suite("parameterized tests", .hegel(database: .disabled))
struct ParameterizedTests {
    @Test(.hegel, arguments: Mode.allCases, ["plain", "quote \" backslash \\ newline \n"])
    func eachTestCaseHasItsOwnKey(_ mode: Mode, text: String) throws {
        let scope = try #require(HegelScope.current)
        let arguments = try #require(scope.arguments)
        #expect(arguments.label == "mode: .\(mode), text: \(String(describingForTest: text))")
        try expectOwnKey(scope)
    }

    @Test(.hegel, arguments: [Point(x: 1), Point(x: 2)])
    func unencodableArgumentsHaveTheirOwnKey(point: Point) throws {
        let scope = try #require(HegelScope.current)
        #expect(scope.arguments?.label == "point: Point(x: \(point.x))")
        try expectOwnKey(scope)
    }

    @Test(.hegel)
    func aTestWithoutArgumentsIsKeyedByItsID() throws {
        let scope = try #require(HegelScope.current)
        #expect(scope.arguments == nil)
        #expect(scope.databaseKey == Test.current?.id.description)
    }

    /// Records the scope's key, checking that it extends the test's ID and
    /// that no test case with other arguments has it.
    private func expectOwnKey(_ scope: HegelScope) throws {
        let test = try #require(Test.current)
        let label = try #require(scope.arguments?.label)
        #expect(scope.databaseKey.hasPrefix(test.id.description + "/"))
        let other = keysSeen.withLock { seen in
            defer { seen[scope.databaseKey] = label }
            return seen[scope.databaseKey].flatMap { $0 == label ? nil : $0 }
        }
        #expect(other == nil, "\(label) has the key of \(other ?? "")")
    }

    @Test(.capturingIssues, .hegel)
    func eachTestCaseKeepsItsOwnFailures() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hegel-parameterized-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let scope = try #require(HegelScope.current)

        // Runs a property in the test case with `mode`, failing for n >= 500
        // when `failing`, and returns the first n it drew.
        func firstDraw(_ mode: String, failing: Bool) throws -> Int? {
            var testCase = scope
            testCase.settings = scope.settings.merging(Settings(database: .path(directory)))
            testCase.arguments = TestCaseArguments([
                .init(name: "mode", id: Array(mode.utf8), value: mode.debugDescription)
            ])
            let first = Mutex<Int?>(nil)
            let issues = try HegelScope.$current.withValue(testCase) {
                try capture {
                    try property { tc in
                        let n = try tc.draw(.int(), named: "n")
                        first.withLock { $0 = $0 ?? n }
                        if failing {
                            #expect(n < 500)
                        }
                    }
                }
            }
            #expect(issues.count == (failing ? 1 : 0))
            return first.withLock { $0 }
        }

        _ = try firstDraw("fails", failing: true)
        // Another argument doesn't replay the failure, which would also
        // delete it from the database when it passed.
        #expect(try firstDraw("passes", failing: false) != 500)
        #expect(try firstDraw("fails", failing: true) == 500)
    }

    @Test(.capturingIssues, .hegel, arguments: Mode.allCases)
    func theReproduceHintNamesTheArguments(mode: Mode) async throws {
        let label = "mode: .\(mode)"
        let issues = try capture {
            try property { tc in
                let n = try tc.draw(.int(), named: "n")
                #expect(n < 500)
            }
        }
        try #require(issues.count == 1)
        let hint = try #require(
            issues[0].commentText.firstMatch(
                of: /\.hegel\(reproducing: "([^"]+)", arguments: (.+)\)/
            )
        )
        #expect(hint.output.2 == label.debugDescription)

        let thrown = #expect(throws: HegelTestFailure.self) {
            try property { tc in
                let n = try tc.draw(.int(), named: "n")
                if n >= 500 {
                    throw Failed()
                }
            }
        }
        #expect(thrown?.description.contains("arguments: \(label.debugDescription))") == true)

        // The trait replays the blob only in the test case it names.
        let blob = String(hint.output.1)
        let test = try #require(Test.current)
        for (arguments, replays) in [(label, true), ("mode: .other", false)] {
            try await HegelTrait.hegel(reproducing: blob, arguments: arguments).provideScope(
                for: test,
                testCase: Test.Case.current
            ) {
                #expect(HegelScope.current?.reproducing == (replays ? blob : nil))
            }
        }
    }
}

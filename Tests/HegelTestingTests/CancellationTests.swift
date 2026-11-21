import Hegel
import Synchronization
import Testing

@testable import HegelTesting

/// What a test case does once it has cancelled its own task.
private enum AfterCancelling: CaseIterable, Sendable {
    /// Throws `CancellationError`, as cancellable work does.
    case throwsCancellationError
    /// Fails an expectation.
    case failsAnExpectation
    /// Finishes as if nothing had happened.
    case returns
}

/// Counts the calls of a property's body, shared with the task that runs
/// it.
private final class Calls: Sendable {
    private let count = Atomic(0)

    var value: Int { count.load(ordering: .sequentiallyConsistent) }

    /// The index of this call: 0 for the first.
    func next() -> Int {
        count.add(1, ordering: .sequentiallyConsistent).oldValue
    }
}

/// Cancels the task the caller runs in.
private func cancelCurrentTask() {
    withUnsafeCurrentTask { $0?.cancel() }
}

@Suite("cancelling a property", .hegel(database: .disabled))
struct PropertyCancellationTests {
    @Test(.hegel(testCases: 200))
    func throwsCancellationErrorAndReportsNothing() async throws {
        // Enough cases that the run is still going at the cancellation.
        var deeper = try #require(HegelScope.current)
        deeper.settings = deeper.settings.merging(Settings(testCases: 1_000))
        let scope = deeper
        try await property(reaching: ["before the run"] + AfterCancelling.allCases.map { "\($0)" })
        {
            tc in
            // The call whose test case cancels its task; -1 cancels it
            // before the run starts.
            let cancelAt = try tc.draw(.oneOf(.just(-1), .int(in: -1...199)), named: "cancelAt")
            let then = try tc.draw(.element(of: AfterCancelling.allCases), named: "then")
            let isAsync = try tc.draw(.bool(), named: "isAsync")
            let calls = Calls()
            let body: @Sendable (TestCase) throws -> Void = { inner in
                _ = try inner.draw(.int(), named: "n")
                guard calls.next() == cancelAt else {
                    return
                }
                cancelCurrentTask()
                switch then {
                    case .throwsCancellationError: try Task.checkCancellation()
                    case .failsAnExpectation: #expect(Bool(false), "an expectation fails")
                    case .returns: return
                }
            }
            let task = Task {
                try await HegelScope.$current.withValue(scope) {
                    if cancelAt == -1 {
                        cancelCurrentTask()
                    }
                    if isAsync {
                        try await property { inner in
                            try body(inner)
                            await Task.yield()
                        }
                    } else {
                        try property(body)
                    }
                }
            }
            let result = await task.result
            #expect(throws: CancellationError.self) { try result.get() }
            #expect(calls.value == cancelAt + 1)
            try tc.event(cancelAt == -1 ? "before the run" : "\(then)")
        }
    }

    @Test(.capturingIssues, .hegel)
    func aCancelledReplayThrowsCancellationError() async throws {
        let issues = try capture {
            try property { tc in
                let n = try tc.draw(.int(), named: "n")
                #expect(n < 500)
            }
        }
        let comment = try #require(issues.first?.commentText)
        let blob = try #require(comment.firstMatch(of: /reproducing: "([^"]+)"/)?.output.1)
        var replaying = try #require(HegelScope.current)
        replaying.reproducing = String(blob)
        let scope = replaying

        let task = Task {
            try await HegelScope.$current.withValue(scope) {
                try await property { tc in
                    _ = try tc.draw(.int(), named: "n")
                    cancelCurrentTask()
                    try Task.checkCancellation()
                }
            }
        }
        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
    }
}

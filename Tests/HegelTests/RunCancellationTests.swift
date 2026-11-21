import Foundation
import Hegel
import Synchronization
import Testing

/// What a test case does once it has cancelled its own task.
enum AfterCancelling: CaseIterable, Sendable {
    /// Throws `CancellationError`, as cancellable work does.
    case throwsCancellationError
    /// Fails for another reason.
    case fails
    /// Finishes as if nothing had happened.
    case returns
}

/// What a property's body did, shared with the task that runs it.
private final class Calls: Sendable {
    private let count = Atomic(0)
    private let failed = Atomic(false)

    /// How many times the body was called.
    var value: Int { count.load(ordering: .sequentiallyConsistent) }

    /// Whether the body failed before it cancelled its task.
    var failedFirst: Bool { failed.load(ordering: .sequentiallyConsistent) }

    /// The index of this call: 0 for the first.
    func next() -> Int {
        count.add(1, ordering: .sequentiallyConsistent).oldValue
    }

    func fail() {
        failed.store(true, ordering: .sequentiallyConsistent)
    }
}

private struct Unexpected: Error, CustomStringConvertible {
    let description: String
}

/// The failure of a test case that cancelled its task.
private struct FailedAfterCancelling: Error, CustomStringConvertible {
    var description: String { "failed after cancelling" }
}

/// The lines a run printed.
private final class Lines: Sendable {
    private let lines = Mutex<[String]>([])

    var all: [String] { lines.withLock { $0 } }

    func append(_ line: String) {
        lines.withLock { $0.append(line) }
    }
}

/// Cancels the task the caller runs in.
private func cancelCurrentTask() {
    withUnsafeCurrentTask { $0?.cancel() }
}

@Suite("cancelling a run")
struct RunCancellationTests {
    @Test("stops at the test case that saw cancellation, with no verdict and nothing stored")
    func stopsAtTheCancellingCase() async throws {
        let outcome = try await Property.run(
            settings: isolated.merging(Settings(testCases: 300)),
            reaching: [
                "cancelled before the run",
                "cancelled in an explicit example",
                "cancelled in a generated case",
                "cancelled after a failure",
                "failed before the cancellation",
            ]
        ) { tc in
            let explicit = try tc.draw(.array(of: .int(), count: 0...5), named: "explicit")
            // The call whose test case cancels its task; -1 cancels it
            // before the run starts. Before the run and in the explicit
            // examples are narrow slices of the range, so they get branches
            // of their own.
            let cancelAt = try tc.draw(
                .oneOf(
                    .just(-1),
                    .int(in: -1...explicit.count),
                    .int(in: -1...(explicit.count + 199))
                ),
                named: "cancelAt"
            )
            let then = try tc.draw(.element(of: AfterCancelling.allCases), named: "then")
            // A real failure for n at or above it, found before the
            // cancellation or not at all.
            let failsFrom = try tc.draw(
                Gen<Int?>.oneOf(.just(nil), Gen.int().map { Optional($0) }),
                named: "failsFrom"
            )
            let isAsync = try tc.draw(.bool(), named: "isAsync")

            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("hegel-cancel-\(UUID().uuidString)").path
            defer { try? FileManager.default.removeItem(atPath: directory) }
            // Enough generated cases that only a failure ends the run before
            // the cancellation. Verbose, so that the engine prints every
            // failing test case's summary.
            let settings = Settings(
                testCases: 1_000,
                database: .path(directory),
                verbosity: .verbose
            )
            let printed = Lines()
            let output: @Sendable (String) -> Void = { printed.append($0) }
            let examples = explicit.map { ["n": $0] as Example }
            let calls = Calls()
            let body: @Sendable (TestCase) throws -> Void = { inner in
                let n = try inner.draw(.int(), named: "n")
                if calls.next() == cancelAt {
                    cancelCurrentTask()
                    switch then {
                        case .throwsCancellationError: try Task.checkCancellation()
                        case .fails: throw FailedAfterCancelling()
                        case .returns: return
                    }
                }
                if let failsFrom, n >= failsFrom {
                    calls.fail()
                    throw Failed()
                }
            }
            // Whether the run failed, if it ended with a verdict.
            let task = Task {
                if cancelAt == -1 {
                    cancelCurrentTask()
                }
                if isAsync {
                    return try await Property.run(
                        settings: settings,
                        examples: examples,
                        output: output
                    ) { inner in
                        try body(inner)
                        await Task.yield()
                    }.failure != nil
                }
                return try Property.run(
                    settings: settings,
                    examples: examples,
                    output: output,
                    body
                ).failure != nil
            }

            switch await task.result {
                case .failure(HegelError.cancelled):
                    guard calls.value == cancelAt + 1 else {
                        throw Unexpected(
                            description:
                                "\(calls.value - cancelAt - 1) test cases ran after the cancellation"
                        )
                    }
                    // The engine never saw the cancelling test case fail.
                    let reported = printed.all.filter {
                        $0.contains("CancellationError") || $0.contains("failed after cancelling")
                    }
                    guard reported.isEmpty else {
                        throw Unexpected(description: "the engine printed \(reported)")
                    }
                    let stored =
                        (try? FileManager.default.subpathsOfDirectory(atPath: directory)) ?? []
                    guard calls.failedFirst || stored.isEmpty else {
                        throw Unexpected(description: "the database stored \(stored)")
                    }
                    if cancelAt == -1 {
                        try tc.event("cancelled before the run")
                    } else if cancelAt < explicit.count {
                        try tc.event("cancelled in an explicit example")
                    } else {
                        try tc.event("cancelled in a generated case")
                    }
                    if calls.failedFirst {
                        try tc.event("cancelled after a failure")
                    }
                case .success(let failed):
                    // Only a real failure ends the run before the cancelling
                    // test case.
                    guard failed, calls.failedFirst, calls.value <= cancelAt else {
                        throw Unexpected(description: "the run ended without its cancellation")
                    }
                    try tc.event("failed before the cancellation")
                case .failure(let error):
                    throw error
            }
        }
        if case .failed(let failure) = outcome {
            Issue.record(Comment(rawValue: failure.report()))
        }
    }
}

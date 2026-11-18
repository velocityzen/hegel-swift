import Hegel
import Synchronization
import Testing

/// Collects the lines a run's engine output sends.
final class OutputLines: Sendable {
    private let lines = Mutex<[String]>([])

    var all: [String] {
        lines.withLock { $0 }
    }

    var sink: @Sendable (String) -> Void {
        { line in self.lines.withLock { $0.append(line) } }
    }
}

/// An error that says whatever it is given.
struct MessageError: Error, CustomStringConvertible {
    let description: String
}

/// `detail` ends with `message`, compared scalar by scalar: a message that
/// starts with a combining mark joins the character before it, so comparing
/// characters would not find it.
private func endsWith(_ detail: String, _ message: String) -> Bool {
    detail.unicodeScalars.suffix(message.unicodeScalars.count)
        .elementsEqual(message.unicodeScalars)
}

@Suite("Engine output")
struct EngineOutputTests {
    @Test("goes to the output callback, statistics included")
    func callback() throws {
        let output = OutputLines()
        let settings = isolated.merging(Settings(testCases: 20, showStatistics: true))
        _ = try Property.run(settings: settings, output: output.sink) { tc in
            try tc.event(try tc.draw(.bool()) ? "yes" : "no")
        }
        let lines = output.all
        #expect(lines.contains { $0.hasPrefix("Statistics") })
        #expect(lines.contains { $0.contains("* yes: ") })
    }

    /// A property that fails for `n >= 10`, so it shrinks to `n = 10`, with
    /// a note and a two-line error.
    private func runShrinking(
        _ verbosity: Settings.Verbosity,
        _ output: OutputLines
    ) throws -> PropertyFailure.Counterexample {
        let outcome = try Property.run(
            settings: isolated.merging(Settings(verbosity: verbosity)),
            output: output.sink
        ) { tc in
            let n = try tc.draw(.int(), named: "n")
            tc.note("n is \(n)")
            if n >= 10 {
                throw MessageError(description: "n too big: \(n)\nmore detail")
            }
        }
        return try #require(outcome.failure?.counterexamples.first)
    }

    @Test(
        "the report's error is the reported case's at every verbosity",
        arguments: [Settings.Verbosity.quiet, .normal, .verbose, .debug]
    )
    func reportedError(_ verbosity: Settings.Verbosity) throws {
        let counterexample = try runShrinking(verbosity, OutputLines())
        #expect(String(describing: counterexample.error) == "n too big: 10\nmore detail")
        // A quiet run keeps no output for its report.
        let drawn = verbosity == .quiet ? [] : ["let n = 10", "n is 10"]
        #expect(counterexample.drawn == drawn)
    }

    @Test("a quiet run prints nothing")
    func quietPrintsNothing() throws {
        let output = OutputLines()
        _ = try runShrinking(.quiet, output)
        #expect(output.all.isEmpty)
    }

    @Test("a normal run prints no test case")
    func normalPrintsNoCase() throws {
        let output = OutputLines()
        _ = try runShrinking(.normal, output)
        #expect(!output.all.contains { $0.hasPrefix("let n = ") || $0.hasPrefix("n is ") })
    }

    @Test("a verbose run streams each case's draws and notes, and summarizes failing ones")
    func verboseStreams() throws {
        let output = OutputLines()
        _ = try runShrinking(.verbose, output)
        let lines = output.all
        #expect(lines.contains("let n = 10"))
        #expect(lines.contains("n is 10"))
        #expect(lines.contains("MessageError: n too big: 10 …"))
        #expect(!lines.contains("more detail"))
    }

    @Test("a debug run prints each failing case's whole error")
    func debugPrintsDetail() throws {
        let output = OutputLines()
        _ = try runShrinking(.debug, output)
        let lines = output.all
        #expect(lines.contains("let n = 10"))
        #expect(lines.contains("MessageError: n too big: 10"))
        #expect(lines.contains("more detail"))
    }

    @Test("a summary is the detail's first line: never empty, never more than one line")
    func summaryRules() throws {
        try Property.check(settings: isolated) { tc in
            let message = try tc.draw(.string(), named: "message")
            let error = MessageError(description: message)
            let summary = failureSummary(of: error)
            let detail = failureDetail(of: error)
            tc.note("summary: \(String(reflecting: summary))")
            tc.note("detail: \(String(reflecting: detail))")
            let firstLine = detail.prefix { !$0.isNewline }
            let expected =
                firstLine.endIndex == detail.endIndex ? String(firstLine) : "\(firstLine) …"
            guard !summary.isEmpty, !summary.contains(where: \.isNewline), summary == expected,
                !detail.isEmpty, endsWith(detail, message)
            else {
                throw Failed()
            }
        }
    }

    @Test(
        "the engine takes the summary and detail of any error message",
        arguments: [Settings.Verbosity.verbose, .debug]
    )
    func engineTakesAnyMessage(_ verbosity: Settings.Verbosity) throws {
        try Property.check(settings: isolated) { tc in
            let message = try tc.draw(.string(), named: "message")
            // A rejected completion would end this run with an engine error.
            let outcome = try Property.run(
                settings: isolated.merging(Settings(testCases: 1, verbosity: verbosity)),
                output: { _ in }
            ) { _ in
                throw MessageError(description: message)
            }
            guard let error = outcome.failure?.counterexamples.first?.error as? MessageError,
                error.description == message
            else {
                throw Failed()
            }
        }
    }
}

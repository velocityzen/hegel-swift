import Foundation
import Hegel
import Synchronization
import Testing

/// Few cases: each paused check runs the fault-control program twice.
private let fewCases = isolated.merging(Settings(testCases: 10))

/// Few cases and no shrinking, for a failing run: shrinking replays the
/// machine many times, each paused check running the program twice.
private let fewCasesUnshrunk = fewCases.merging(Settings(phases: [.explicit, .generate]))

/// A shared counter, the model of the concurrent machines below.
private final class Counter: Sendable {
    let value = Mutex(0)
}

/// Every test here sets `ANTITHESIS_FAULT_CONTROL` for the whole process,
/// so the suite runs serially. Tests elsewhere never pause faults, so they
/// don't see it.
@Suite("pausing faults", .serialized)
struct FaultsTests {
    @Test("without Antithesis, a pausing invariant runs like any other")
    func outsideAntithesis() throws {
        #if !os(Windows)
            unsetenv("ANTITHESIS_FAULT_CONTROL")
        #endif
        let checks = Mutex(0)
        let machine = StateMachine<Int>(steps: 5)
            .rule("add") { n, tc in n += try tc.draw(.int(in: 0...10)) }
            .invariant("non-negative", everyStep: true, pauseFaults: true) { n, _ in
                checks.withLock { $0 += 1 }
                if n < 0 {
                    throw Failed()
                }
            }
        let outcome = try Property.run(settings: fewCases) { tc in
            _ = try machine.run(tc, from: 0)
        }
        #expect(outcome.failure == nil)
        #expect(checks.withLock { $0 } > 0)
    }

    #if !os(Windows)
        @Test("only an invariant declared with pauseFaults is bracketed by pause and unpause")
        func bracketsPausingInvariants() throws {
            let control = try FaultControl()
            let paused = Mutex(0)
            let machine = StateMachine<Int>(steps: 5)
                .rule("add") { n, tc in n += try tc.draw(.int(in: 0...10)) }
                .invariant("paused", everyStep: true, pauseFaults: true) { _, _ in
                    #expect(control.calls().last == "--pause")
                    paused.withLock { $0 += 1 }
                }
                .invariant("unpaused", everyStep: true) { _, _ in
                    #expect(control.calls().last != "--pause")
                }
            let outcome = try Property.run(settings: fewCases) { tc in
                _ = try machine.run(tc, from: 0)
            }
            #expect(outcome.failure == nil)
            let count = paused.withLock { $0 }
            #expect(count > 0)
            #expect(
                control.calls()
                    == Array(repeating: ["--pause", "--unpause"], count: count).flatMap { $0 }
            )
        }

        @Test("an async machine's pausing invariant is bracketed by pause and unpause")
        func bracketsAsyncInvariants() async throws {
            let control = try FaultControl()
            let paused = Mutex(0)
            let machine = StateMachine<Int>(steps: 5)
                .rule("add") { n, tc in n += try tc.draw(.int(in: 0...10)) }
                .invariant("paused", everyStep: true, pauseFaults: true) { _, _ in
                    await Task.yield()
                    #expect(control.calls().last == "--pause")
                    paused.withLock { $0 += 1 }
                }
            let outcome = try await Property.run(settings: fewCases) { tc in
                _ = try await machine.run(tc, from: 0)
            }
            #expect(outcome.failure == nil)
            let count = paused.withLock { $0 }
            #expect(count > 0)
            #expect(
                control.calls()
                    == Array(repeating: ["--pause", "--unpause"], count: count).flatMap { $0 }
            )
        }

        @Test("a concurrent machine's pausing invariant is bracketed by pause and unpause")
        func bracketsConcurrentInvariants() async throws {
            let control = try FaultControl()
            let paused = Mutex(0)
            let machine = ConcurrentStateMachine<Counter>(steps: 5, concurrency: 1...3)
                .rule("add") { counter, tc in
                    let n = try tc.draw(.int(in: 0...10))
                    counter.value.withLock { $0 += n }
                }
                .invariant("paused", everyStep: true, pauseFaults: true) { _, _ in
                    #expect(control.calls().last == "--pause")
                    paused.withLock { $0 += 1 }
                }
            let outcome = try await Property.run(settings: fewCases) { tc in
                try await machine.run(tc, from: Counter())
            }
            #expect(outcome.failure == nil)
            let count = paused.withLock { $0 }
            #expect(count > 0)
            #expect(
                control.calls()
                    == Array(repeating: ["--pause", "--unpause"], count: count).flatMap { $0 }
            )
        }

        @Test("a failing pausing invariant still resumes faults, and its failure is reported")
        func failingInvariantUnpauses() throws {
            let control = try FaultControl()
            let machine = StateMachine<Int>(steps: 10)
                .rule("add") { n, tc in n += try tc.draw(.int(in: 0...10)) }
                .invariant("small", everyStep: true, pauseFaults: true) { n, _ in
                    if n > 3 {
                        throw Failed()
                    }
                }
            let outcome = try Property.run(settings: fewCasesUnshrunk) { tc in
                _ = try machine.run(tc, from: 0)
            }
            let drawn = try #require(outcome.failure).counterexamples[0].drawn
            #expect(drawn.last == "Invariant small failed:")
            let calls = control.calls()
            #expect(!calls.isEmpty)
            #expect(calls.count.isMultiple(of: 2))
            #expect(
                calls.enumerated().allSatisfy {
                    $1 == ($0.isMultiple(of: 2) ? "--pause" : "--unpause")
                }
            )
        }

        @Test("a fault-control program that fails is a usage error naming it")
        func failingProgramIsUsageError() throws {
            let control = try FaultControl(exitStatus: 3)
            let machine = StateMachine<Int>(steps: 5)
                .rule("add") { n, tc in n += try tc.draw(.int(in: 0...10)) }
                .invariant("paused", pauseFaults: true) { _, _ in }
            #expect {
                _ = try Property.run(settings: fewCases) { tc in
                    _ = try machine.run(tc, from: 0)
                }
            } throws: { error in
                guard case HegelError.usage(let message) = error else {
                    return false
                }
                return message.contains(control.program.lastPathComponent)
            }
        }

        @Test("withFaultsPaused brackets its body, and rethrows the body's error")
        func withFaultsPaused() throws {
            let control = try FaultControl()
            let outcome = try Property.run(settings: fewCases) { tc in
                let n = try tc.draw(.int(in: 0...10))
                let seen = try tc.withFaultsPaused { control.calls().last }
                #expect(seen == "--pause")
                try tc.withFaultsPaused {
                    if n > 5 {
                        throw Failed()
                    }
                }
            }
            #expect(outcome.failure != nil)
            let calls = control.calls()
            #expect(calls.count.isMultiple(of: 2))
            #expect(
                calls.enumerated().allSatisfy {
                    $1 == ($0.isMultiple(of: 2) ? "--pause" : "--unpause")
                }
            )
        }
    #endif
}

#if !os(Windows)
    /// A stand-in for Antithesis's fault-control program: a script, named by
    /// `ANTITHESIS_FAULT_CONTROL` while this value lives, that logs the flag
    /// of each call and exits with `exitStatus`.
    private final class FaultControl: Sendable {
        let program: URL
        private let log: URL

        init(exitStatus: Int = 0) throws {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("hegel-faults-\(UUID().uuidString)")
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            program = directory.appendingPathComponent("fault-control")
            log = directory.appendingPathComponent("calls.log")
            try "".write(to: log, atomically: true, encoding: .utf8)
            let script = """
                #!/bin/sh
                echo "$1" >> '\(log.path)'
                exit \(exitStatus)

                """
            try script.write(to: program, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: program.path
            )
            setenv("ANTITHESIS_FAULT_CONTROL", program.path, 1)
        }

        deinit {
            unsetenv("ANTITHESIS_FAULT_CONTROL")
            try? FileManager.default.removeItem(at: program.deletingLastPathComponent())
        }

        /// The flags of every call so far, in order.
        func calls() -> [String] {
            let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            return text.split(separator: "\n").map(String.init)
        }
    }
#endif

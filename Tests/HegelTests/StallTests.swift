import Hegel
import Synchronization
import Testing

/// Counts hangs: how many started, and how many saw their task cancelled.
private final class Hangs: Sendable {
    private let starts = Atomic<Int>(0)
    private let cancels = Atomic<Int>(0)

    var started: Int { starts.load(ordering: .sequentiallyConsistent) }
    var cancelled: Int { cancels.load(ordering: .sequentiallyConsistent) }

    /// Waits until cancelled, for at most an hour.
    func hang() async {
        starts.add(1, ordering: .sequentiallyConsistent)
        await withTaskCancellationHandler {
            try? await Task.sleep(for: .seconds(3600))
        } onCancel: {
            cancels.add(1, ordering: .sequentiallyConsistent)
        }
    }

    /// Waits forever, ignoring cancellation, as a lost wakeup does.
    func hangForever() async {
        starts.add(1, ordering: .sequentiallyConsistent)
        await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
    }
}

@Suite("stall detection")
struct StallTests {
    @Test("a stall fails the test case, and shrinks to the smallest stalling input")
    func stallShrinks() async throws {
        let hangs = Hangs()
        let outcome = try await Property.run(settings: isolated) { tc in
            let n = try tc.draw(.int(in: 0...1000), named: "n")
            try await tc.withStallDetection(after: .milliseconds(300)) { heartbeat in
                for _ in 0..<min(n, 5) {
                    heartbeat.beat()
                }
                if n >= 10 {
                    await hangs.hang()
                }
            }
        }
        let counterexample = try #require(outcome.failure?.counterexamples.first)
        #expect(counterexample.drawn == ["let n = 10"])
        let stalled = try #require(counterexample.error as? Stalled)
        #expect(stalled.limit == .milliseconds(300))
        #expect(stalled.beats == 5)
        #expect(stalled.location.hasPrefix("HegelTests/StallTests.swift:"))
        #expect(hangs.started > 0)
    }

    @Test("slow work that keeps beating passes, though it takes longer than the limit")
    func slowButProgressing() async throws {
        let outcome = try await Property.run(settings: isolated.merging(Settings(testCases: 3))) {
            tc in
            // Twice the limit in all, in steps of a twentieth of it.
            try await tc.withStallDetection(after: .milliseconds(400)) { heartbeat in
                for _ in 0..<40 {
                    try await Task.sleep(for: .milliseconds(20))
                    heartbeat.beat()
                }
            }
        }
        #expect(outcome.failure == nil)
    }

    @Test("body's value is returned and its error rethrown, under its own origin")
    func passesThrough() async throws {
        let outcome = try await Property.run(settings: isolated) { tc in
            let n = try tc.draw(.int(in: 0...100), named: "n")
            let doubled = try await tc.withStallDetection(after: .seconds(5)) { _ in n * 2 }
            #expect(doubled == n * 2)
            _ = try await tc.withStallDetection(after: .seconds(5)) { _ in
                if n > 50 {
                    throw Failed()
                }
            }
        }
        let counterexample = try #require(outcome.failure?.counterexamples.first)
        #expect(counterexample.error is Failed)
        #expect(counterexample.drawn == ["let n = 51"])
    }

    @Test("a stalled task is cancelled")
    func cancelsTheStuckTask() async throws {
        let hangs = Hangs()
        _ = try await Property.run(settings: isolated.merging(Settings(testCases: 5))) { tc in
            try await tc.withStallDetection(after: .milliseconds(50)) { _ in
                await hangs.hang()
            }
        }
        #expect(hangs.started > 0)
        // The cancel lands at once, but the counter runs in the hang's
        // task, which may not have run its handler yet.
        let deadline = ContinuousClock.now + .seconds(5)
        while hangs.cancelled < hangs.started, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(hangs.cancelled == hangs.started)
    }

    @Test("a hang that ignores cancellation still fails the test case")
    func ignoresCancellation() async throws {
        let hangs = Hangs()
        let outcome = try await Property.run(settings: isolated.merging(Settings(testCases: 5))) {
            tc in
            try await tc.withStallDetection(after: .milliseconds(50)) { _ in
                await hangs.hangForever()
            }
        }
        let counterexample = try #require(outcome.failure?.counterexamples.first)
        #expect(counterexample.error is Stalled)
    }

    @Test("a stall's origin is its call site, so distinct sites are distinct bugs")
    func distinctOrigins() async throws {
        let hangs = Hangs()
        let few = isolated.merging(Settings(testCases: 5))
        let first = try await Property.run(settings: few) { tc in
            try await tc.withStallDetection(after: .milliseconds(10)) { _ in await hangs.hang() }
        }
        let second = try await Property.run(settings: few) { tc in
            try await tc.withStallDetection(after: .milliseconds(10)) { _ in await hangs.hang() }
        }
        let origins = [first, second].compactMap { $0.failure?.counterexamples.first?.origin }
        #expect(origins.count == 2)
        #expect(Set(origins).count == 2)
        #expect(origins.allSatisfy { $0.hasPrefix("Stalled at HegelTests/StallTests.swift:") })
    }

    @Test("shrinking a stall tries candidates with a shorter limit; the report has the full one")
    func shrinksFaster() async throws {
        let full: Duration = .seconds(1)
        let hangs = Hangs()
        let clock = ContinuousClock()
        var outcome: PropertyOutcome?
        let elapsed = try await clock.measure {
            outcome = try await Property.run(settings: isolated) { tc in
                let n = try tc.draw(.int(in: 0...1000), named: "n")
                try await tc.withStallDetection(after: full) { heartbeat in
                    heartbeat.beat()
                    if n >= 10 {
                        await hangs.hang()
                    }
                }
            }
        }
        let counterexample = try #require(outcome?.failure?.counterexamples.first)
        #expect(counterexample.drawn == ["let n = 10"])
        #expect((counterexample.error as? Stalled)?.limit == full)
        // At the full limit, every stall would take at least `full`. The
        // first stall and the replays a report is built from still do, but
        // the shrink candidates between them get a fraction of it.
        #expect(hangs.started >= 10)
        #expect(elapsed < full * hangs.started * 3 / 4)
    }
}

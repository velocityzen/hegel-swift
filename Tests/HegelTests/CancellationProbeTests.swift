import Hegel
import Synchronization
import Testing

@Suite("CancellationProbe")
struct CancellationProbeTests {
    @Test("a hang's cancel is counted by the cancel itself, before its task runs again")
    func countsPromptly() async throws {
        let probe = CancellationProbe()
        let task = Task { await probe.hang() }
        while probe.started == 0 { await Task.yield() }
        // Nothing between the cancel and the reads lets the hanging task
        // run, so only the cancellation handler can have counted it.
        #expect(probe.uncancelled == 1)
        task.cancel()
        #expect(probe.cancelled == 1)
        #expect(probe.uncancelled == 0)
        #expect(await task.value)
    }

    @Test("a hang in a cancelled task returns at once, counted as cancelled")
    func alreadyCancelled() async throws {
        let probe = CancellationProbe()
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return await probe.hang()
        }
        task.cancel()
        #expect(await task.value)
        #expect(probe.started == 1)
        #expect(probe.uncancelled == 0)
    }

    @Test("a hang that runs out its limit stays uncancelled")
    func limit() async throws {
        let probe = CancellationProbe()
        let cancelled = await probe.hang(atMost: .milliseconds(10))
        #expect(!cancelled)
        #expect(probe.started == 1)
        #expect(probe.uncancelled == 1)
    }

    @Test("a property finds work that is left running after its caller is cancelled")
    func findsLeakedWork() async throws {
        let outcome = try await Property.run(settings: isolated) { tc in
            let jobs = try tc.draw(.int(in: 1...5), named: "jobs")
            let probe = CancellationProbe()
            _ = try await tc.withRandomCancellation(
                checkpoints: 0...jobs,
                endsWithin: .seconds(5)
            ) { cancellation in
                await withTaskGroup(of: Void.self) { group in
                    for job in 1...jobs {
                        cancellation.checkpoint("job \(job)")
                        if job == 3 {
                            // A bug: an unstructured task doesn't inherit
                            // the group's cancellation.
                            Task { await probe.hang(atMost: .seconds(5)) }
                        } else {
                            group.addTask { await probe.hang(atMost: .seconds(5)) }
                        }
                    }
                    group.cancelAll()
                }
            }
            // The task group waited for its children, and their cancels
            // are counted, so only the leaked hang can be left.
            if jobs >= 3 {
                while probe.started < jobs { await Task.yield() }
            }
            if probe.uncancelled != 0 {
                throw Failed()
            }
        }
        let counterexample = try #require(outcome.failure?.counterexamples.first)
        #expect(counterexample.drawn.first == "let jobs = 3")
    }
}

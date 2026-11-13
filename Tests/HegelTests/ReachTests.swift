import Foundation
import Hegel
import Testing

/// The labels and passing-case count of a run's unmet reach claims, or nil
/// when it met them.
private func unreached(_ run: () throws -> PropertyOutcome) throws -> (
    labels: [String], testCases: Int
)? {
    do {
        _ = try run()
        return nil
    } catch HegelError.unreached(let labels, let testCases) {
        return (labels, testCases)
    }
}

@Suite("reach claims")
struct ReachTests {
    @Test("a claim some passing case reaches is met")
    func reached() throws {
        let outcome = try Property.run(settings: isolated, reaching: ["big"]) { tc in
            let n = try tc.draw(.int(in: 0...100), named: "n")
            if n > 50 {
                try tc.event("big")
            }
        }
        #expect(outcome.failure == nil)
    }

    @Test("an unmet claim fails the run, naming only the unmet labels and the cases that ran")
    func unmet() throws {
        let result = try unreached {
            try Property.run(settings: isolated, reaching: ["big", "huge", "small"]) { tc in
                let n = try tc.draw(.int(in: 0...100), named: "n")
                try tc.event(n > 50 ? "big" : "small")
                if n > 1000 {
                    try tc.event("huge")
                }
            }
        }
        let (labels, testCases) = try #require(result)
        #expect(labels == ["huge"])
        #expect(testCases > 0)
        #expect(
            HegelError.unreached(labels, testCases: testCases).description.contains("\"huge\"")
        )
    }

    @Test("a numeric event's label counts")
    func numericEvents() throws {
        let outcome = try Property.run(settings: isolated, reaching: ["size"]) { tc in
            let xs = try tc.draw(.array(of: .int()), named: "xs")
            try tc.event("size", value: Double(xs.count))
        }
        #expect(outcome.failure == nil)
    }

    @Test("events from concurrently workers count")
    func workerEvents() async throws {
        let outcome = try await Property.run(settings: isolated, reaching: ["worker 1 drew big"]) {
            tc in
            _ = try await tc.concurrently(workers: 2) { worker, tc in
                let n = try tc.draw(.int(in: 0...100), named: "n")
                if worker == 1, n > 50 {
                    try tc.event("worker 1 drew big")
                }
            }
        }
        #expect(outcome.failure == nil)
    }

    @Test("events from state machine steps count")
    func stepEvents() throws {
        let machine = StateMachine<Int>(steps: 10)
            .rule("add") { n, tc in
                let k = try tc.draw(.int(in: 0...10), named: "k")
                n += k
                if n > 20 {
                    try tc.event("total past 20")
                }
            }
        let outcome = try Property.run(settings: isolated, reaching: ["total past 20"]) { tc in
            _ = try machine.run(tc, from: 0)
        }
        #expect(outcome.failure == nil)
    }

    @Test("a rejected case's events don't count")
    func rejectedCases() throws {
        let result = try unreached {
            try Property.run(settings: isolated, reaching: ["big"]) { tc in
                let n = try tc.draw(.int(in: 0...100), named: "n")
                if n > 50 {
                    try tc.event("big")
                    try tc.reject()
                }
            }
        }
        #expect(result?.labels == ["big"])
    }

    @Test("explicit examples' events don't count: the claim is about generated cases")
    func explicitEventsDontCount() throws {
        let result = try unreached {
            try Property.run(settings: isolated, examples: [["n": 999]], reaching: ["huge"]) { tc in
                let n = try tc.draw(.int(in: 0...100), named: "n")
                if n > 500 {
                    try tc.event("huge")
                }
            }
        }
        #expect(result?.labels == ["huge"])
    }

    @Test("a failing run doesn't judge its claims")
    func failingRun() throws {
        let outcome = try Property.run(settings: isolated, reaching: ["never"]) { tc in
            let n = try tc.draw(.int(in: 0...100), named: "n")
            if n > 50 {
                throw Failed()
            }
        }
        #expect(outcome.failure != nil)
    }

    @Test("a replayed reproduce blob doesn't judge the claims")
    func blobReplay() throws {
        let body: (TestCase) throws -> Void = { tc in
            let n = try tc.draw(.int(in: 0...100), named: "n")
            if n > 50 {
                throw Failed()
            }
        }
        let first = try Property.run(settings: isolated, body)
        let blob = try #require(first.failure?.counterexamples.first?.reproductionBlob)
        let replay = try Property.run(
            settings: isolated,
            reproducing: blob,
            reaching: ["never"],
            body
        )
        #expect(replay.failure != nil)
    }

    @Test("a run of explicit examples only doesn't judge the claims")
    func explicitOnly() throws {
        let outcome = try Property.run(
            settings: isolated.merging(Settings(phases: .explicit)),
            examples: [["n": 1], ["n": 2]],
            reaching: ["never"]
        ) { tc in
            _ = try tc.draw(.int(in: 0...100), named: "n")
        }
        #expect(outcome.failure == nil)
    }

    @Test("a stored failure that still fails doesn't judge the claims")
    func storedFailureReplay() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hegel-reach-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = Settings(derandomize: true, database: .path(directory.path))
        let body: (TestCase) throws -> Void = { tc in
            let n = try tc.draw(.int(in: 0...100), named: "n")
            if n > 50 {
                throw Failed()
            }
        }
        let first = try Property.run(settings: settings, databaseKey: "reach-stored", body)
        #expect(first.failure != nil)
        let replay = try Property.run(
            settings: settings.merging(Settings(phases: [.reuse])),
            databaseKey: "reach-stored",
            reaching: ["never"],
            body
        )
        #expect(replay.failure != nil)
    }
}

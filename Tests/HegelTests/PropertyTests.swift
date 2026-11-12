import Hegel
import Testing

struct Failed: Error, CustomStringConvertible {
    var description: String { "the property failed" }
}

/// Settings for tests that assert on the outcome of a run: no database, so
/// one test's stored failures don't leak into the next run, and
/// derandomized, so a run finds the same examples locally as on CI, whose
/// profile derandomizes.
let isolated = Settings(derandomize: true, database: .disabled, printBlob: true)

@Suite("Property runs")
struct PropertyTests {
    @Test("a property that holds passes")
    func passes() throws {
        let outcome = try Property.run(settings: isolated) { tc in
            let x = try tc.draw(.int(in: -1000...1000))
            let y = try tc.draw(.int(in: -1000...1000))
            if x + y != y + x {
                throw Failed()
            }
        }
        #expect(outcome.failure == nil)
    }

    @Test("an integer failure shrinks to the boundary")
    func shrinksIntegers() throws {
        let outcome = try Property.run(settings: isolated) { tc in
            let n = try tc.draw(.int(), named: "n")
            if n >= 10 {
                throw Failed()
            }
        }
        let failure = try #require(outcome.failure)
        #expect(failure.counterexamples.count == 1)
        #expect(failure.counterexamples[0].drawn == ["let n = 10"])
        #expect(failure.counterexamples[0].reproductionBlob != nil)
    }

    @Test("an array failure shrinks to a minimal array")
    func shrinksArrays() throws {
        let outcome = try Property.run(settings: isolated) { tc in
            let xs = try tc.draw(.array(of: .int(in: 0...100)), named: "xs")
            if xs.reduce(0, +) > 100 {
                throw Failed()
            }
        }
        let failure = try #require(outcome.failure)
        #expect(failure.counterexamples[0].drawn == ["let xs = [1, 100]"])
    }

    @Test("unnamed draws are numbered")
    func numbersDraws() throws {
        let outcome = try Property.run(settings: isolated) { tc in
            let a = try tc.draw(.bool())
            let b = try tc.draw(.bool())
            if a && b {
                throw Failed()
            }
        }
        let failure = try #require(outcome.failure)
        #expect(failure.counterexamples[0].drawn == ["let draw_1 = true", "let draw_2 = true"])
    }

    @Test("a reproduce blob replays the failure")
    func replaysBlob() throws {
        let body: (TestCase) throws -> Void = { tc in
            let n = try tc.draw(.int(in: 0...1000), named: "n")
            if n > 500 {
                throw Failed()
            }
        }
        let first = try #require(try Property.run(settings: isolated, body).failure)
        let blob = try #require(first.counterexamples[0].reproductionBlob)
        let replay = try #require(
            try Property.run(settings: isolated, reproducing: blob, body).failure
        )
        #expect(replay.counterexamples[0].drawn == ["let n = 501"])
    }

    @Test("rejecting every case is unsatisfiable")
    func unsatisfiable() {
        #expect(throws: HegelError.self) {
            try Property.run(settings: isolated) { tc in
                try tc.reject()
            }
        }
    }

    @Test("distinct errors are distinct failures")
    func multipleFailures() throws {
        struct Negative: Error {}
        struct Large: Error {}
        let settings = isolated.merging(Settings(reportMultipleFailures: true))
        let outcome = try Property.run(settings: settings) { tc in
            let n = try tc.draw(.int(in: -1000...1000), named: "n")
            if n < 0 { throw Negative() }
            if n > 100 { throw Large() }
        }
        let failure = try #require(outcome.failure)
        let drawn = Set(failure.counterexamples.map(\.drawn))
        #expect(drawn == [["let n = -1"], ["let n = 101"]])
    }

    @Test("check throws the failure")
    func checkThrows() {
        #expect(throws: PropertyFailure.self) {
            try Property.check(settings: isolated) { tc in
                _ = try tc.draw(.int())
                throw Failed()
            }
        }
    }

    @Test("async properties run")
    func asyncProperty() async throws {
        let outcome = try await Property.run(settings: isolated) { tc in
            let n = try tc.draw(.int(in: 0...100), named: "n")
            await Task.yield()
            if n > 50 {
                throw Failed()
            }
        }
        let failure = try #require(outcome.failure)
        #expect(failure.counterexamples[0].drawn == ["let n = 51"])
    }
}

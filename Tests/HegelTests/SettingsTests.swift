@testable import Hegel
import Testing

@Suite("settings")
struct SettingsTests {
    @Test("HEGEL_TEST_CASES wins over testCases, and nothing else changes")
    func testCasesVariableWins() throws {
        try Property.check(settings: isolated) { tc in
            let testCases = try tc.draw(.optional(.int()), named: "testCases")
            let seed = try tc.draw(.optional(Gen<UInt64>.integer()), named: "seed")
            let profile = try tc.draw(.optional(.string()), named: "profile")
            let value = try tc.draw(.optional(.string()), named: "value")
            let others = try tc.draw(
                .dictionary(keys: .string(), values: .string()),
                named: "others"
            ).filter { $0.key != Settings.testCasesVariable }
            var environment = others
            environment[Settings.testCasesVariable] = value
            let settings = Settings(profile: profile, testCases: testCases, seed: seed)

            let yielded = settings.yieldingTo(environment: environment)

            let isSet = !(value ?? "").isEmpty
            #expect(yielded.testCases == (isSet ? nil : testCases))
            var rest = yielded
            rest.testCases = testCases
            #expect(rest == settings)
        }
    }

    @Test("HEGEL_TEST_CASES_SCALE multiplies the resolved count, and HEGEL_TEST_CASES wins")
    func testCasesScale() throws {
        let scaleText = Gen.oneOf(
            .string(),
            Gen.double().map { "\($0)" },
            Gen<Int64>.integer().map { "\($0)" },
            Gen<UInt64>.integer().map { "\($0)" }
        )
        try Property.check(settings: isolated) { tc in
            let resolved = try tc.draw(Gen<UInt64>.integer(), named: "resolved")
            let scale = try tc.draw(.optional(scaleText), named: "scale")
            let testCases = try tc.draw(.optional(.string()), named: "testCases")
            let others = try tc.draw(
                .dictionary(keys: .string(), values: .string()),
                named: "others"
            ).filter {
                $0.key != Settings.testCasesVariable && $0.key != Settings.testCasesScaleVariable
            }
            var environment = others
            environment[Settings.testCasesScaleVariable] = scale
            environment[Settings.testCasesVariable] = testCases

            let result: Result<UInt64?, HegelError> = Result { () throws(HegelError) in
                try Settings.scaledTestCases(resolved, environment: environment)
            }

            guard let scale, !scale.isEmpty, (testCases ?? "").isEmpty else {
                #expect(try result.get() == nil)
                return
            }
            guard let factor = Double(scale), factor.isFinite, factor > 0 else {
                guard case .failure(.usage(let message)) = result else {
                    Issue.record("expected a usage error, got \(result)")
                    return
                }
                #expect(message.contains(Settings.testCasesScaleVariable))
                return
            }
            let scaled = try #require(try result.get())
            #expect(scaled >= 1)
            if factor >= 1 { #expect(scaled >= resolved) }
            if factor <= 1 { #expect(scaled <= max(resolved, 1)) }
            if let k = UInt64(exactly: factor) {
                let (product, overflow) = resolved.multipliedReportingOverflow(by: k)
                if !overflow, product < 1 << 53 { #expect(scaled == max(product, 1)) }
                if overflow { #expect(scaled == .max) }
            }
        }
    }
}

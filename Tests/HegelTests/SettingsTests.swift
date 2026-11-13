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
}

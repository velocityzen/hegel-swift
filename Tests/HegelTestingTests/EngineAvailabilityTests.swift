import Hegel
import HegelTesting
import Testing

@Suite("engine availability")
struct EngineAvailabilityTests {
    @Test
    func theEngineIsLinkedWhereLibhegelIsBuilt() {
        #if (os(macOS) && !targetEnvironment(macCatalyst)) || os(Linux) || os(Windows)
            #expect(isEngineAvailable)
        #else
            #expect(!isEngineAvailable)
        #endif
    }

    @Test(.enabled(if: !isEngineAvailable))
    func withoutAnEngineARunThrows() {
        #expect {
            try Property.check { _ in }
        } throws: { error in
            guard case .engineUnavailable(let platform) = error as? HegelError else {
                return false
            }
            return String(describing: error).contains("isn't available on \(platform)")
        }
    }

    /// Without an engine the property skips the test, so the expectation
    /// after it runs only where the property ran.
    @Test(.hegel)
    func withoutAnEngineAPropertySkipsItsTest() throws {
        try property { _ in }
        #expect(isEngineAvailable)
    }
}

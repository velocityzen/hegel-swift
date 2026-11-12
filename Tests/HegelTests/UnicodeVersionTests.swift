import CHegel
import Testing

@testable import Hegel

@Suite("Unicode version")
struct UnicodeVersionTests {
    @Test("is the standard library's, in a form the engine takes")
    func hostVersion() throws {
        let parts = hostUnicodeVersion.split(separator: ".").compactMap { Int($0) }
        #expect(parts.count == 3)
        #expect(parts[0] >= 14)
        // The newest scalar the tables know is from that version.
        let newest = (0...0x10FFFF).compactMap { Unicode.Scalar(UInt32($0))?.properties.age }
            .max { ($0.major, $0.minor) < ($1.major, $1.minor) }
        #expect(newest.map { "\($0.major).\($0.minor).0" } == hostUnicodeVersion)

        let context = hegel_context_new()
        defer { hegel_context_free(context) }
        let code = hostUnicodeVersion.withHegelString { hegel_set_unicode_version(context, $0) }
        #expect(code == HEGEL_OK)
    }
}

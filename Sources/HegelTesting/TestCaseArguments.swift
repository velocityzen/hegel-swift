import Testing

/// The arguments of one test case of a parameterized test.
///
/// Swift Testing keeps a test case's arguments behind SPI that its macOS
/// framework doesn't export, so they are read by reflection. If a toolchain
/// lays them out differently, `init` returns nil and the test case is
/// treated as the whole test, as it was before arguments were read.
struct TestCaseArguments: Sendable, Equatable {
    struct Argument: Sendable, Equatable {
        /// The parameter's name, as the test's body sees it.
        var name: String
        /// Swift Testing's ID for the value: a digest of its encoding, or
        /// the bytes of its description when it isn't encodable.
        var id: [UInt8]
        /// The value as Swift Testing shows it, such as `"fast"` for a
        /// string.
        var value: String
    }

    var arguments: [Argument]

    init(_ arguments: [Argument]) {
        self.arguments = arguments
    }

    /// The arguments of `testCase`, or nil if it isn't parameterized or its
    /// arguments can't be read.
    init?(_ testCase: Test.Case) {
        guard testCase.isParameterized,
            let kind = Self.field("_kind", of: testCase),
            let parameterized = Self.field("parameterized", of: kind),
            let list = Self.field("arguments", of: parameterized)
        else {
            return nil
        }
        var arguments: [Argument] = []
        for argument in Mirror(reflecting: list).children.map(\.value) {
            guard let value = Self.field("value", of: argument),
                let id = Self.field("id", of: argument).flatMap({ Self.field("bytes", of: $0) })
                    as? [UInt8],
                let parameter = Self.field("parameter", of: argument),
                let firstName = Self.field("firstName", of: parameter) as? String
            else {
                return nil
            }
            let secondName = Self.field("secondName", of: parameter) as? String
            arguments.append(
                Argument(
                    name: secondName ?? firstName,
                    id: id,
                    value: String(describingForTest: value)
                )
            )
        }
        guard !arguments.isEmpty else {
            return nil
        }
        self.arguments = arguments
    }

    /// Names the arguments as a failure report does: `mode: "fast", n: 3`.
    var label: String {
        arguments.map { "\($0.name): \($0.value)" }.joined(separator: ", ")
    }

    /// Identifies the test case among the test's others, from Swift
    /// Testing's argument IDs.
    var key: String {
        arguments.map { argument in
            argument.id.map { byte in
                let hex = String(byte, radix: 16)
                return byte < 16 ? "0" + hex : hex
            }.joined()
        }.joined(separator: ",")
    }

    private static func field(_ label: String, of subject: Any) -> Any? {
        Mirror(reflecting: subject).children.first { $0.label == label }?.value
    }
}

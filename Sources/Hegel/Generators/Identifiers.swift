import CHegel

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

extension Gen where Value == UUID {
    /// UUIDs, never the nil UUID.
    ///
    /// With a `version`, the version and variant bits are set as RFC 4122
    /// says, so `.uuid(version: 4)` draws random-style UUIDs. Without one,
    /// all 128 bits vary.
    public static func uuid(version: Int? = nil) -> Gen<UUID> {
        if let version {
            precondition((0...15).contains(version), "a UUID version is in 0...15")
        }
        return Gen(label: .uuid) { tc, printer in
            var bytes = [UInt8](repeating: 0, count: 16)
            try bytes.withUnsafeMutableBufferPointer { buffer in
                try tc.call {
                    hegel_generate_uuid(
                        $0,
                        tc.raw,
                        UInt8(version ?? 0),
                        version != nil,
                        buffer.baseAddress
                    )
                }
            }
            let b = bytes
            let value = UUID(
                uuid: (
                    b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                    b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]
                )
            )
            printer.value(value)
            return value
        }
    }
}

/// An IPv4 address.
public struct IPv4Address: Hashable, Sendable, CustomStringConvertible {
    /// The address's 4 bytes, in network order.
    public let bytes: [UInt8]

    public init(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) {
        bytes = [a, b, c, d]
    }

    /// Dotted decimal: `192.168.0.1`.
    public var description: String {
        bytes.map(String.init).joined(separator: ".")
    }
}

/// An IPv6 address.
public struct IPv6Address: Hashable, Sendable, CustomStringConvertible {
    /// The address's 16 bytes, in network order.
    public let bytes: [UInt8]

    /// The address with these 16 bytes, in network order.
    public init(bytes: [UInt8]) {
        precondition(bytes.count == 16, "an IPv6 address has 16 bytes")
        self.bytes = bytes
    }

    /// The text form RFC 5952 recommends: lowercase hex, the longest run of
    /// zero groups shortened to `::`, and IPv4-mapped addresses as
    /// `::ffff:192.0.2.1`.
    public var description: String {
        let groups = (0..<8).map { UInt16(bytes[2 * $0]) << 8 | UInt16(bytes[2 * $0 + 1]) }
        if groups[0..<5].allSatisfy({ $0 == 0 }) && groups[5] == 0xffff {
            return "::ffff:" + bytes[12...].map(String.init).joined(separator: ".")
        }
        // The longest run of two or more zero groups, the first on a tie.
        var best: Range<Int>?
        var start: Int?
        for index in 0...8 {
            if index < 8, groups[index] == 0 {
                start = start ?? index
            } else if let runStart = start {
                if index - runStart >= 2, index - runStart > (best?.count ?? 0) {
                    best = runStart..<index
                }
                start = nil
            }
        }
        let hex = { (range: Range<Int>) in
            groups[range].map { String($0, radix: 16) }.joined(separator: ":")
        }
        guard let best else {
            return hex(0..<8)
        }
        return hex(0..<best.lowerBound) + "::" + hex(best.upperBound..<8)
    }
}

extension Gen where Value == IPv4Address {
    /// IPv4 addresses, any of the 2³² of them.
    public static var ipv4: Gen<IPv4Address> {
        Gen(label: .ipv4) { tc, printer in
            var b = [UInt8](repeating: 0, count: 4)
            try b.withUnsafeMutableBufferPointer { buffer in
                try tc.call { hegel_generate_ipv4($0, tc.raw, buffer.baseAddress) }
            }
            let value = IPv4Address(b[0], b[1], b[2], b[3])
            printer.value(value)
            return value
        }
    }
}

extension Gen where Value == IPv6Address {
    /// IPv6 addresses, any of the 2¹²⁸ of them.
    public static var ipv6: Gen<IPv6Address> {
        Gen(label: .ipv6) { tc, printer in
            var bytes = [UInt8](repeating: 0, count: 16)
            try bytes.withUnsafeMutableBufferPointer { buffer in
                try tc.call { hegel_generate_ipv6($0, tc.raw, buffer.baseAddress) }
            }
            let value = IPv6Address(bytes: bytes)
            printer.value(value)
            return value
        }
    }
}

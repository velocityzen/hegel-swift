import CHegel

// MARK: - Booleans

extension Gen where Value == Bool {
    /// `true` with probability `probability`. Shrinks toward `false`.
    public static func bool(probability: Double = 0.5) -> Gen<Bool> {
        Gen(label: .bool) { tc, printer in
            let value = try tc.generateBool(probability: probability)
            printer.text(value ? "true" : "false")
            return value
        }
    }
}

// MARK: - Integers

extension Gen where Value: FixedWidthInteger & Sendable {
    /// An integer in `range`, the whole type by default. Shrinks toward zero,
    /// or toward the bound nearest zero when zero is out of range.
    public static func integer(in range: ClosedRange<Value> = Value.min...Value.max) -> Gen<Value> {
        let label = Label.integer.combined(with: .named(String(reflecting: Value.self)))
        if let lower = Int64(exactly: range.lowerBound),
            let upper = Int64(exactly: range.upperBound)
        {
            return Gen(label: label) { tc, printer in
                let value = Value(truncatingIfNeeded: try tc.generateInteger(lower, upper))
                printer.text(String(value))
                return value
            }
        }
        let lower = twosComplementBytes(range.lowerBound)
        let upper = twosComplementBytes(range.upperBound)
        let capacity = max(lower.count, upper.count)
        return Gen(label: label) { tc, printer in
            let bytes = try tc.generateBigInteger(lower, upper, capacity: capacity)
            let value = Value(truncatingIfNeeded: littleEndianUInt128(bytes))
            printer.text(String(value))
            return value
        }
    }

    /// An integer in `range`.
    public static func integer(in range: Range<Value>) -> Gen<Value> {
        precondition(!range.isEmpty, "integer(in:) needs a non-empty range")
        return integer(in: range.lowerBound...(range.upperBound - 1))
    }
}

extension Gen where Value == Int {
    /// An `Int` in `range`, any `Int` by default.
    public static func int(in range: ClosedRange<Int> = .min ... .max) -> Gen<Int> {
        integer(in: range)
    }

    /// An `Int` in `range`.
    public static func int(in range: Range<Int>) -> Gen<Int> {
        integer(in: range)
    }
}

/// The two's-complement little-endian bytes of `value`, one byte wider than
/// the type so the sign is explicit.
func twosComplementBytes<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
    var bytes: [UInt8] = []
    for word in value.words {
        var word = word
        for _ in 0..<MemoryLayout<UInt>.size {
            bytes.append(UInt8(truncatingIfNeeded: word))
            word >>= 8
        }
    }
    bytes.append(T.isSigned && value < 0 ? 0xFF : 0x00)
    return bytes
}

/// The low 128 bits of a two's-complement little-endian byte buffer.
func littleEndianUInt128(_ bytes: [UInt8]) -> UInt128 {
    var value: UInt128 = 0
    for (index, byte) in bytes.prefix(16).enumerated() {
        value |= UInt128(byte) << (8 * index)
    }
    if bytes.count < 16, let last = bytes.last, last & 0x80 != 0 {
        value |= UInt128.max << (8 * bytes.count)
    }
    return value
}

// MARK: - Floating point

extension Gen where Value == Double {
    /// A `Double` in `range`, or any `Double` by default.
    ///
    /// NaN and the infinities are drawn by default only when there is no
    /// range.
    public static func double(
        in range: ClosedRange<Double>? = nil,
        allowNaN: Bool? = nil,
        allowInfinity: Bool? = nil,
        excludeLowerBound: Bool = false,
        excludeUpperBound: Bool = false
    ) -> Gen<Double> {
        floatingPoint(
            width: 64,
            range: range,
            allowNaN: allowNaN ?? (range == nil),
            allowInfinity: allowInfinity ?? (range == nil),
            excludeLowerBound: excludeLowerBound,
            excludeUpperBound: excludeUpperBound,
            smallestNonzeroMagnitude: Double.leastNonzeroMagnitude
        )
    }
}

extension Gen where Value == Float {
    /// A `Float` in `range`, or any `Float` by default.
    ///
    /// NaN and the infinities are drawn by default only when there is no
    /// range.
    public static func float(
        in range: ClosedRange<Float>? = nil,
        allowNaN: Bool? = nil,
        allowInfinity: Bool? = nil,
        excludeLowerBound: Bool = false,
        excludeUpperBound: Bool = false
    ) -> Gen<Float> {
        Gen<Double>.floatingPoint(
            width: 32,
            range: range.map { Double($0.lowerBound)...Double($0.upperBound) },
            allowNaN: allowNaN ?? (range == nil),
            allowInfinity: allowInfinity ?? (range == nil),
            excludeLowerBound: excludeLowerBound,
            excludeUpperBound: excludeUpperBound,
            smallestNonzeroMagnitude: Double(Float.leastNonzeroMagnitude)
        )
        .printed(with: { value, printer in printer.text(String(Float(value))) })
        .mapSilently { Float($0) }
    }
}

extension Gen where Value == Double {
    static func floatingPoint(
        width: UInt32,
        range: ClosedRange<Double>?,
        allowNaN: Bool,
        allowInfinity: Bool,
        excludeLowerBound: Bool,
        excludeUpperBound: Bool,
        smallestNonzeroMagnitude: Double
    ) -> Gen<Double> {
        let lower = range?.lowerBound ?? -.infinity
        let upper = range?.upperBound ?? .infinity
        let label = Label.floatingPoint.combined(with: .named("width\(width)"))
        return Gen(label: label) { tc, printer in
            let value = try tc.generateFloat(
                width: width,
                min: lower,
                max: upper,
                allowNaN: allowNaN,
                allowInfinity: allowInfinity,
                excludeMin: excludeLowerBound,
                excludeMax: excludeUpperBound,
                smallestNonzeroMagnitude: smallestNonzeroMagnitude
            )
            printer.text(Self.literal(value))
            return value
        }
    }

    static func literal(_ value: Double) -> String {
        if value.isNaN {
            return "Double.nan"
        }
        if value.isInfinite {
            return value < 0 ? "-Double.infinity" : "Double.infinity"
        }
        return String(value)
    }
}

extension Gen {
    /// Transforms values without printing the result: the report keeps what
    /// this generator printed.
    func mapSilently<NewValue>(
        _ transform: @escaping @Sendable (Value) -> NewValue
    ) -> Gen<NewValue> {
        Gen<NewValue>(label: label) { tc, printer in
            transform(try body(tc, printer))
        }
    }
}

// MARK: - Bytes

extension Gen where Value == [UInt8] {
    /// A byte array whose length is in `count`. Without a range, the length
    /// is up to the engine's default maximum for bytes.
    public static func bytes(count: ClosedRange<Int>? = nil) -> Gen<[UInt8]> {
        let (minCount, maxCount) = sizeBounds(count, defaultMax: maxSizeDefault)
        return Gen(label: .bytes) { tc, printer in
            let bytes = try tc.generateBytes(minCount: minCount, maxCount: maxCount)
            printer.value(bytes)
            return bytes
        }
    }
}

/// libhegel's `HEGEL_MAX_SIZE_DEFAULT`: "no maximum given", for which the
/// engine applies its default size for text and bytes.
let maxSizeDefault = UInt64.max - 1

/// Engine size bounds for a count range: an explicit maximum at or above
/// the reserved "default" value becomes "no maximum".
func sizeBounds(_ count: ClosedRange<Int>?, defaultMax: UInt64) -> (UInt64, UInt64) {
    guard let count else {
        return (0, defaultMax)
    }
    precondition(count.lowerBound >= 0, "a count cannot be negative")
    let upper = UInt64(count.upperBound)
    return (UInt64(count.lowerBound), upper >= maxSizeDefault ? .max : upper)
}

import CHegel

/// An instant: whole seconds since the Unix epoch, and the nanoseconds
/// after that second, so -1.5 s is `-2` seconds and `500_000_000`
/// nanoseconds.
public struct Timestamp: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let seconds: Int
    public let nanoseconds: Int

    /// The instant `seconds` and `nanoseconds` after the Unix epoch.
    /// `nanoseconds` is in `0..<1_000_000_000`, and the instant lies in
    /// years ±999999, between `Timestamp.min` and `Timestamp.max`.
    public init(seconds: Int, nanoseconds: Int = 0) {
        precondition(
            (0...999_999_999).contains(nanoseconds),
            "nanoseconds must be in 0..<1_000_000_000"
        )
        precondition(
            (Self.min.seconds...Self.max.seconds).contains(seconds),
            "the instant must lie in years ±999999"
        )
        self.seconds = seconds
        self.nanoseconds = nanoseconds
    }

    private init(unchecked seconds: Int, _ nanoseconds: Int) {
        self.seconds = seconds
        self.nanoseconds = nanoseconds
    }

    /// -999999-01-01T00:00:00Z, the first instant Hegel draws.
    public static let min = Timestamp(unchecked: -31_619_087_596_800, 0)
    /// 999999-12-31T23:59:59.999999999Z, the last instant Hegel draws.
    public static let max = Timestamp(unchecked: 31_494_784_780_799, 999_999_999)

    /// The instant `utc` names in UTC.
    public init(utc: LocalDateTime) {
        self.init(
            unchecked: utc.date.daysSinceEpoch * 86_400 + utc.time.secondsSinceMidnight,
            utc.time.nanosecond
        )
    }

    /// The date and time of this instant in UTC.
    public var utc: LocalDateTime {
        let (days, second) = seconds.floorDivided(by: 86_400)
        return LocalDateTime(
            date: CalendarDate(daysSinceEpoch: days),
            time: TimeOfDay(
                hour: second / 3600,
                minute: second / 60 % 60,
                second: second % 60,
                nanosecond: nanoseconds
            )
        )
    }

    public static func < (lhs: Timestamp, rhs: Timestamp) -> Bool {
        (lhs.seconds, lhs.nanoseconds) < (rhs.seconds, rhs.nanoseconds)
    }

    /// RFC 3339 in UTC, as every Hegel frontend prints an instant:
    /// `2000-01-01T00:00:00Z`, `1969-12-31T23:59:58.5Z`.
    public var description: String {
        engineText { hegel_format_timestamp(nil, raw, $0) }
    }

    init(_ raw: hegel_timestamp_t) {
        self.init(unchecked: Int(raw.second), Int(raw.nanosecond))
    }

    var raw: hegel_timestamp_t {
        hegel_timestamp_t(second: Int64(seconds), nanosecond: UInt32(nanoseconds))
    }

}

extension Int {
    /// The quotient rounded toward negative infinity, and the remainder
    /// with the divisor's sign.
    fileprivate func floorDivided(by divisor: Int) -> (quotient: Int, remainder: Int) {
        let (quotient, remainder) = quotientAndRemainder(dividingBy: divisor)
        return remainder < 0 ? (quotient - 1, remainder + divisor) : (quotient, remainder)
    }
}

/// A UTC offset: a known number of seconds east of UTC, within ±25:59:59,
/// or RFC 3339's unknown offset, `-00:00`.
public enum UTCOffset: Hashable, Sendable, CustomStringConvertible {
    case known(seconds: Int)
    case unknown

    /// The largest offset Hegel draws, 25:59:59, in seconds.
    public static let maxSeconds = 93_599

    /// UTC itself, `+00:00`.
    public static let utc = UTCOffset.known(seconds: 0)

    /// The seconds east of UTC, or nil for the unknown offset.
    public var seconds: Int? {
        switch self {
            case .known(let seconds): seconds
            case .unknown: nil
        }
    }

    /// The values an offset draw restricts itself to.
    public enum Granularity: Hashable, Sendable, CaseIterable {
        case hours
        case quarterHours
        case minutes
        case seconds

        var raw: UInt32 {
            let value =
                switch self {
                    case .hours: HEGEL_OFFSET_GRANULARITY_HOURS
                    case .quarterHours: HEGEL_OFFSET_GRANULARITY_QUARTER_HOURS
                    case .minutes: HEGEL_OFFSET_GRANULARITY_MINUTES
                    case .seconds: HEGEL_OFFSET_GRANULARITY_SECONDS
                }
            return UInt32(value.rawValue)
        }
    }

    /// As every Hegel frontend prints an offset: `+05:30`, `-00:44:30`
    /// with the seconds when there are some, `+00:00` for UTC and `-00:00`
    /// for the unknown offset.
    public var description: String {
        engineText { hegel_format_offset(nil, raw, $0) }
    }

    init(seconds: Int32, known: Bool) {
        self = known ? .known(seconds: Int(seconds)) : .unknown
    }

    var raw: hegel_offset_t {
        switch self {
            case .known(let seconds): hegel_offset_t(seconds: Int32(seconds), known: true)
            case .unknown: hegel_offset_t(seconds: 0, known: false)
        }
    }

    /// The seconds the engine reports for this offset: 0 when unknown.
    var rawSeconds: Int32 { raw.seconds }
}

/// A calendar span: a count of each unit from years to nanoseconds, kept
/// apart rather than added up, since a month or a day has no fixed length.
public struct CalendarSpan: Hashable, Sendable, CustomStringConvertible {
    public var years: Int
    public var months: Int
    public var weeks: Int
    public var days: Int
    public var hours: Int
    public var minutes: Int
    public var seconds: Int
    public var milliseconds: Int
    public var microseconds: Int
    public var nanoseconds: Int

    public init(
        years: Int = 0,
        months: Int = 0,
        weeks: Int = 0,
        days: Int = 0,
        hours: Int = 0,
        minutes: Int = 0,
        seconds: Int = 0,
        milliseconds: Int = 0,
        microseconds: Int = 0,
        nanoseconds: Int = 0
    ) {
        self.years = years
        self.months = months
        self.weeks = weeks
        self.days = days
        self.hours = hours
        self.minutes = minutes
        self.seconds = seconds
        self.milliseconds = milliseconds
        self.microseconds = microseconds
        self.nanoseconds = nanoseconds
    }

    /// A unit of a span, largest first.
    public enum Unit: Hashable, Sendable, CaseIterable {
        case years
        case months
        case weeks
        case days
        case hours
        case minutes
        case seconds
        case milliseconds
        case microseconds
        case nanoseconds

        var raw: UInt32 {
            let value =
                switch self {
                    case .years: HEGEL_SPAN_UNIT_YEARS
                    case .months: HEGEL_SPAN_UNIT_MONTHS
                    case .weeks: HEGEL_SPAN_UNIT_WEEKS
                    case .days: HEGEL_SPAN_UNIT_DAYS
                    case .hours: HEGEL_SPAN_UNIT_HOURS
                    case .minutes: HEGEL_SPAN_UNIT_MINUTES
                    case .seconds: HEGEL_SPAN_UNIT_SECONDS
                    case .milliseconds: HEGEL_SPAN_UNIT_MILLISECONDS
                    case .microseconds: HEGEL_SPAN_UNIT_MICROSECONDS
                    case .nanoseconds: HEGEL_SPAN_UNIT_NANOSECONDS
                }
            return UInt32(value.rawValue)
        }
    }

    /// How a span draw signs its units.
    public enum Sign: Hashable, Sendable, CaseIterable {
        /// One sign for every unit, as a Temporal `Duration` has.
        case uniform
        /// Each unit signed on its own, as a Java `Period` is.
        case mixed
        /// Magnitudes only.
        case nonnegative

        var raw: UInt32 {
            let value =
                switch self {
                    case .uniform: HEGEL_SPAN_SIGN_UNIFORM
                    case .mixed: HEGEL_SPAN_SIGN_MIXED
                    case .nonnegative: HEGEL_SPAN_SIGN_NONNEGATIVE
                }
            return UInt32(value.rawValue)
        }
    }

    /// The count of `unit`.
    public subscript(unit: Unit) -> Int {
        get {
            switch unit {
                case .years: years
                case .months: months
                case .weeks: weeks
                case .days: days
                case .hours: hours
                case .minutes: minutes
                case .seconds: seconds
                case .milliseconds: milliseconds
                case .microseconds: microseconds
                case .nanoseconds: nanoseconds
            }
        }
        set {
            switch unit {
                case .years: years = newValue
                case .months: months = newValue
                case .weeks: weeks = newValue
                case .days: days = newValue
                case .hours: hours = newValue
                case .minutes: minutes = newValue
                case .seconds: seconds = newValue
                case .milliseconds: milliseconds = newValue
                case .microseconds: microseconds = newValue
                case .nanoseconds: nanoseconds = newValue
            }
        }
    }

    /// As every Hegel frontend prints a span: the units that are not zero,
    /// largest first, `1y 2mo 3d`; one leading `-` when every unit is
    /// negative, `-3d 4h`; a sign on every unit when they differ,
    /// `+1y -2mo`; and `0s` for the zero span.
    public var description: String {
        var value = raw
        return engineText { hegel_format_span(nil, &value, $0) }
    }

    init(_ raw: hegel_span_t) {
        self.init(
            years: Int(raw.years),
            months: Int(raw.months),
            weeks: Int(raw.weeks),
            days: Int(raw.days),
            hours: Int(raw.hours),
            minutes: Int(raw.minutes),
            seconds: Int(raw.seconds),
            milliseconds: Int(raw.milliseconds),
            microseconds: Int(raw.microseconds),
            nanoseconds: Int(raw.nanoseconds)
        )
    }

    var raw: hegel_span_t {
        hegel_span_t(
            years: Int64(years),
            months: Int64(months),
            weeks: Int64(weeks),
            days: Int64(days),
            hours: Int64(hours),
            minutes: Int64(minutes),
            seconds: Int64(seconds),
            milliseconds: Int64(milliseconds),
            microseconds: Int64(microseconds),
            nanoseconds: Int64(nanoseconds)
        )
    }
}

extension Gen where Value == Timestamp {
    /// Instants in `range`, each a whole number of `precision` units since
    /// the Unix epoch. Shrinks toward 2000-01-01T00:00:00Z, or the bound
    /// nearest it.
    public static func timestamp(
        in range: ClosedRange<Timestamp> = .min ... .max,
        precision: Precision = .nanoseconds
    ) -> Gen<Timestamp> {
        let failure = engineCheck {
            hegel_validate_timestamp($0, range.lowerBound.raw, range.upperBound.raw, precision.raw)
        }
        return Gen(label: .timestamp) { tc, printer in
            if let failure {
                throw HegelError.usage(failure)
            }
            let value = try drawTimestamp(tc, range, precision)
            printer.value(value)
            return value
        }
    }
}

extension Gen where Value == UTCOffset {
    /// Offsets in `range`, in seconds east of UTC, that are a whole number
    /// of `granularity` units, and the unknown offset `-00:00` too when
    /// `allowUnknown` is set. Shrinks to a known offset, then toward UTC or
    /// the bound nearest it.
    public static func utcOffset(
        in range: ClosedRange<Int> = -UTCOffset.maxSeconds...UTCOffset.maxSeconds,
        granularity: UTCOffset.Granularity = .seconds,
        allowUnknown: Bool = false
    ) -> Gen<UTCOffset> {
        let lower = Int32(clamping: range.lowerBound)
        let upper = Int32(clamping: range.upperBound)
        let failure = engineCheck {
            hegel_validate_offset($0, lower, upper, granularity.raw, allowUnknown)
        }
        return Gen(label: .utcOffset) { tc, printer in
            if let failure {
                throw HegelError.usage(failure)
            }
            var out = hegel_offset_t()
            try tc.call {
                hegel_generate_offset($0, tc.raw, lower, upper, granularity.raw, allowUnknown, &out)
            }
            let value = UTCOffset(seconds: out.seconds, known: out.known)
            printer.value(value)
            return value
        }
    }
}

extension Gen where Value == Duration {
    /// Durations in `range`, each a whole number of `precision` units. By
    /// default every duration of whole nanoseconds whose seconds fit in an
    /// `Int64`. Shrinks toward zero, or the bound nearest it.
    public static func duration(
        in range: ClosedRange<Duration>? = nil,
        precision: Precision = .nanoseconds
    ) -> Gen<Duration> {
        let lower = range.map { engineDuration($0.lowerBound, roundingUp: true) } ?? minDuration
        let upper = range.map { engineDuration($0.upperBound, roundingUp: false) } ?? maxDuration
        let failure = engineCheck { hegel_validate_duration($0, lower, upper, precision.raw) }
        return Gen(label: .duration) { tc, printer in
            if let failure {
                throw HegelError.usage(failure)
            }
            var out = hegel_duration_t()
            try tc.call { hegel_generate_duration($0, tc.raw, lower, upper, precision.raw, &out) }
            let value = Duration(out)
            printer.value(value)
            return value
        }
    }
}

private let nanosecondsPerSecond: Int128 = 1_000_000_000
private let minDuration = hegel_duration_t(seconds: .min, nanoseconds: -999_999_999)
private let maxDuration = hegel_duration_t(seconds: .max, nanoseconds: 999_999_999)

/// `duration` as the engine holds it: in whole nanoseconds, rounded up
/// or down to one, and clamped to the engine's range.
private func engineDuration(_ duration: Duration, roundingUp: Bool) -> hegel_duration_t {
    let (quotient, remainder) = duration.attoseconds.quotientAndRemainder(
        dividingBy: 1_000_000_000
    )
    var nanoseconds = quotient
    if roundingUp, remainder > 0 {
        nanoseconds += 1
    } else if !roundingUp, remainder < 0 {
        nanoseconds -= 1
    }
    let (seconds, fraction) = nanoseconds.quotientAndRemainder(dividingBy: nanosecondsPerSecond)
    guard seconds >= Int128(Int64.min) else {
        return minDuration
    }
    guard seconds <= Int128(Int64.max) else {
        return maxDuration
    }
    return hegel_duration_t(seconds: Int64(seconds), nanoseconds: Int32(fraction))
}

extension Duration {
    init(_ raw: hegel_duration_t) {
        self.init(
            attoseconds: (Int128(raw.seconds) * nanosecondsPerSecond + Int128(raw.nanoseconds))
                * 1_000_000_000
        )
    }
}

extension Gen where Value == CalendarSpan {
    /// Spans whose units each lie in their range in `units`, the units it
    /// leaves out always 0, signed as `sign` says. By default every unit,
    /// within ±`Int.max` (or `0...Int.max` for nonnegative spans). Shrinks
    /// toward the zero span, or the nearest value to it in each unit's
    /// range.
    public static func calendarSpan(
        _ units: [CalendarSpan.Unit: ClosedRange<Int>]? = nil,
        sign: CalendarSpan.Sign = .uniform
    ) -> Gen<CalendarSpan> {
        let everyUnit = (sign == .nonnegative ? 0 : -Int.max)...Int.max
        let bounds =
            units
            ?? Dictionary(uniqueKeysWithValues: CalendarSpan.Unit.allCases.map { ($0, everyUnit) })
        let spec = EngineObject(
            make: { hegel_span_spec_new($0, $1) },
            free: { _ = hegel_span_spec_free(nil, $0) },
            configure: { context, spec throws(EngineError) in
                try context.call { hegel_span_spec_set_sign($0, spec, sign.raw) }
                for unit in CalendarSpan.Unit.allCases {
                    guard let range = bounds[unit] else {
                        continue
                    }
                    try context.call {
                        hegel_span_spec_set_unit_bounds(
                            $0,
                            spec,
                            unit.raw,
                            Int64(range.lowerBound),
                            Int64(range.upperBound)
                        )
                    }
                }
                try context.call { hegel_span_spec_validate($0, spec) }
            }
        )
        return Gen(label: .calendarSpan) { tc, printer in
            let handle = try spec.handle()
            var out = hegel_span_t()
            try tc.call { hegel_generate_span($0, tc.raw, handle, &out) }
            let value = CalendarSpan(out)
            printer.value(value)
            return value
        }
    }
}

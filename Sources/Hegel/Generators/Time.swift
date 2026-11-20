import CHegel

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// The unit the time part of a drawn value is counted in: a time drawn
/// at `.seconds` has no fraction, and one at `.hours` is on the hour.
public enum Precision: Hashable, Sendable, CaseIterable {
    case nanoseconds
    case microseconds
    case milliseconds
    case seconds
    case minutes
    case hours

    /// The `hegel_precision_t` argument. A C enum's raw value is `UInt32`
    /// on Darwin and Linux but `Int32` on Windows, so convert.
    var raw: UInt32 {
        let value =
            switch self {
                case .nanoseconds: HEGEL_PRECISION_NANOSECONDS
                case .microseconds: HEGEL_PRECISION_MICROSECONDS
                case .milliseconds: HEGEL_PRECISION_MILLISECONDS
                case .seconds: HEGEL_PRECISION_SECONDS
                case .minutes: HEGEL_PRECISION_MINUTES
                case .hours: HEGEL_PRECISION_HOURS
            }
        return UInt32(value.rawValue)
    }
}

/// A day of the week, numbered as ISO 8601 does, from Monday.
public enum Weekday: Int, Hashable, Sendable, CaseIterable {
    case monday = 1
    case tuesday
    case wednesday
    case thursday
    case friday
    case saturday
    case sunday
}

/// A month of the year, numbered from January.
public enum Month: Int, Hashable, Sendable, CaseIterable {
    case january = 1
    case february
    case march
    case april
    case may
    case june
    case july
    case august
    case september
    case october
    case november
    case december
}

/// A date in the proleptic Gregorian calendar, with no time zone.
public struct CalendarDate: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    /// The date `year`-`month`-`day`, which must exist: `day` is at most
    /// the length of `month`, and `year` is within ±999999.
    public init(year: Int, month: Int, day: Int) {
        precondition(abs(year) <= 999_999, "year must be within ±999999")
        precondition((1...12).contains(month), "month must be in 1...12")
        precondition(
            (1...daysIn(month: month, year: year)).contains(day),
            "\(year)-\(month) has no day \(day)"
        )
        self.year = year
        self.month = month
        self.day = day
    }

    /// The date `year`-`month`-`day`.
    public init(year: Int, month: Month, day: Int) {
        self.init(year: year, month: month.rawValue, day: day)
    }

    /// -999999-01-01, the first date Hegel draws.
    public static let min = CalendarDate(year: -999_999, month: 1, day: 1)
    /// 999999-12-31, the last date Hegel draws.
    public static let max = CalendarDate(year: 999_999, month: 12, day: 31)

    public static func < (lhs: CalendarDate, rhs: CalendarDate) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    /// The day of the week the date falls on.
    public var weekday: Weekday {
        // 1970-01-01 was a Thursday.
        let offset = (daysSinceEpoch % 7 + 7 + 3) % 7
        return Weekday(rawValue: offset + 1)!
    }

    /// ISO 8601, as every Hegel frontend prints a date: `2000-01-31`, with
    /// a sign and six digits for a year past 9999 or before 0,
    /// `+010000-01-01`.
    public var description: String {
        engineText { hegel_format_date(nil, raw, $0) }
    }

    init(_ raw: hegel_date_t) {
        self.init(year: Int(raw.year), month: Int(raw.month), day: Int(raw.day))
    }

    var raw: hegel_date_t {
        hegel_date_t(year: Int32(year), month: UInt8(month), day: UInt8(day))
    }

    /// Days since 1970-01-01.
    var daysSinceEpoch: Int {
        // Howard Hinnant's days_from_civil.
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * ((month + 9) % 12) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    init(daysSinceEpoch days: Int) {
        // Howard Hinnant's civil_from_days.
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra =
            (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let shiftedMonth = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * shiftedMonth + 2) / 5 + 1
        let month = shiftedMonth < 10 ? shiftedMonth + 3 : shiftedMonth - 9
        self.init(year: yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month: month, day: day)
    }
}

/// A time of day, with no time zone and nanosecond precision.
public struct TimeOfDay: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let hour: Int
    public let minute: Int
    public let second: Int
    public let nanosecond: Int

    public init(hour: Int, minute: Int = 0, second: Int = 0, nanosecond: Int = 0) {
        precondition((0...23).contains(hour), "hour must be in 0...23")
        precondition((0...59).contains(minute), "minute must be in 0...59")
        precondition((0...59).contains(second), "second must be in 0...59")
        precondition((0...999_999_999).contains(nanosecond), "nanosecond must be below 1e9")
        self.hour = hour
        self.minute = minute
        self.second = second
        self.nanosecond = nanosecond
    }

    /// 00:00:00.
    public static let midnight = TimeOfDay(hour: 0)
    /// 23:59:59.999999999.
    public static let max = TimeOfDay(hour: 23, minute: 59, second: 59, nanosecond: 999_999_999)

    public static func < (lhs: TimeOfDay, rhs: TimeOfDay) -> Bool {
        (lhs.hour, lhs.minute, lhs.second, lhs.nanosecond)
            < (rhs.hour, rhs.minute, rhs.second, rhs.nanosecond)
    }

    /// ISO 8601: `13:05:00`, with a fraction when there is one,
    /// `13:05:00.25`.
    public var description: String {
        engineText { hegel_format_time(nil, raw, $0) }
    }

    init(_ raw: hegel_time_t) {
        self.init(
            hour: Int(raw.hour),
            minute: Int(raw.minute),
            second: Int(raw.second),
            nanosecond: Int(raw.nanosecond)
        )
    }

    var raw: hegel_time_t {
        hegel_time_t(
            hour: UInt8(hour),
            minute: UInt8(minute),
            second: UInt8(second),
            nanosecond: UInt32(nanosecond)
        )
    }

    var secondsSinceMidnight: Int { (hour * 60 + minute) * 60 + second }
}

/// A date and a time of day, with no time zone.
public struct LocalDateTime: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let date: CalendarDate
    public let time: TimeOfDay

    public init(date: CalendarDate, time: TimeOfDay = .midnight) {
        self.date = date
        self.time = time
    }

    public static let min = LocalDateTime(date: .min)
    public static let max = LocalDateTime(date: .max, time: .max)

    public static func < (lhs: LocalDateTime, rhs: LocalDateTime) -> Bool {
        (lhs.date, lhs.time) < (rhs.date, rhs.time)
    }

    /// ISO 8601: `2000-01-31T13:05:00`.
    public var description: String {
        engineText { hegel_format_datetime(nil, raw, $0) }
    }

    init(_ raw: hegel_datetime_t) {
        self.init(date: CalendarDate(raw.date), time: TimeOfDay(raw.time))
    }

    var raw: hegel_datetime_t {
        hegel_datetime_t(date: date.raw, time: time.raw)
    }
}

extension Gen where Value == CalendarDate {
    /// Dates in `range` that fall on one of `weekdays` in one of `months`.
    /// Shrinks toward 2000-01-01, or the bound nearest it, or the nearest
    /// allowed day to either.
    ///
    /// A date outside the weekdays and months is moved to the nearest one
    /// inside them rather than rejected, so narrowing them costs nothing.
    public static func calendarDate(
        in range: ClosedRange<CalendarDate> = .min ... .max,
        weekdays: Set<Weekday> = Set(Weekday.allCases),
        months: Set<Month> = Set(Month.allCases)
    ) -> Gen<CalendarDate> {
        let options = dateOptions(weekdays: weekdays, months: months)
        let failure =
            options.failure
            ?? engineCheck {
                hegel_validate_date(
                    $0,
                    range.lowerBound.raw,
                    range.upperBound.raw,
                    options.object?.raw
                )
            }
        return Gen(label: .calendarDate) { tc, printer in
            if let failure {
                throw HegelError.usage(failure)
            }
            var out = hegel_date_t()
            try tc.call {
                hegel_generate_date(
                    $0,
                    tc.raw,
                    range.lowerBound.raw,
                    range.upperBound.raw,
                    options.object?.raw,
                    &out
                )
            }
            let value = CalendarDate(out)
            printer.value(value)
            return value
        }
    }
}

/// Date options for `weekdays` and `months`: none when they allow every
/// day, so the draw takes its fast path, or the engine's reason for
/// rejecting them.
private func dateOptions(weekdays: Set<Weekday>, months: Set<Month>) -> (
    object: EngineObject?, failure: String?
) {
    if weekdays.count == Weekday.allCases.count, months.count == Month.allCases.count {
        return (nil, nil)
    }
    let weekdayMask = weekdays.reduce(UInt32(0)) { $0 | 1 << UInt32($1.rawValue - 1) }
    let monthMask = months.reduce(UInt32(0)) { $0 | 1 << UInt32($1.rawValue - 1) }
    let object = EngineObject(
        make: { hegel_date_options_new($0, $1) },
        free: { _ = hegel_date_options_free(nil, $0) },
        configure: { context, options throws(EngineError) in
            try context.call { hegel_date_options_set_weekdays($0, options, weekdayMask) }
            try context.call { hegel_date_options_set_months($0, options, monthMask) }
        }
    )
    return (object.failure == nil ? object : nil, object.failure)
}

extension Gen where Value == TimeOfDay {
    /// Times of day in `range`, each a whole number of `precision` units.
    /// Shrinks toward its lower bound.
    public static func timeOfDay(
        in range: ClosedRange<TimeOfDay> = .midnight ... .max,
        precision: Precision = .nanoseconds
    ) -> Gen<TimeOfDay> {
        let lower = range.lowerBound.raw
        let upper = range.upperBound.raw
        let failure = engineCheck { hegel_validate_time($0, lower, upper, precision.raw) }
        return Gen(label: .timeOfDay) { tc, printer in
            if let failure {
                throw HegelError.usage(failure)
            }
            var out = hegel_time_t()
            try tc.call { hegel_generate_time($0, tc.raw, lower, upper, precision.raw, &out) }
            let value = TimeOfDay(out)
            printer.value(value)
            return value
        }
    }
}

extension Gen where Value == LocalDateTime {
    /// Dates and times in `range`, the time a whole number of `precision`
    /// units. Shrinks toward 2000-01-01T00:00:00, or the bound nearest it.
    public static func localDateTime(
        in range: ClosedRange<LocalDateTime> = .min ... .max,
        precision: Precision = .nanoseconds
    ) -> Gen<LocalDateTime> {
        let lower = range.lowerBound.raw
        let upper = range.upperBound.raw
        let failure = engineCheck { hegel_validate_datetime($0, lower, upper, precision.raw) }
        return Gen(label: .localDateTime) { tc, printer in
            if let failure {
                throw HegelError.usage(failure)
            }
            var out = hegel_datetime_t()
            try tc.call {
                hegel_generate_datetime($0, tc.raw, lower, upper, precision.raw, &out)
            }
            let value = LocalDateTime(out)
            printer.value(value)
            return value
        }
    }
}

extension Gen where Value == Date {
    /// Instants in `range`, from year 1 to 9999 by default, each a whole
    /// number of `precision` units since the Unix epoch, to the nearest
    /// value a `Date` holds. Shrinks toward 2000-01-01T00:00:00Z, or the
    /// bound nearest it.
    public static func date(
        in range: ClosedRange<Date>? = nil,
        precision: Precision = .nanoseconds
    ) -> Gen<Date> {
        let dates = range ?? foundationDates
        let bounds = Timestamp(dates.lowerBound)...Timestamp(dates.upperBound)
        let failure = engineCheck {
            hegel_validate_timestamp(
                $0,
                bounds.lowerBound.raw,
                bounds.upperBound.raw,
                precision.raw
            )
        }
        return Gen(label: .date) { tc, printer in
            if let failure {
                throw HegelError.usage(failure)
            }
            // A `Date` rounds to its precision, which may cross a bound.
            let drawn = try drawTimestamp(tc, bounds, precision).date
            let value = Swift.min(Swift.max(drawn, dates.lowerBound), dates.upperBound)
            printer.value(value)
            return value
        }
    }
}

/// 0001-01-01T00:00:00Z to 9999-12-31T23:59:59.999Z, the default range of
/// `Gen.date()`: a `Date` closer to year 10000 than a millisecond rounds
/// into it.
private let foundationDates =
    Date(timeIntervalSince1970: -62_135_596_800)...Date(timeIntervalSince1970: 253_402_300_799.999)

func drawTimestamp(_ tc: TestCase, _ range: ClosedRange<Timestamp>, _ precision: Precision)
    throws -> Timestamp
{
    var out = hegel_timestamp_t()
    try tc.call {
        hegel_generate_timestamp(
            $0,
            tc.raw,
            range.lowerBound.raw,
            range.upperBound.raw,
            precision.raw,
            &out
        )
    }
    return Timestamp(out)
}

private func daysIn(month: Int, year: Int) -> Int {
    switch month {
        case 2:
            let leap =
                year.isMultiple(of: 4) && (!year.isMultiple(of: 100) || year.isMultiple(of: 400))
            return leap ? 29 : 28
        case 4, 6, 9, 11:
            return 30
        default:
            return 31
    }
}

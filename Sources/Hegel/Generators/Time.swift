import CHegel

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

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

    /// 0001-01-01.
    public static let min = CalendarDate(year: 1, month: 1, day: 1)
    /// 9999-12-31.
    public static let max = CalendarDate(year: 9999, month: 12, day: 31)

    public static func < (lhs: CalendarDate, rhs: CalendarDate) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    /// ISO 8601: `2000-01-31`.
    public var description: String {
        let year = year < 0 ? "-\(pad(-year, 4))" : pad(year, 4)
        return "\(year)-\(pad(month, 2))-\(pad(day, 2))"
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
        var text = "\(pad(hour, 2)):\(pad(minute, 2)):\(pad(second, 2))"
        if nanosecond > 0 {
            var fraction = pad(nanosecond, 9)
            while fraction.hasSuffix("0") {
                fraction.removeLast()
            }
            text += ".\(fraction)"
        }
        return text
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
    public var description: String { "\(date)T\(time)" }

    init(_ raw: hegel_datetime_t) {
        self.init(date: CalendarDate(raw.date), time: TimeOfDay(raw.time))
    }

    var raw: hegel_datetime_t {
        hegel_datetime_t(date: date.raw, time: time.raw)
    }

    /// The instant this date and time names in UTC.
    var utcInstant: Date {
        let seconds = date.daysSinceEpoch * 86_400 + time.secondsSinceMidnight
        return Date(timeIntervalSince1970: Double(seconds) + Double(time.nanosecond) / 1e9)
    }

    /// The UTC date and time of `instant`, to the nanosecond `Date` can
    /// hold.
    init(utc instant: Date) {
        let interval = instant.timeIntervalSince1970
        let seconds = interval.rounded(.down)
        let nanosecond = Swift.min(Int(((interval - seconds) * 1e9).rounded()), 999_999_999)
        let (days, secondOfDay) = Int(seconds).quotientAndRemainder(dividingBy: 86_400)
        let (dayShift, second) = secondOfDay < 0 ? (-1, secondOfDay + 86_400) : (0, secondOfDay)
        self.init(
            date: CalendarDate(daysSinceEpoch: days + dayShift),
            time: TimeOfDay(
                hour: second / 3600,
                minute: second / 60 % 60,
                second: second % 60,
                nanosecond: nanosecond
            )
        )
    }
}

extension Gen where Value == CalendarDate {
    /// Dates in `range`. Shrinks toward 2000-01-01, or the bound nearest it.
    public static func calendarDate(in range: ClosedRange<CalendarDate> = .min ... .max) -> Gen<
        CalendarDate
    > {
        Gen(label: .calendarDate) { tc, printer in
            var out = hegel_date_t()
            try tc.call {
                hegel_generate_date($0, tc.raw, range.lowerBound.raw, range.upperBound.raw, &out)
            }
            let value = CalendarDate(out)
            printer.value(value)
            return value
        }
    }
}

extension Gen where Value == TimeOfDay {
    /// Times of day in `range`. Shrinks toward its lower bound.
    public static func timeOfDay(in range: ClosedRange<TimeOfDay> = .midnight ... .max) -> Gen<
        TimeOfDay
    > {
        Gen(label: .timeOfDay) { tc, printer in
            var out = hegel_time_t()
            try tc.call {
                hegel_generate_time($0, tc.raw, range.lowerBound.raw, range.upperBound.raw, &out)
            }
            let value = TimeOfDay(out)
            printer.value(value)
            return value
        }
    }
}

extension Gen where Value == LocalDateTime {
    /// Dates and times in `range`. Shrinks toward 2000-01-01T00:00:00, or the
    /// bound nearest it.
    public static func localDateTime(
        in range: ClosedRange<LocalDateTime> = .min ... .max
    ) -> Gen<LocalDateTime> {
        Gen(label: .localDateTime) { tc, printer in
            let value = try drawDateTime(tc, range)
            printer.value(value)
            return value
        }
    }
}

extension Gen where Value == Date {
    /// Instants in `range`, from year 1 to 9999 by default. Shrinks toward
    /// 2000-01-01T00:00:00Z, or the bound nearest it.
    public static func date(in range: ClosedRange<Date>? = nil) -> Gen<Date> {
        let bounds =
            range.map { LocalDateTime(utc: $0.lowerBound)...LocalDateTime(utc: $0.upperBound) }
            ?? LocalDateTime.min...LocalDateTime.max
        return Gen(label: .date) { tc, printer in
            var value = try drawDateTime(tc, bounds).utcInstant
            // Converting the bounds rounds to the nanosecond.
            if let range {
                value = Swift.min(Swift.max(value, range.lowerBound), range.upperBound)
            }
            printer.value(value)
            return value
        }
    }
}

private func drawDateTime(_ tc: TestCase, _ range: ClosedRange<LocalDateTime>) throws
    -> LocalDateTime
{
    var out = hegel_datetime_t()
    try tc.call {
        hegel_generate_datetime($0, tc.raw, range.lowerBound.raw, range.upperBound.raw, &out)
    }
    return LocalDateTime(out)
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

/// `value` in decimal, zero-padded to `width` digits.
func pad(_ value: Int, _ width: Int) -> String {
    let digits = String(value)
    return String(repeating: "0", count: Swift.max(0, width - digits.count)) + digits
}

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

// Hegel's time values meet Foundation's at the instant: a `Date` becomes a
// `Timestamp` and back, and the calendar fields come from the timestamp's
// own arithmetic. No conversion goes through a `Calendar`, whose Gregorian
// calendar turns Julian before 1582-10-15 and has no year 0, where Hegel's
// dates stay proleptic Gregorian.

extension Timestamp {
    /// The instant `date` names, to the nanosecond. `date` must lie in
    /// years ±999999.
    public init(_ date: Date) {
        let interval = date.timeIntervalSince1970
        let seconds = interval.rounded(.down)
        let nanoseconds = Swift.min(Int(((interval - seconds) * 1e9).rounded()), 999_999_999)
        self.init(seconds: Int(seconds), nanoseconds: nanoseconds)
    }

    /// This instant as a `Date`, which holds it to within a microsecond
    /// or so near the present, and less finely far from it.
    public var date: Date {
        Date(timeIntervalSince1970: Double(seconds) + Double(nanoseconds) / 1e9)
    }
}

extension LocalDateTime {
    /// The wall-clock date and time of `date` in `timeZone`: the instant
    /// moved by the zone's offset at it, in the proleptic Gregorian
    /// calendar, so 1000-01-01 is the date ISO 8601 gives it, not the
    /// Julian date a Foundation `Calendar` would. `date`, and its time in
    /// `timeZone`, must lie in years ±999999.
    public init(_ date: Date, in timeZone: TimeZone) {
        let instant = Timestamp(date)
        let offset = timeZone.secondsFromGMT(for: date)
        self =
            Timestamp(seconds: instant.seconds + offset, nanoseconds: instant.nanoseconds).utc
    }

    /// The instant this date and time names in UTC.
    var utcInstant: Date { Timestamp(utc: self).date }

    /// The UTC date and time of `instant`, to the nanosecond `Date` can
    /// hold.
    init(utc instant: Date) {
        self = Timestamp(instant).utc
    }
}

extension TimeZone {
    /// Foundation's zone of the same tz database name as `zone`, or nil
    /// when `zone` has a name the tz database lacks (`Etc/Unknown`, an
    /// opaque zone, a name only your own zone source knows) or Foundation
    /// has no zone by that name. Foundation reads some names outside the
    /// tz database its own way, `GMT+1` an hour east where POSIX puts it
    /// west and `PST` as Los Angeles, so those give nil too. The names
    /// that give a zone are those of `ZoneSource.foundation`.
    ///
    /// The zone's rules are Foundation's, not the zone source's: a zone
    /// whose rules changed lately can differ between the two databases,
    /// and `tzdbVersion` names the bundled one. Draw against
    /// `ZoneSource.foundation` for zones that agree with Foundation.
    public init?(_ zone: Zone) {
        guard foundationZoneNames.contains(zone.name) else { return nil }
        self.init(identifier: zone.name)
    }

    /// A zone fixed at `offset`, or nil for an unknown offset and for one
    /// Foundation cannot hold, past ±18 hours.
    public init?(_ offset: UTCOffset) {
        guard let seconds = offset.seconds,
            let zone = TimeZone(secondsFromGMT: seconds),
            zone.secondsFromGMT() == seconds
        else { return nil }
        self = zone
    }
}

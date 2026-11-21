// Outside Apple platforms, `TimeZone` reads named zones, lists them and
// gives their data version only once FoundationInternationalization is
// loaded: with FoundationEssentials alone it knows fixed offsets only.
#if canImport(FoundationEssentials)
    import FoundationEssentials
    import FoundationInternationalization
#else
    import Foundation
#endif

extension ZoneSource {
    /// Foundation's own time zone database, as `TimeZone` reads it on the
    /// platform the tests run on, so that zoned datetimes drawn against it
    /// resolve as `TimeZone` and `Calendar` resolve them there.
    ///
    /// ```swift
    /// let values = Gen.zonedDateTime(zones: Zones(source: .foundation))
    /// ```
    ///
    /// - Names: every tz database name Foundation reads. Those are the
    ///   bundled database's names that `TimeZone(identifier:)` accepts,
    ///   and any name `TimeZone.knownTimeZoneIdentifiers` lists in the
    ///   Area/Location form, such as a zone newer than the bundled
    ///   database. Never a name Foundation reads its own way: `GMT+1`, an
    ///   hour east where POSIX puts it west, or `PST`. A name keeps the
    ///   rank, tags and link the bundled database gives it, so
    ///   `Asia/Calcutta` is a link to `Asia/Kolkata`.
    /// - Data: read from Foundation the first time a draw or query needs
    ///   a name. The offsets and daylight saving flags hold from
    ///   Foundation's first transition through 2200. After 2200, the
    ///   source applies the yearly rule inferred from the years before,
    ///   as Foundation applies each zone's last rule for ever.
    ///   Abbreviations are what Foundation gives at each transition. They
    ///   differ between platforms (`EST` on Apple platforms, `GMT-5` on
    ///   Linux) and are informational only.
    /// - Version: `TimeZone.timeZoneDataVersion`, such as `"2026a"`, or
    ///   an empty string when Foundation gives none.
    public static let foundation: ZoneSource = {
        let names = foundationZoneNames
        let version = TimeZone.timeZoneDataVersion
        // The engine refuses only an empty name, a NUL byte and
        // `Etc/Unknown`, which no name here has, and a version that is
        // not UTF-8, so making the source fails only if allocation does.
        return try! ZoneSource(
            version: version.isEmpty ? nil : version,
            loader: { name, zones in
                guard names.contains(name), let timeZone = TimeZone(identifier: name) else {
                    return
                }
                try zones.addOracle(named: name, oracle: Zone.Oracle(timeZone))
            },
            build: { zones in try zones.declare(names.sorted()) }
        )
    }()
}

/// The tz database names Foundation reads: those of the bundled database,
/// and those it lists in the Area/Location form that every zone the tz
/// database adds takes. A name it lists without a slash may be an
/// abbreviation or an ICU ID it reads its own way, such as `PST`, rather
/// than a tz name.
let foundationZoneNames: Set<String> = {
    let listed = TimeZone.knownTimeZoneIdentifiers.filter { $0.contains("/") }
    return Set(ZoneSource.bundled.names + listed)
        .subtracting([Zone.unknownName])
        .filter { TimeZone(identifier: $0) != nil }
}()

extension Zone.Oracle {
    /// The years a Foundation zone is probed over. From the first year of
    /// the range the probe jumps to Foundation's first transition, in 1844
    /// at the earliest. The tz database's irregular predictions end by
    /// 2087 (Morocco's Ramadan changes; Palestine's end in 2086), and from
    /// then on Foundation applies each zone's last rule, so probing to
    /// 2200 gives the inference more than the 28 years of that rule it
    /// reads.
    static let foundationYears = CalendarDate.min.year...2200

    /// An oracle that asks `timeZone` for each transition in turn, then
    /// infers its yearly rule.
    init(_ timeZone: TimeZone) {
        self.init(
            years: Self.foundationYears,
            after: .infer,
            nextTransition: { after in
                let date = Date(timeIntervalSince1970: Double(after))
                return timeZone.nextDaylightSavingTimeTransition(after: date).map {
                    Int($0.timeIntervalSince1970.rounded(.up))
                }
            },
            offset: { instant in
                let date = Date(timeIntervalSince1970: Double(instant))
                let offset = timeZone.secondsFromGMT(for: date)
                return Zone.LocalTimeType(
                    offset: offset,
                    isDST: timeZone.isDaylightSavingTime(for: date),
                    abbreviation: timeZone.abbreviation(for: date)
                        ?? UTCOffset.known(seconds: offset).description
                )
            }
        )
    }
}

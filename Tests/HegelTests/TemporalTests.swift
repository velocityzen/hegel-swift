import Foundation
import Synchronization
import Testing

@testable import Hegel

/// Nanoseconds in one unit of each precision.
private let nanosecondsPerUnit: [Precision: Int128] = [
    .nanoseconds: 1,
    .microseconds: 1_000,
    .milliseconds: 1_000_000,
    .seconds: 1_000_000_000,
    .minutes: 60_000_000_000,
    .hours: 3_600_000_000_000,
]

private func nanoseconds(_ time: TimeOfDay) -> Int128 {
    Int128(time.secondsSinceMidnight) * 1_000_000_000 + Int128(time.nanosecond)
}

private func nanoseconds(_ timestamp: Timestamp) -> Int128 {
    Int128(timestamp.seconds) * 1_000_000_000 + Int128(timestamp.nanoseconds)
}

/// Two values from `generator`, as the bounds of a range.
private func bounds<Value: Comparable>(_ tc: TestCase, _ generator: Gen<Value>) throws
    -> ClosedRange<Value>
{
    let first = try tc.draw(generator)
    let second = try tc.draw(generator)
    return min(first, second)...max(first, second)
}

/// The message of the usage error `body` threw, if it threw one.
private func usageError(_ body: () throws -> Void) -> String? {
    do {
        try body()
        return nil
    } catch HegelError.usage(let message) {
        return message
    } catch {
        return "unexpected \(error)"
    }
}

/// `timestamp` moved by `seconds`.
private func shifted(_ timestamp: Timestamp, by seconds: Int) -> Timestamp {
    Timestamp(seconds: timestamp.seconds + seconds, nanoseconds: timestamp.nanoseconds)
}

/// More test cases, for draws that only reach a transition now and then.
private let thorough = isolated.merging(Settings(testCases: 2000))

@Suite("Temporal values")
struct TemporalValueTests {
    @Test("every precision draws whole units within drawn bounds")
    func precisions() throws {
        try Property.check(settings: isolated) { tc in
            let precision = try tc.draw(.element(of: Precision.allCases), named: "precision")
            let unit = try #require(nanosecondsPerUnit[precision])

            let times = try bounds(tc, .timeOfDay(precision: precision))
            let time = try tc.draw(.timeOfDay(in: times, precision: precision))
            #expect(times.contains(time))
            #expect(nanoseconds(time) % unit == 0)

            let dateTimes = try bounds(tc, .localDateTime(precision: precision))
            let dateTime = try tc.draw(.localDateTime(in: dateTimes, precision: precision))
            #expect(dateTimes.contains(dateTime))
            #expect(nanoseconds(dateTime.time) % unit == 0)

            let timestamps = try bounds(tc, .timestamp(precision: precision))
            let timestamp = try tc.draw(.timestamp(in: timestamps, precision: precision))
            #expect(timestamps.contains(timestamp))
            #expect(nanoseconds(timestamp) % unit == 0)

            let durations = try bounds(tc, .duration(precision: precision))
            let duration = try tc.draw(.duration(in: durations, precision: precision))
            #expect(durations.contains(duration))
            #expect(duration.attoseconds % (unit * 1_000_000_000) == 0)
        }
    }

    @Test("bounds holding no value at the precision are a usage error")
    func emptyAtPrecision() {
        let tenth = TimeOfDay(hour: 0, nanosecond: 100_000_000)
        let fifth = TimeOfDay(hour: 0, nanosecond: 200_000_000)
        let message = usageError {
            try Property.check(settings: isolated) { tc in
                _ = try tc.draw(.timeOfDay(in: tenth...fifth, precision: .seconds))
            }
        }
        #expect(message != nil)
        let subNanosecond = usageError {
            try Property.check(settings: isolated) { tc in
                let range = Duration(attoseconds: 200)...Duration(attoseconds: 800)
                _ = try tc.draw(.duration(in: range))
            }
        }
        #expect(subNanosecond != nil)
    }

    @Test("dates fall on the weekdays and in the months asked for")
    func weekdaysAndMonths() throws {
        let lastWindowStart = CalendarDate(daysSinceEpoch: CalendarDate.max.daysSinceEpoch - 366)
        try Property.check(settings: isolated) { tc in
            let weekdays = try tc.draw(.set(of: .element(of: Weekday.allCases), count: 1...7))
            let months = try tc.draw(.set(of: .element(of: Month.allCases), count: 1...12))
            var range = CalendarDate.min...CalendarDate.max
            if try tc.draw(.bool()) {
                // Every weekday of every month falls in any 367 days.
                let start = try tc.draw(.calendarDate(in: .min...lastWindowStart))
                range = start...CalendarDate(daysSinceEpoch: start.daysSinceEpoch + 366)
            }
            let date = try tc.draw(.calendarDate(in: range, weekdays: weekdays, months: months))
            #expect(range.contains(date))
            #expect(weekdays.contains(date.weekday))
            #expect(months.contains(Month(rawValue: date.month)!))
        }
    }

    @Test("no weekday or no month is a usage error")
    func emptyWeekdays() {
        let noWeekday = usageError {
            try Property.check(settings: isolated) { tc in
                _ = try tc.draw(.calendarDate(weekdays: []))
            }
        }
        #expect(noWeekday?.contains("weekday") == true)
        let noMonth = usageError {
            try Property.check(settings: isolated) { tc in
                _ = try tc.draw(.calendarDate(months: []))
            }
        }
        #expect(noMonth?.contains("month") == true)
    }

    @Test("weekdays follow one another, and 2000-01-01 was a Saturday")
    func weekdays() throws {
        #expect(CalendarDate(year: 2000, month: 1, day: 1).weekday == .saturday)
        #expect(CalendarDate(year: 1970, month: 1, day: 1).weekday == .thursday)
        try Property.check(settings: isolated) { tc in
            let date = try tc.draw(
                .calendarDate(in: .min...CalendarDate(year: 999_999, month: 12, day: 30))
            )
            let next = CalendarDate(daysSinceEpoch: date.daysSinceEpoch + 1)
            #expect(next.weekday.rawValue == date.weekday.rawValue % 7 + 1)
        }
    }

    @Test("timestamps round-trip through their UTC date and time")
    func timestampsThroughUTC() throws {
        try Property.check(settings: isolated) { tc in
            let first = try tc.draw(.timestamp())
            let second = try tc.draw(.timestamp())
            #expect(Timestamp(utc: first.utc) == first)
            #expect((first < second) == (first.utc < second.utc))
        }
    }

    @Test("Foundation dates are whole units at a precision of seconds or coarser")
    func foundationPrecision() throws {
        try Property.check(settings: isolated) { tc in
            let precision = try tc.draw(.element(of: Precision.allCases))
            let date = try tc.draw(.date(precision: precision))
            #expect((1...9999).contains(Timestamp(date).utc.date.year))
            let unit = try #require(nanosecondsPerUnit[precision])
            if unit >= 1_000_000_000 {
                let seconds = date.timeIntervalSince1970
                #expect(seconds.truncatingRemainder(dividingBy: Double(unit / 1_000_000_000)) == 0)
            }
        }
    }

    @Test("offsets stay in bounds at their granularity, unknown only when allowed")
    func offsets() throws {
        let secondsPerUnit: [UTCOffset.Granularity: Int] = [
            .hours: 3600, .quarterHours: 900, .minutes: 60, .seconds: 1,
        ]
        try Property.check(settings: isolated) { tc in
            let granularity = try tc.draw(.element(of: UTCOffset.Granularity.allCases))
            let unit = try #require(secondsPerUnit[granularity])
            let first = try #require(try tc.draw(.utcOffset(granularity: granularity)).seconds)
            let second = try #require(try tc.draw(.utcOffset(granularity: granularity)).seconds)
            let range = min(first, second)...max(first, second)
            let allowUnknown = try tc.draw(.bool())
            let offset = try tc.draw(
                .utcOffset(in: range, granularity: granularity, allowUnknown: allowUnknown)
            )
            if let seconds = offset.seconds {
                #expect(range.contains(seconds))
                #expect(seconds % unit == 0)
            } else {
                #expect(allowUnknown)
            }
        }
    }

    @Test("durations stay within bounds finer than a nanosecond")
    func durationBounds() throws {
        let lowest = (Int128(Int64.min) * 1_000_000_000 - 999_999_999) * 1_000_000_000
        let highest = (Int128(Int64.max) * 1_000_000_000 + 999_999_999) * 1_000_000_000
        let nanosecond: Int128 = 1_000_000_000
        try Property.check(settings: isolated) { tc in
            let start = try tc.draw(Gen<Int128>.integer(in: lowest...(highest - nanosecond)))
            let length = try tc.draw(Gen<Int128>.integer(in: nanosecond...(highest - start)))
            let range = Duration(attoseconds: start)...Duration(attoseconds: start + length)
            let duration = try tc.draw(.duration(in: range))
            #expect(range.contains(duration))
        }
    }

    @Test("spans keep each unit in its bounds and sign the units as asked")
    func spans() throws {
        try Property.check(settings: isolated) { tc in
            let sign = try tc.draw(.element(of: CalendarSpan.Sign.allCases))
            var units: [CalendarSpan.Unit: ClosedRange<Int>] = [:]
            for unit in CalendarSpan.Unit.allCases where try tc.draw(.bool()) {
                units[unit] = try bounds(tc, .int())
            }
            let ranges = units.values
            let signs: Bool =
                switch sign {
                    case .mixed: true
                    case .nonnegative: ranges.allSatisfy { $0.lowerBound >= 0 }
                    case .uniform:
                        ranges.allSatisfy { $0.upperBound >= 0 }
                            || ranges.allSatisfy { $0.lowerBound <= 0 }
                }
            let valid = !units.isEmpty && signs
            let generator = Gen.calendarSpan(units, sign: sign)
            guard valid else {
                #expect(usageError { _ = try tc.draw(generator) } != nil)
                return
            }
            let span = try tc.draw(generator)
            for unit in CalendarSpan.Unit.allCases {
                if let range = units[unit] {
                    #expect(range.contains(span[unit]))
                } else {
                    #expect(span[unit] == 0)
                }
            }
            let values = CalendarSpan.Unit.allCases.map { span[$0] }
            switch sign {
                case .mixed: break
                case .nonnegative: #expect(values.allSatisfy { $0 >= 0 })
                case .uniform:
                    #expect(values.allSatisfy { $0 >= 0 } || values.allSatisfy { $0 <= 0 })
            }
        }
    }

    @Test("spans of every unit by default")
    func defaultSpans() throws {
        try Property.check(settings: isolated) { tc in
            let span = try tc.draw(.calendarSpan())
            let values = CalendarSpan.Unit.allCases.map { span[$0] }
            #expect(values.allSatisfy { $0 >= 0 } || values.allSatisfy { $0 <= 0 })
            let magnitudes = try tc.draw(.calendarSpan(sign: .nonnegative))
            #expect(CalendarSpan.Unit.allCases.allSatisfy { magnitudes[$0] >= 0 })
        }
    }

    @Test("values print as every Hegel frontend prints them")
    func canonicalText() {
        #expect(CalendarDate(year: 2024, month: 3, day: 10).description == "2024-03-10")
        #expect(CalendarDate(year: 10_000, month: 1, day: 1).description == "+010000-01-01")
        #expect(CalendarDate(year: -1, month: .december, day: 31).description == "-000001-12-31")
        #expect(TimeOfDay(hour: 2, minute: 30).description == "02:30:00")
        #expect(TimeOfDay(hour: 2, minute: 30, nanosecond: 500_000_000).description == "02:30:00.5")
        #expect(Timestamp(seconds: 946_684_800).description == "2000-01-01T00:00:00Z")
        #expect(
            Timestamp(seconds: -2, nanoseconds: 500_000_000).description
                == "1969-12-31T23:59:58.5Z"
        )
        #expect(UTCOffset.known(seconds: 19_800).description == "+05:30")
        #expect(UTCOffset.known(seconds: -2670).description == "-00:44:30")
        #expect(UTCOffset.utc.description == "+00:00")
        #expect(UTCOffset.unknown.description == "-00:00")
        #expect(CalendarSpan(years: 1, months: 2, days: 3).description == "1y 2mo 3d")
        #expect(CalendarSpan(days: -3, hours: -4).description == "-3d 4h")
        #expect(CalendarSpan(days: -3, hours: 4).description == "-3d +4h")
        #expect(CalendarSpan(years: 1, months: -2).description == "+1y -2mo")
        #expect(CalendarSpan(microseconds: 5).description == "5µs")
        #expect(CalendarSpan().description == "0s")
    }
}

@Suite("Time zones")
struct ZoneTests {
    static let bundledNames = ZoneSource.bundled.names

    @Test("zone draws honor the link, legacy and unknown flags")
    func flags() throws {
        let names = Set(Self.bundledNames)
        try Property.check(settings: isolated) { tc in
            let links = try tc.draw(.bool())
            let legacy = try tc.draw(.bool())
            let unknown = try tc.draw(.bool())
            let zone = try tc.draw(
                .zone(from: Zones(links: links, legacy: legacy, unknown: unknown))
            )
            if zone.name == Zone.unknownName {
                #expect(unknown)
                return
            }
            #expect(names.contains(zone.name))
            let info = try #require(try ZoneSource.bundled.info(for: zone.name))
            #expect(zone.primaryName == info.primaryName)
            #expect(links || !info.isLink)
            #expect(legacy || !info.tags.contains(.legacy))
        }
    }

    @Test("an explicit list of names is drawn from, flags aside")
    func explicitNames() throws {
        try Property.check(settings: isolated) { tc in
            let names = try tc.draw(.set(of: .element(of: Self.bundledNames), count: 1...20))
            let zone = try tc.draw(.zone(from: Zones(names: Array(names), links: false)))
            #expect(names.contains(zone.name))
        }
    }

    @Test("opaque names are drawn only when accepted, and read as UTC")
    func opaqueNames() throws {
        try Property.check(settings: isolated) { tc in
            let names = try tc.draw(.set(of: .element(of: Self.bundledNames), count: 0...5))
            let zones = Zones(names: Array(names) + ["Mars/Base"], opaque: true)
            let value = try tc.draw(.zonedDateTime(zones: zones))
            if value.zone.name == "Mars/Base" {
                #expect(value.zone.primaryName == "Mars/Base")
                #expect(value.offset == .unknown)
                #expect(value.timestamp == Timestamp(utc: value.civil))
            } else {
                #expect(names.contains(value.zone.name))
            }
        }
        let refused = usageError {
            try Property.check(settings: isolated) { tc in
                _ = try tc.draw(.zone(from: Zones(names: ["UTC", "Mars/Base"])))
            }
        }
        #expect(refused?.contains("Mars/Base") == true)
    }

    @Test("zones shrink to UTC")
    func shrinksToUTC() throws {
        let drawn = try minimalExample { tc in
            _ = try tc.draw(.zone(), named: "zone")
            throw Failed()
        }
        #expect(drawn == ["let zone = UTC"])
    }
}

@Suite("Zoned datetimes")
struct ZonedDateTimeTests {
    /// Checks that `value` is what the default source says of its wall
    /// time, and that its instant follows from its offsets.
    private func checkResolved(_ value: ZonedDateTime) throws {
        let source = ZoneSource.default
        let resolved = try source.resolve(value.civil, in: value.zone.name)
        #expect(resolved.kind == value.kind)
        #expect(resolved.offsetBefore == value.offsetBefore)
        #expect(resolved.offsetAfter == value.offsetAfter)
        #expect(value.fold == false || value.kind == .fold)
        let wallClock = Timestamp(utc: value.civil)
        switch (value.offsetBefore.seconds, value.offsetAfter.seconds) {
            case let (before?, after?):
                if value.fold {
                    #expect(value.timestamp == shifted(resolved.timestamp, by: before - after))
                } else {
                    #expect(value.timestamp == resolved.timestamp)
                }
                let offset = value.kind == .gap ? before : value.fold ? after : before
                #expect(value.timestamp == shifted(wallClock, by: -offset))
            default:
                #expect(value.offset == .unknown)
                #expect(value.timestamp == wallClock)
        }
        #expect(try source.offset(in: value.zone.name, at: value.timestamp).offset == value.offset)
    }

    @Test("drawn values agree with the zone source and with their options")
    func agreeWithQueries() throws {
        try Property.check(settings: isolated) { tc in
            let precision = try tc.draw(.element(of: Precision.allCases))
            let allowImaginary = try tc.draw(.bool())
            let ambiguous = try tc.draw(.element(of: ZonedDateTime.Ambiguous.allCases))
            let unknown = try tc.draw(.bool())
            let value = try tc.draw(
                .zonedDateTime(
                    zones: Zones(unknown: unknown),
                    precision: precision,
                    allowImaginary: allowImaginary,
                    ambiguous: ambiguous
                ),
                named: "value"
            )
            try checkResolved(value)
            #expect(nanoseconds(value.civil.time) % nanosecondsPerUnit[precision]! == 0)
            #expect(allowImaginary || value.kind != .gap)
            switch ambiguous {
                case .both: break
                case .earlier: #expect(!value.fold)
                case .later: #expect(value.fold == (value.kind == .fold))
            }
        }
    }

    @Test("wall-clock and instant bounds hold")
    func bounded() throws {
        try Property.check(settings: isolated) { tc in
            let precision = try tc.draw(.element(of: Precision.allCases))
            if try tc.draw(.bool()) {
                let range = try bounds(tc, .localDateTime(precision: precision))
                let value = try tc.draw(.zonedDateTime(in: .wallClock(range), precision: precision))
                #expect(range.contains(value.civil))
            } else {
                let range = try bounds(tc, .timestamp(precision: precision))
                let value = try tc.draw(.zonedDateTime(in: .instants(range), precision: precision))
                #expect(range.contains(value.timestamp))
            }
        }
    }

    @Test("a zone generator of your own picks the zone")
    func zoneGenerator() throws {
        let names = ZoneSource.bundled.names
        try Property.check(settings: isolated) { tc in
            let value = try tc.draw(.zonedDateTime(zone: .element(of: names)))
            #expect(names.contains(value.zone.name))
            try checkResolved(value)
        }
    }

    @Test("a zone the source does not know is a usage error")
    func unknownZone() {
        let message = usageError {
            try Property.check(settings: isolated) { tc in
                _ = try tc.draw(.zonedDateTime(zone: "Mars/Base"))
            }
        }
        #expect(message?.contains("Mars/Base") == true)
    }

    @Test("gaps and folds are reached, and folds shrink to the nearest one")
    func transitions() throws {
        let outcome = try Property.run(settings: thorough) { tc in
            let value = try tc.draw(.zonedDateTime(zone: "America/New_York"))
            if value.kind == .gap {
                throw Failed()
            }
        }
        #expect(outcome.failure != nil)
        let outcomeFold = try Property.run(settings: thorough) { tc in
            let value = try tc.draw(.zonedDateTime(zone: "America/New_York"), named: "z")
            if value.fold {
                throw Failed()
            }
        }
        #expect(
            try #require(outcomeFold.failure).counterexamples[0].drawn
                == ["let z = 1999-10-31T01:00:00-05:00[America/New_York][fold=1]"]
        )
    }

    @Test("resolved wall times print as RFC 9557")
    func canonicalText() throws {
        let source = ZoneSource.bundled
        func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> LocalDateTime
        {
            LocalDateTime(
                date: CalendarDate(year: year, month: month, day: day),
                time: TimeOfDay(hour: hour, minute: minute)
            )
        }
        #expect(
            try source.resolve(at(2024, 3, 10, 1, 30), in: "America/New_York").description
                == "2024-03-10T01:30:00-05:00[America/New_York]"
        )
        #expect(
            try source.resolve(at(2024, 3, 10, 2, 30), in: "America/New_York").description
                == "2024-03-10T02:30:00-04:00[America/New_York][gap]"
        )
        #expect(
            try source.resolve(at(2024, 11, 3, 1, 30), in: "America/New_York").description
                == "2024-11-03T01:30:00-04:00[America/New_York][fold=0]"
        )
        #expect(
            try source.resolve(at(2000, 1, 1, 0, 0), in: Zone.unknownName).description
                == "2000-01-01T00:00:00Z[Etc/Unknown]"
        )
    }
}

@Suite("Zone sources")
struct ZoneSourceTests {
    static let eastern = Zone.LocalTimeType(offset: -18_000, abbreviation: "EST")
    static let easternDaylight = Zone.LocalTimeType(
        offset: -14_400,
        isDST: true,
        abbreviation: "EDT"
    )

    @Test("the bundled source lists its names in byte order and knows each one")
    func bundledNames() throws {
        let source = ZoneSource.bundled
        let names = source.names
        #expect(names == names.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) })
        #expect(names.contains("UTC") && names.contains("America/New_York"))
        for name in names {
            let info = try #require(try source.info(for: name))
            #expect(info.isLink == info.tags.contains(.link))
        }
        #expect(try source.info(for: "Mars/Base") == nil)
        #expect(try source.info(for: "UTC")?.rank == 0)
        #expect(!tzdbVersion.isEmpty)
        #expect(source.version == tzdbVersion)
    }

    @Test("a fixed zone given as fields")
    func fixedZone() throws {
        let noNUL = Alphabet(excludedCharacters: "\u{0}")
        try Property.check(settings: isolated) { tc in
            let name = try tc.draw(.string(of: noNUL, count: 1...20))
            try tc.assume(name != Zone.unknownName)
            let type = Zone.LocalTimeType(
                offset: try tc.draw(.int(in: -172_799...172_799)),
                isDST: try tc.draw(.bool()),
                abbreviation: try tc.draw(.string(of: noNUL, count: 1...10))
            )
            let source = try ZoneSource { zones in
                try zones.addZone(named: name, data: Zone.Data(initial: type))
            }
            #expect(source.names == [name])
            let timestamp = try tc.draw(.timestamp())
            let offset = try source.offset(in: name, at: timestamp)
            #expect(offset.offset == .known(seconds: type.offset))
            #expect(offset.abbreviation == type.abbreviation)
            #expect(offset.isDST == type.isDST)

            let civil = try tc.draw(.localDateTime())
            let instant = Timestamp(utc: civil).seconds - type.offset
            if (Timestamp.min.seconds...Timestamp.max.seconds).contains(instant) {
                let resolved = try source.resolve(civil, in: name)
                #expect(resolved.kind == .unique)
                #expect(resolved.timestamp.seconds == instant)
            } else {
                #expect(throws: HegelError.self) { try source.resolve(civil, in: name) }
            }

            let zone = try tc.draw(.zone(from: Zones(source: source)))
            #expect(zone.name == name)
            let value = try tc.draw(.zonedDateTime(zones: Zones(source: source)))
            #expect(value.offset == .known(seconds: type.offset))
        }
    }

    @Test("a yearly rule matches the bundled zone it copies")
    func yearlyRule() throws {
        let rule = Zone.Rule(
            standard: Self.eastern,
            daylight: .init(
                localTimeType: Self.easternDaylight,
                start: .init(day: .weekday(.sunday, week: 2, month: .march)),
                end: .init(day: .weekday(.sunday, week: 1, month: .november))
            )
        )
        let source = try ZoneSource { zones in
            try zones.addZone(
                named: "Rule/Eastern",
                data: Zone.Data(initial: Self.eastern, after: .rule(rule))
            )
        }
        // America/New_York has followed this rule since 2007.
        let since = Timestamp(utc: LocalDateTime(date: CalendarDate(year: 2007, month: 1, day: 1)))
        try Property.check(settings: isolated) { tc in
            let timestamp = try tc.draw(.timestamp(in: since...Timestamp.max))
            let copied = try source.offset(in: "Rule/Eastern", at: timestamp)
            let bundled = try ZoneSource.bundled.offset(in: "America/New_York", at: timestamp)
            #expect(copied == bundled)
        }
    }

    @Test(
        "TZif files from the system database match the bundled zones",
        .enabled(if: FileManager.default.fileExists(atPath: "/usr/share/zoneinfo/Europe/Paris"))
    )
    func tzif() throws {
        let bytes = try [UInt8](
            Data(contentsOf: URL(fileURLWithPath: "/usr/share/zoneinfo/Europe/Paris"))
        )
        let source = try ZoneSource { zones in
            try zones.addTZif(named: "Europe/Paris", bytes: bytes)
        }
        try Property.check(settings: isolated) { tc in
            let timestamp = try tc.draw(.timestamp())
            let system = try source.offset(in: "Europe/Paris", at: timestamp)
            let bundled = try ZoneSource.bundled.offset(in: "Europe/Paris", at: timestamp)
            #expect(system.offset == bundled.offset)
        }
        #expect(throws: HegelError.self) {
            try ZoneSource { zones in try zones.addTZif(named: "Bad/Zone", bytes: [1, 2, 3]) }
        }
    }

    @Test("an oracle sampled once a day matches the zone it asks")
    func sampledOracle() throws {
        let bundled = ZoneSource.bundled
        let oracle = Zone.Oracle(years: 2000...2030, after: .infer) { instant in
            let offset = try bundled.offset(in: "America/New_York", at: Timestamp(seconds: instant))
            return Zone.LocalTimeType(
                offset: offset.offset.seconds ?? 0,
                isDST: offset.isDST,
                abbreviation: offset.abbreviation
            )
        }
        let source = try ZoneSource { zones in
            try zones.addOracle(named: "Oracle/Eastern", oracle: oracle)
        }
        let since = Timestamp(utc: LocalDateTime(date: CalendarDate(year: 2000, month: 1, day: 1)))
        try Property.check(settings: isolated) { tc in
            let timestamp = try tc.draw(.timestamp(in: since...Timestamp.max))
            let probed = try source.offset(in: "Oracle/Eastern", at: timestamp)
            let asked = try bundled.offset(in: "America/New_York", at: timestamp)
            #expect(probed == asked)
        }
    }

    @Test("an oracle that reports its transitions holds its types beyond the years probed")
    func transitionOracle() throws {
        let transitions = [0, 1_000_000, 2_000_000, 30_000_000]
        let types = (0...transitions.count).map { index in
            Zone.LocalTimeType(offset: 3600 * (index % 2 + 1), abbreviation: "T\(index)")
        }
        func type(at instant: Int) -> Zone.LocalTimeType {
            types[transitions.lastIndex { $0 <= instant }.map { $0 + 1 } ?? 0]
        }
        let oracle = Zone.Oracle(
            years: 1969...1971,
            nextTransition: { after in transitions.first { $0 > after } },
            offset: { type(at: $0) }
        )
        let source = try ZoneSource { zones in
            try zones.addOracle(named: "Oracle/Steps", oracle: oracle)
        }
        try Property.check(settings: isolated) { tc in
            let timestamp = try tc.draw(.timestamp())
            let offset = try source.offset(in: "Oracle/Steps", at: timestamp)
            let expected = type(at: timestamp.seconds)
            #expect(offset.offset == .known(seconds: expected.offset))
            #expect(offset.abbreviation == expected.abbreviation)
        }
        struct Refused: Error, CustomStringConvertible {
            var description: String { "the oracle refused" }
        }
        let failing = Zone.Oracle(years: 2000...2001) { _ in throw Refused() }
        let message = usageError {
            _ = try ZoneSource { zones in
                try zones.addOracle(named: "Oracle/Broken", oracle: failing)
            }
        }
        #expect(message?.contains("the oracle refused") == true)
    }

    @Test("a loader supplies the declared names on demand")
    func loader() throws {
        final class Loads: Sendable {
            let names = Mutex<Set<String>>([])
        }
        let declared = (0...23).map { "Fixed/\($0)" }
        let loaded = Loads()
        let source = try ZoneSource(
            loader: { name, zones in
                loaded.names.withLock { _ = $0.insert(name) }
                if name == "Fixed/Broken" {
                    throw HegelError.usage("no data for Fixed/Broken")
                }
                guard let hours = Int(name.dropFirst("Fixed/".count)) else {
                    return
                }
                let type = Zone.LocalTimeType(offset: hours * 3600, abbreviation: "F\(hours)")
                try zones.addZone(named: name, data: Zone.Data(initial: type))
            },
            build: { zones in try zones.declare(declared + ["Fixed/Broken"]) }
        )
        #expect(Set(source.names) == Set(declared + ["Fixed/Broken"]))
        try Property.check(settings: isolated) { tc in
            let name = try tc.draw(.element(of: declared))
            let timestamp = try tc.draw(.timestamp())
            let hours = Int(name.dropFirst("Fixed/".count))!
            #expect(
                try source.offset(in: name, at: timestamp).offset == .known(seconds: hours * 3600)
            )
            #expect(loaded.names.withLock { $0.contains(name) })
        }
        #expect(try source.info(for: "Elsewhere/Unknown") == nil)
        let message = usageError {
            _ = try source.offset(in: "Fixed/Broken", at: Timestamp(seconds: 0))
        }
        #expect(message?.contains("no data for Fixed/Broken") == true)
    }

    @Test("a loader is released with its source")
    func loaderRelease() throws {
        final class Flag: Sendable {
            let isSet = Atomic(false)
        }
        final class Token: Sendable {
            let released: Flag
            init(_ released: Flag) { self.released = released }
            deinit { released.isSet.store(true, ordering: .sequentiallyConsistent) }
        }
        let released = Flag()
        do {
            let token = Token(released)
            let source = try ZoneSource(loader: { _, _ in withExtendedLifetime(token) {} }) { _ in }
            let releasedEarly = released.isSet.load(ordering: .sequentiallyConsistent)
            #expect(!releasedEarly)
            withExtendedLifetime(source) {}
        }
        let releasedLate = released.isSet.load(ordering: .sequentiallyConsistent)
        #expect(releasedLate)
    }

    @Test("a source records its version")
    func version() throws {
        #expect(try ZoneSource(version: "2099z") { _ in }.version == "2099z")
        #expect(try ZoneSource { _ in }.version == "")
    }

    @Test("the default source is the bundled one until replaced")
    func defaultSource() {
        // Replacing the default would change it for tests running alongside.
        #expect(ZoneSource.setDefault(.bundled) == .bundled)
        #expect(ZoneSource.default == .bundled)
    }

    @Test("bad zone data is rejected with the engine's reason")
    func badData() throws {
        let empty = usageError {
            _ = try ZoneSource { zones in
                try zones.addZone(named: "", data: Zone.Data(initial: ZoneSourceTests.eastern))
            }
        }
        #expect(empty?.contains("cannot name a zone") == true)
        let selfLink = usageError {
            _ = try ZoneSource { zones in try zones.addLink(named: "Loop/Zone", to: "Loop/Zone") }
        }
        #expect(selfLink != nil)
        #expect(throws: HegelError.self) { try ZoneSource.bundled.zone(named: "Mars/Base") }
        #expect(try ZoneSource.bundled.zone(named: "Asia/Calcutta").primaryName == "Asia/Kolkata")
    }
}

@Suite("Foundation bridges")
struct FoundationBridgeTests {
    /// Foundation zones: those Hegel's zones name, legacy names included,
    /// and every offset Foundation holds.
    static let timeZones: Gen<TimeZone> = .oneOf(
        Gen<Zone>.zone(from: Zones(legacy: true))
            .filter { TimeZone($0) != nil }
            .map { TimeZone($0)! },
        Gen<UTCOffset>.utcOffset(in: -64_800...64_800).map { TimeZone($0)! }
    )

    @Test("a date's wall-clock time is its instant moved by the zone's offset")
    func wallClockTimes() throws {
        try Property.check(settings: isolated) { tc in
            let date = try tc.draw(.date())
            let timeZone = try tc.draw(Self.timeZones)
            let local = LocalDateTime(date, in: timeZone)
            let offset = timeZone.secondsFromGMT(for: date)
            #expect(Timestamp(utc: local) == shifted(Timestamp(date), by: offset))
        }
    }

    @Test("wall-clock times agree with Foundation's calendar from 1583 on")
    func gregorianCalendar() throws {
        let calendar = Calendar(identifier: .gregorian)
        try Property.check(settings: isolated) { tc in
            // Whole milliseconds keep a `Date` clear of a second's edge,
            // where Foundation and Hegel may round apart.
            let date = try tc.draw(.date(precision: .milliseconds))
            let timeZone = try tc.draw(Self.timeZones)
            let local = LocalDateTime(date, in: timeZone)
            // Before 1582-10-15 Foundation's Gregorian calendar is Julian.
            guard local.date.year > 1582 else { return }
            let fields = calendar.dateComponents(in: timeZone, from: date)
            #expect(fields.year == local.date.year)
            #expect(fields.month == local.date.month)
            #expect(fields.day == local.date.day)
            #expect(fields.hour == local.time.hour)
            #expect(fields.minute == local.time.minute)
            #expect(fields.second == local.time.second)
        }
    }

    @Test("zones bridge by tz database name, and fixed zones keep their offset")
    func zones() throws {
        let names = Set(ZoneTests.bundledNames)
        try Property.check(settings: isolated) { tc in
            let zone = try tc.draw(.zone(from: Zones(legacy: true, unknown: true)))
            guard let timeZone = TimeZone(zone) else {
                #expect(!names.contains(zone.name) || TimeZone(identifier: zone.name) == nil)
                return
            }
            #expect(names.contains(zone.name))
            let info = try #require(try ZoneSource.bundled.info(for: zone.name))
            if info.tags.contains(.fixed) {
                let date = try tc.draw(.date())
                let offset = try ZoneSource.bundled.offset(in: zone.name, at: Timestamp(date))
                #expect(timeZone.secondsFromGMT(for: date) == offset.offset.seconds)
            }
        }
    }

    @Test("names outside the tz database bridge to no zone")
    func foreignNames() throws {
        // The tz database names Foundation reads, newer ones included.
        let names = Set(ZoneSource.foundation.names).union(ZoneTests.bundledNames)
        let foreign: Gen<String> = .oneOf(
            .string(),
            .element(of: ["GMT+1", "PST", "utc", "america/new_york", "Mars/Base"]),
            .just(Zone.unknownName)
        )
        try Property.check(settings: isolated) { tc in
            let name = try tc.draw(foreign.filter { !names.contains($0) })
            #expect(TimeZone(Zone(name: name, primaryName: name)) == nil)
        }
        // POSIX signs are inverted: Etc/GMT+1 is an hour west of UTC.
        let west = try ZoneSource.bundled.zone(named: "Etc/GMT+1")
        #expect(TimeZone(west)?.secondsFromGMT() == -3600)
    }

    @Test("offsets bridge to fixed zones within ±18 hours")
    func offsets() throws {
        try Property.check(settings: isolated) { tc in
            let offset = try tc.draw(.utcOffset(allowUnknown: true))
            let timeZone = TimeZone(offset)
            if let seconds = offset.seconds, abs(seconds) <= 64_800 {
                let date = try tc.draw(.date())
                #expect(timeZone?.secondsFromGMT(for: date) == seconds)
            } else {
                #expect(timeZone == nil)
            }
        }
    }

    @Test("dates before the Gregorian reform keep the proleptic calendar")
    func prolepticDates() {
        let date = Date(timeIntervalSince1970: -30_610_224_000)
        let local = LocalDateTime(date, in: TimeZone(UTCOffset.utc)!)
        #expect(local == LocalDateTime(date: CalendarDate(year: 1000, month: 1, day: 1)))
        let paris = TimeZone(identifier: "Europe/Paris")!
        #expect(
            LocalDateTime(date, in: paris).time.secondsSinceMidnight
                == paris.secondsFromGMT(for: date)
        )
    }
}

/// The instant `seconds` (Unix seconds) as a `Date`, exact for every
/// second of `Timestamp`'s range.
private func date(_ seconds: Int) -> Date {
    Date(timeIntervalSince1970: Double(seconds))
}

/// 506713-02-07T00:00:00Z, in Unix seconds: the end of the range
/// Foundation's calendars compute in (`Date.validCalendarRange`). They
/// read every later instant as this one.
private let calendarLimit = 15_928_153_804_800

/// The instants, ascending, at which Foundation says the clocks of
/// `timeZone` show `wall`: the wall-clock second, in Unix seconds as if
/// it were UTC. None for a skipped wall time, two for a repeated one.
private func foundationInstants(showing wall: Int, in timeZone: TimeZone) -> [Int] {
    // An instant showing `wall` lies within a day of it, as every offset
    // does, so its offset is one in force within a day of those
    // instants: one Foundation reports a transition to, or one an
    // hourly sample finds, should a report be missing.
    let window = 2 * 86_400
    var offsets = Set(
        stride(from: wall - window, through: wall + window, by: 3600).map {
            timeZone.secondsFromGMT(for: date($0))
        }
    )
    var at = date(wall - window)
    while let next = timeZone.nextDaylightSavingTimeTransition(after: at),
        next <= date(wall + window)
    {
        offsets.insert(timeZone.secondsFromGMT(for: next))
        at = next
    }
    return offsets.map { wall - $0 }
        .filter { timeZone.secondsFromGMT(for: date($0)) == wall - $0 }
        .sorted()
}

@Suite("Foundation zone source")
struct FoundationZoneSourceTests {
    static let source = ZoneSource.foundation
    static let names = source.names
    /// The years zones' histories lie in, and the end of the probe.
    static let history =
        Timestamp(
            utc: LocalDateTime(date: CalendarDate(year: 1800, month: 1, day: 1))
        )...Timestamp(utc: LocalDateTime(date: CalendarDate(year: 2300, month: 1, day: 1)))

    /// Wall-clock times in `timeZone`: any, or one near the next
    /// transition Foundation reports after it, among the wall times it
    /// skipped or repeated or the first after them.
    static func wallTimes(around timeZone: TimeZone) -> Gen<LocalDateTime> {
        Gen { tc in
            let civil = try tc.draw(
                .oneOf(.localDateTime(), Gen<Timestamp>.timestamp(in: history).map(\.utc))
            )
            let wall = Timestamp(utc: civil).seconds
            guard try tc.draw(.bool()),
                let next = timeZone.nextDaylightSavingTimeTransition(after: date(wall))
            else { return civil }
            let transition = Int(next.timeIntervalSince1970)
            let before = timeZone.secondsFromGMT(for: date(transition - 1))
            let after = timeZone.secondsFromGMT(for: next)
            let shift = try tc.draw(
                .oneOf(
                    .int(in: -86_400...86_400),
                    .int(in: min(before, after)...max(before, after))
                )
            )
            let shifted = transition + shift
            guard (Timestamp.min.seconds...Timestamp.max.seconds).contains(shifted) else {
                return civil
            }
            return Timestamp(seconds: shifted, nanoseconds: civil.time.nanosecond).utc
        }
    }

    /// Checks `value` against Foundation's reading of its zone: the
    /// instants that show its wall-clock time, its offsets, and its
    /// wall-clock time read back through `LocalDateTime(_:in:)` and, from
    /// 1583 on, through `Calendar`.
    private func checkAgainstFoundation(_ value: ZonedDateTime) throws {
        let timeZone = try #require(TimeZone(identifier: value.zone.name))
        #expect(TimeZone(value.zone) != nil)
        let wall = Timestamp(utc: value.civil).seconds
        let instants = foundationInstants(showing: wall, in: timeZone)
        let offsetsAt = instants.map { UTCOffset.known(seconds: wall - $0) }
        switch value.kind {
            case .unique:
                #expect(instants == [value.timestamp.seconds])
                #expect(offsetsAt == [value.offset])
                #expect(value.offsetBefore == value.offset && value.offsetAfter == value.offset)
            case .fold:
                #expect(instants.count == 2)
                #expect(offsetsAt == [value.offsetBefore, value.offsetAfter])
                #expect(value.timestamp.seconds == (value.fold ? instants.last : instants.first))
            case .gap:
                #expect(instants.isEmpty)
                let before = try #require(value.offsetBefore.seconds)
                let after = try #require(value.offsetAfter.seconds)
                #expect(before < after)
                // The wall time read with either offset lands on the other
                // side of the transition.
                #expect(timeZone.secondsFromGMT(for: date(wall - after)) == before)
                #expect(timeZone.secondsFromGMT(for: date(wall - before)) == after)
                #expect(value.timestamp.seconds == wall - before)
        }
        let instant = date(value.timestamp.seconds)
        let offset = try #require(value.offset.seconds)
        // Foundation's own offset moves a wall time near either end of the
        // range past it, so the reads below need the two to agree.
        try #require(offset == timeZone.secondsFromGMT(for: instant))
        // The wall-clock time Foundation shows at the value's instant: the
        // value's own, or for a gap the one the clocks jumped to.
        let shown = LocalDateTime(instant, in: timeZone)
        #expect(Timestamp(utc: shown).seconds == value.timestamp.seconds + offset)
        if value.kind != .gap {
            #expect(shown == Timestamp(seconds: wall).utc)
        }
        // Before 1582-10-15 Foundation's Gregorian calendar is Julian, and
        // it reads an instant past its range as the range's last.
        if shown.date.year > 1582 && value.timestamp.seconds < calendarLimit {
            let fields = Calendar(identifier: .gregorian).dateComponents(
                in: timeZone,
                from: instant
            )
            #expect(fields.year == shown.date.year)
            #expect(fields.month == shown.date.month)
            #expect(fields.day == shown.date.day)
            #expect(fields.hour == shown.time.hour)
            #expect(fields.minute == shown.time.minute)
            #expect(fields.second == shown.time.second)
        }
    }

    @Test("the source holds the tz names Foundation reads, at its version")
    func names() throws {
        let names = Set(Self.names)
        let bundled = Set(ZoneSource.bundled.names)
        #expect(Self.names == Self.names.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) })
        for name in names {
            #expect(TimeZone(identifier: name) != nil)
            #expect(bundled.contains(name) || name.contains("/"))
            #expect(try Self.source.info(for: name) != nil)
        }
        #expect(!names.contains(Zone.unknownName))
        for name in bundled.union(TimeZone.knownTimeZoneIdentifiers.filter { $0.contains("/") })
        where name != Zone.unknownName && TimeZone(identifier: name) != nil {
            #expect(names.contains(name))
        }
        // Names Foundation reads its own way: abbreviations, and offsets
        // signed the other way from POSIX's `Etc/GMT+1`.
        for name in ["GMT+1", "GMT+0100", "PST", "IST", "BST", "JST"] {
            #expect(TimeZone(identifier: name) != nil)
            #expect(!names.contains(name))
            #expect(try Self.source.info(for: name) == nil)
            #expect(TimeZone(Zone(name: name, primaryName: name)) == nil)
        }
        #expect(Self.source.version == TimeZone.timeZoneDataVersion)
    }

    @Test("offsets agree with Foundation at every instant, transitions included")
    func offsets() throws {
        try Property.check(settings: thorough) { tc in
            let name = try tc.draw(.element(of: Self.names), named: "name")
            let timeZone = try #require(TimeZone(identifier: name))
            var instant = try tc.draw(.oneOf(.timestamp(), .timestamp(in: Self.history))).seconds
            if try tc.draw(.bool()),
                let next = timeZone.nextDaylightSavingTimeTransition(after: date(instant))
            {
                // Either side of Foundation's next transition, which may
                // lie past the end of the range.
                let before = try tc.draw(.bool())
                instant = Int(next.timeIntervalSince1970) - (before ? 1 : 0)
                try tc.assume(instant <= Timestamp.max.seconds)
            }
            let offset = try Self.source.offset(in: name, at: Timestamp(seconds: instant))
            #expect(offset.offset == .known(seconds: timeZone.secondsFromGMT(for: date(instant))))
            #expect(offset.isDST == timeZone.isDaylightSavingTime(for: date(instant)))
        }
    }

    @Test("every zone agrees with Foundation either side of each of its transitions")
    func everyTransition() throws {
        // Past the end of the probe, the source and Foundation both apply
        // a yearly rule, a function of the year's calendar, which repeats
        // every 400 years: agreeing through one cycle past the probe,
        // they agree for ever.
        let lastYear = Zone.Oracle.foundationYears.upperBound
        let end = Timestamp(
            utc: LocalDateTime(date: CalendarDate(year: lastYear + 401, month: 1, day: 1))
        ).seconds
        for name in Self.names {
            let timeZone = try #require(TimeZone(identifier: name))
            func agrees(at instant: Int) throws -> Bool {
                let offset = try Self.source.offset(in: name, at: Timestamp(seconds: instant))
                return offset.offset == .known(seconds: timeZone.secondsFromGMT(for: date(instant)))
                    && offset.isDST == timeZone.isDaylightSavingTime(for: date(instant))
            }
            var at = date(Timestamp.min.seconds)
            #expect(try agrees(at: Timestamp.min.seconds), "\(name) at the start")
            while let next = timeZone.nextDaylightSavingTimeTransition(after: at), next < date(end)
            {
                let instant = Int(next.timeIntervalSince1970)
                #expect(
                    try agrees(at: instant - 1),
                    "\(name) before \(Timestamp(seconds: instant))"
                )
                #expect(try agrees(at: instant), "\(name) at \(Timestamp(seconds: instant))")
                at = next
            }
        }
    }

    @Test("zoned datetimes drawn against Foundation's database read back through Foundation")
    func drawn() throws {
        try Property.check(settings: thorough) { tc in
            let precision = try tc.draw(.element(of: Precision.allCases))
            let ambiguous = try tc.draw(.element(of: ZonedDateTime.Ambiguous.allCases))
            let value = try tc.draw(
                .zonedDateTime(
                    zones: Zones(names: Self.names, source: Self.source),
                    precision: precision,
                    ambiguous: ambiguous
                ),
                named: "value"
            )
            try checkAgainstFoundation(value)
        }
    }

    @Test("wall-clock times resolve as Foundation reads them, around its transitions too")
    func resolved() throws {
        let range = Timestamp.min.seconds...Timestamp.max.seconds
        try Property.check(settings: thorough, reaching: ["gap", "fold"]) { tc in
            let name = try tc.draw(.element(of: Self.names), named: "name")
            let timeZone = try #require(TimeZone(identifier: name))
            let civil = try tc.draw(Self.wallTimes(around: timeZone), named: "civil")
            let resolved: ZonedDateTime
            do {
                resolved = try Self.source.resolve(civil, in: name)
            } catch HegelError.usage {
                // Only a wall time near either end of the range, whose
                // instant lies past it, fails to resolve.
                let wall = Timestamp(utc: civil).seconds
                let instants = foundationInstants(showing: wall, in: timeZone)
                #expect(instants.first.map { !range.contains($0) } == true)
                return
            }
            try checkAgainstFoundation(resolved)
            switch resolved.kind {
                case .unique: break
                case .gap: try tc.event("gap")
                case .fold: try tc.event("fold")
            }
        }
    }
}

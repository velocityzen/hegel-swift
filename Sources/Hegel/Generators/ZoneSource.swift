import CHegel
import Synchronization

/// The IANA release of the time zone database bundled in libhegel, such as
/// `"2026e"`.
public var tzdbVersion: String {
    var version = hegel_string_t()
    hegel_tzdb_version(nil, &version)
    return String(hegelString: version)
}

/// A time zone database that zone and zoned datetime draws pick names from
/// and resolve wall-clock times against: the database bundled in libhegel,
/// or one you fill, such as the system's.
///
/// ```swift
/// let source = try ZoneSource(version: "2026a") { zones in
///     try zones.addTZif(named: "Europe/Paris", bytes: parisTZif)
///     try zones.addLink(named: "Europe/Monaco", to: "Europe/Paris")
/// }
/// let draws = Gen.zonedDateTime(zones: Zones(source: source))
/// ```
public final class ZoneSource: Hashable, @unchecked Sendable {
    let raw: OpaquePointer

    private init(raw: OpaquePointer) {
        self.raw = raw
    }

    deinit {
        hegel_zone_source_free(nil, raw)
    }

    public static func == (lhs: ZoneSource, rhs: ZoneSource) -> Bool {
        lhs === rhs
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }

    /// The database bundled in libhegel, whose release is `tzdbVersion`.
    public static let bundled: ZoneSource = {
        var out: OpaquePointer?
        hegel_zone_source_bundled(nil, &out)
        return ZoneSource(raw: out!)
    }()

    private static let current = Mutex<ZoneSource?>(nil)

    /// The process-wide default zone source: `bundled` until `setDefault`
    /// replaces it.
    ///
    /// A generator reads the default when it is built and keeps the source
    /// it read; the queries of the default read it at each call.
    public static var `default`: ZoneSource {
        current.withLock { $0 } ?? bundled
    }

    /// Makes `source` the process-wide default, for the generators built
    /// from now on, and returns the default it replaces.
    ///
    /// Tests run in parallel and share the default, so set it once, before
    /// any test runs, rather than around one test.
    @discardableResult
    public static func setDefault(_ source: ZoneSource) -> ZoneSource {
        current.withLock { current in
            hegel_set_default_zone_source(nil, source.raw)
            let previous = current ?? bundled
            current = source
            return previous
        }
    }

    /// A source filled by `build`, holding release `version` of its
    /// database.
    ///
    /// `loader`, when given, supplies the data of a name the source lacks
    /// the first time a draw or query needs it, as `build` does: declare the
    /// names in `build` and load each one on demand. It is called from
    /// whichever thread draws, possibly at once on several, must not draw,
    /// and should add nothing for a name it does not know. An error it
    /// throws fails the draw or query that needed the name as a usage
    /// error.
    public init(
        version: String? = nil,
        loader: (@Sendable (_ name: String, _ zones: Writer) throws -> Void)? = nil,
        build: (_ zones: Writer) throws -> Void
    ) throws {
        var out: OpaquePointer?
        try engineQuery { hegel_zone_source_new($0, &out) }
        raw = out!
        if let version {
            try version.withHegelString { view in
                try engineQuery { hegel_zone_source_set_version($0, raw, view) }
            }
        }
        try build(Writer(raw: raw))
        if let loader {
            let box = Unmanaged.passRetained(LoaderBox(loader)).toOpaque()
            // On failure the engine releases the box before it returns.
            try engineQuery {
                hegel_zone_source_set_loader(
                    $0,
                    raw,
                    { userData, context, source, name in
                        let box = Unmanaged<LoaderBox>.fromOpaque(userData!).takeUnretainedValue()
                        return reportingErrors(to: context) {
                            try box.load(String(hegelString: name), Writer(raw: source!))
                        }
                    },
                    box,
                    { userData in
                        Unmanaged<LoaderBox>.fromOpaque(userData!).release()
                    }
                )
            }
        }
    }

    /// The release of the source's database: the bundled release for
    /// `bundled`, what was given for a source you filled, or an empty
    /// string.
    public var version: String {
        var version = hegel_string_t()
        hegel_zone_source_version(nil, raw, &version)
        return String(hegelString: version)
    }

    /// Every name the source knows, in ascending byte order: for `bundled`
    /// every name of its database, links and legacy names included; for
    /// another every name it was given data for or had declared.
    public var names: [String] {
        var count = 0
        hegel_zone_source_name_count(nil, raw, &count)
        return (0..<count).map { index in
            var name = hegel_string_t()
            hegel_zone_source_name(nil, raw, index, &name)
            return String(hegelString: name)
        }
    }

    /// What the source knows about `name`, or nil when it does not know
    /// it. Throws when loading the name's data fails.
    public func info(for name: String) throws -> Zone.Info? {
        var info = hegel_timezone_info_t()
        try name.withHegelString { view in
            try engineQuery { hegel_timezone_info_in($0, raw, view, &info) }
        }
        return info.known ? Zone.Info(info) : nil
    }

    /// The zone `name` names, matched exactly as the source spells it.
    /// Throws when the source does not know the name or fails to load it.
    public func zone(named name: String) throws -> Zone {
        guard let info = try info(for: name) else {
            throw HegelError.usage("The zone source does not know the time zone \"\(name)\"")
        }
        return Zone(name: name, primaryName: info.primaryName)
    }

    /// The wall-clock time `civil` in the zone `zone`, classified and
    /// resolved to an instant: for a repeated wall time the earlier
    /// instant, `fold` false. Throws for a zone the source does not know or
    /// fails to load, and for a wall time whose instant lies outside the
    /// range of `Timestamp`.
    public func resolve(_ civil: LocalDateTime, in zone: String) throws -> ZonedDateTime {
        var out = hegel_timezone_resolution_t()
        try zone.withHegelString { view in
            try engineQuery { hegel_timezone_resolve_in($0, raw, view, civil.raw, &out) }
        }
        return ZonedDateTime(out, civil: civil, zone: try self.zone(named: zone))
    }

    /// The offset the zone `zone` has in force at `timestamp`. Throws for a
    /// zone the source does not know or fails to load.
    public func offset(in zone: String, at timestamp: Timestamp) throws -> Zone.Offset {
        var out = hegel_timezone_offset_t()
        try zone.withHegelString { view in
            try engineQuery { hegel_timezone_offset_at_in($0, raw, view, timestamp.raw, &out) }
        }
        return Zone.Offset(out)
    }

    /// The zone a draw reported, with the primary name the source gives
    /// it, or its own name for an opaque zone.
    func zone(drawn name: String, in tc: TestCase) throws -> Zone {
        var info = hegel_timezone_info_t()
        try name.withHegelString { view in
            try tc.call { hegel_timezone_info_in($0, raw, view, &info) }
        }
        let primaryName = info.known ? String(hegelString: info.primary_name) : name
        return Zone(name: name, primaryName: primaryName)
    }

    /// A zone source being filled, by `ZoneSource.init`'s `build` or its
    /// loader. Each method adds to the source, replacing what it had for
    /// the name, and throws the engine's reason for rejecting the data.
    ///
    /// A writer is valid only during the call it is passed to: don't keep
    /// it.
    public struct Writer {
        let raw: OpaquePointer

        /// Adds the zone `name` from a TZif file (RFC 9636, version 2 or
        /// later), such as one under `/usr/share/zoneinfo`.
        public func addTZif(named name: String, bytes: [UInt8]) throws {
            try name.withHegelString { view in
                try bytes.withUnsafeBufferPointer { buffer in
                    try engineQuery {
                        hegel_zone_source_add_tzif($0, raw, view, buffer.baseAddress, buffer.count)
                    }
                }
            }
        }

        /// Adds the zone `name` from its data given as fields.
        public func addZone(named name: String, data: Zone.Data) throws {
            let strings = StringPool()
            var raw = data.raw(strings)
            let transitions = data.transitions.map { $0.raw(strings) }
            try transitions.withUnsafeBufferPointer { buffer in
                raw.transitions = buffer.baseAddress
                raw.transition_count = buffer.count
                try name.withHegelString { view in
                    try engineQuery { hegel_zone_source_add_zone($0, self.raw, view, &raw) }
                }
            }
            withExtendedLifetime(strings) {}
        }

        /// Adds the zone `name` by probing `oracle`, which is called on
        /// this thread during this call only.
        public func addOracle(named name: String, oracle: Zone.Oracle) throws {
            let box = OracleBox(oracle)
            var raw = hegel_zone_oracle_t()
            raw.offset_at = { userData, context, instant, out in
                let box = Unmanaged<OracleBox>.fromOpaque(userData!).takeUnretainedValue()
                return reportingErrors(to: context) {
                    out!.pointee = try box.offset(at: instant)
                }
            }
            if oracle.nextTransition != nil {
                raw.next_transition = { userData, context, after, found, instant in
                    let box = Unmanaged<OracleBox>.fromOpaque(userData!).takeUnretainedValue()
                    return reportingErrors(to: context) {
                        if let next = try box.oracle.nextTransition?(Int(after)) {
                            found!.pointee = true
                            instant!.pointee = Int64(next)
                        } else {
                            found!.pointee = false
                        }
                    }
                }
            }
            raw.user_data = Unmanaged.passUnretained(box).toOpaque()
            raw.first_year = Int32(clamping: oracle.years.lowerBound)
            raw.last_year = Int32(clamping: oracle.years.upperBound)
            raw.after = oracle.after.raw
            try withExtendedLifetime(box) {
                try name.withHegelString { view in
                    try engineQuery { hegel_zone_source_add_oracle($0, self.raw, view, &raw) }
                }
            }
        }

        /// Makes `name` a link to `target`, whose data then applies to
        /// both. The target need not have data yet.
        public func addLink(named name: String, to target: String) throws {
            try name.withHegelString { name in
                try target.withHegelString { target in
                    try engineQuery { hegel_zone_source_add_link($0, raw, name, target) }
                }
            }
        }

        /// Declares names the source knows whose data comes later: from the
        /// loader the first time a draw or query needs it, or from another
        /// call of this writer. A name the source already has keeps what it
        /// has.
        public func declare(_ names: [String]) throws {
            try withHegelStrings(names) { views, count in
                try engineQuery { hegel_zone_source_declare($0, raw, views, count) }
            }
        }
    }
}

extension Zone {
    /// A local time type: an offset, its daylight saving flag and its
    /// abbreviation.
    public struct LocalTimeType: Hashable, Sendable {
        /// Seconds east of UTC, less than two days in magnitude.
        public var offset: Int
        /// Informational only: never used to classify a wall time.
        public var isDST: Bool
        /// Such as `EST`.
        public var abbreviation: String

        public init(offset: Int, isDST: Bool = false, abbreviation: String) {
            self.offset = offset
            self.isDST = isDST
            self.abbreviation = abbreviation
        }

        func raw(_ strings: StringPool) -> hegel_zone_type_t {
            hegel_zone_type_t(
                utoff: Int32(clamping: offset),
                is_dst: isDST,
                abbreviation: strings.view(abbreviation)
            )
        }
    }

    /// From `instant` (Unix seconds) on, `localTimeType` is in force.
    public struct Transition: Hashable, Sendable {
        public var instant: Int
        public var localTimeType: LocalTimeType

        public init(instant: Int, localTimeType: LocalTimeType) {
            self.instant = instant
            self.localTimeType = localTimeType
        }

        func raw(_ strings: StringPool) -> hegel_zone_transition_t {
            hegel_zone_transition_t(instant: Int64(instant), local_type: localTimeType.raw(strings))
        }
    }

    /// The day of the year a yearly rule's transition happens on, as a
    /// POSIX TZ string names it.
    public enum RuleDay: Hashable, Sendable {
        /// `Jn`: day `n` of the year in `1...365`, never counting
        /// February 29.
        case julian(Int)
        /// `n`: day `n` of the year in `0...365`, counting February 29.
        case zeroBased(Int)
        /// `Mm.w.d`: the weekday of week `week` (1 to 5, 5 meaning the last)
        /// of the month.
        case weekday(Weekday, week: Int, month: Month)
    }

    /// When a yearly rule's transition happens: `time` seconds (within
    /// ±167 hours) after local midnight of `day`, in the offset in force
    /// before the transition.
    public struct RuleDate: Hashable, Sendable {
        public var day: RuleDay
        public var time: Int

        public init(day: RuleDay, time: Int = 7200) {
            self.day = day
            self.time = time
        }

        var raw: hegel_zone_rule_date_t {
            var raw = hegel_zone_rule_date_t()
            raw.time = Int32(clamping: time)
            switch day {
                case .julian(let day):
                    raw.kind = UInt32(HEGEL_ZONE_RULE_DAY_JULIAN.rawValue)
                    raw.day = UInt16(clamping: day)
                case .zeroBased(let day):
                    raw.kind = UInt32(HEGEL_ZONE_RULE_DAY_ZERO_BASED.rawValue)
                    raw.day = UInt16(clamping: day)
                case .weekday(let weekday, let week, let month):
                    raw.kind = UInt32(HEGEL_ZONE_RULE_DAY_MONTH_WEEK_DAY.rawValue)
                    raw.month = UInt8(month.rawValue)
                    raw.week = UInt8(clamping: week)
                    // POSIX counts weekdays from 0 for Sunday.
                    raw.weekday = UInt8(weekday.rawValue % 7)
            }
            return raw
        }
    }

    /// A yearly rule: `standard` all year, or `daylight` from its start to
    /// its end each year.
    public struct Rule: Hashable, Sendable {
        public var standard: LocalTimeType
        public var daylight: Daylight?

        public init(standard: LocalTimeType, daylight: Daylight? = nil) {
            self.standard = standard
            self.daylight = daylight
        }

        /// The daylight time type and when it starts and ends each year.
        public struct Daylight: Hashable, Sendable {
            public var localTimeType: LocalTimeType
            public var start: RuleDate
            public var end: RuleDate

            public init(localTimeType: LocalTimeType, start: RuleDate, end: RuleDate) {
                self.localTimeType = localTimeType
                self.start = start
                self.end = end
            }
        }
    }

    /// A zone's data, given as fields: the TZif model of RFC 9636.
    public struct Data: Hashable, Sendable {
        /// The type in force before the first transition.
        public var initial: LocalTimeType
        /// The explicit transitions, strictly ascending by instant.
        public var transitions: [Transition]
        /// What is in force after the last transition.
        public var after: After

        public init(initial: LocalTimeType, transitions: [Transition] = [], after: After = .hold) {
            self.initial = initial
            self.transitions = transitions
            self.after = after
        }

        /// What a zone has in force after its explicit transitions.
        public enum After: Hashable, Sendable {
            /// The last transition's type, or the initial type, for ever.
            case hold
            /// A yearly rule, which must have the last transition's type in
            /// force at that transition.
            case rule(Rule)
            /// A yearly rule inferred from the transitions of `lastYear`,
            /// the last year they cover, and the year before it.
            case infer(lastYear: Int)
        }

        /// The fields, without the transitions, which the caller points to.
        func raw(_ strings: StringPool) -> hegel_zone_data_t {
            var raw = hegel_zone_data_t()
            raw.initial = initial.raw(strings)
            switch after {
                case .hold:
                    raw.after = UInt32(HEGEL_ZONE_AFTER_HOLD.rawValue)
                case .rule(let rule):
                    raw.after = UInt32(HEGEL_ZONE_AFTER_RULE.rawValue)
                    raw.standard = rule.standard.raw(strings)
                    if let daylight = rule.daylight {
                        raw.has_dst = true
                        raw.dst = daylight.localTimeType.raw(strings)
                        raw.dst_start = daylight.start.raw
                        raw.dst_end = daylight.end.raw
                    }
                case .infer(let lastYear):
                    raw.after = UInt32(HEGEL_ZONE_AFTER_INFER.rawValue)
                    raw.last_year = Int32(clamping: lastYear)
            }
            return raw
        }
    }

    /// A library that answers offset lookups but does not expose its zone
    /// data, probed into explicit transitions over `years` when it is added
    /// to a source.
    ///
    /// With `nextTransition` the probe asks for each transition in turn;
    /// without it, it samples `offset` once a day and bisects each change
    /// to the second, which misses two changes less than a day apart.
    public struct Oracle {
        /// The years probed, within ±999999.
        public var years: ClosedRange<Int>
        /// What is in force after the last year probed. Before the first,
        /// the type at its start holds.
        public var after: After
        /// The local time type in force at an instant in Unix seconds.
        public var offset: (_ instant: Int) throws -> LocalTimeType
        /// The first instant after the one given at which the type in force
        /// changes, or nil when it never changes again.
        public var nextTransition: ((_ after: Int) throws -> Int?)?

        public init(
            years: ClosedRange<Int>,
            after: After = .hold,
            nextTransition: ((_ after: Int) throws -> Int?)? = nil,
            offset: @escaping (_ instant: Int) throws -> LocalTimeType
        ) {
            self.years = years
            self.after = after
            self.offset = offset
            self.nextTransition = nextTransition
        }

        /// What an oracle's zone does after the last year probed.
        public enum After: Hashable, Sendable {
            /// The last type stays in force.
            case hold
            /// A yearly rule inferred from the last two years probed, which
            /// fits a library that applies the IANA rule for ever. The
            /// years probed must span two at least.
            case infer

            var raw: UInt32 {
                let value =
                    switch self {
                        case .hold: HEGEL_ZONE_AFTER_HOLD
                        case .infer: HEGEL_ZONE_AFTER_INFER
                    }
                return UInt32(value.rawValue)
            }
        }
    }
}

/// A zone source's loader, kept alive by the engine until it releases it.
private final class LoaderBox: Sendable {
    let load: @Sendable (String, ZoneSource.Writer) throws -> Void

    init(_ load: @escaping @Sendable (String, ZoneSource.Writer) throws -> Void) {
        self.load = load
    }
}

/// An oracle being probed, with the abbreviation it last answered, which
/// the engine reads until it next calls the oracle.
private final class OracleBox {
    let oracle: Zone.Oracle
    private var strings = StringPool()

    init(_ oracle: Zone.Oracle) {
        self.oracle = oracle
    }

    func offset(at instant: Int64) throws -> hegel_zone_type_t {
        let type = try oracle.offset(Int(instant))
        strings = StringPool()
        return type.raw(strings)
    }
}

/// Runs a callback's body, turning an error it throws into the failure
/// libhegel reads from the callback's context.
private func reportingErrors(to context: OpaquePointer?, _ body: () throws -> Void) -> Int32 {
    do {
        try body()
        return 0
    } catch {
        // A writer's usage error already carries the engine's message.
        let message =
            if case HegelError.usage(let message) = error { message } else { "\(error)" }
        message.withHegelString { _ = hegel_context_set_error(context, $0) }
        return 1
    }
}

/// Makes a libhegel call outside a test case, turning a failure into a
/// usage error.
func engineQuery(_ body: (OpaquePointer) -> hegel_result_t) throws(HegelError) {
    let context = EngineContext()
    do {
        try context.call(body)
    } catch {
        throw .usage(error.message)
    }
}

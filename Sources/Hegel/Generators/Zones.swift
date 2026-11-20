import CHegel

/// A time zone of a zone source, or `Etc/Unknown`.
///
/// `name` is the name as it was drawn or looked up, link names such as
/// `Asia/Calcutta` included, and `primaryName` the zone whose data applies
/// (`Asia/Kolkata`), or the name itself for a zone the source does not
/// know. Prints as its name.
public struct Zone: Hashable, Sendable, CustomStringConvertible {
    public let name: String
    public let primaryName: String

    /// `Etc/Unknown`, the zone with a known instant and an unknown offset,
    /// in which a wall-clock time is read as UTC.
    public static let unknownName = "Etc/Unknown"

    init(name: String, primaryName: String) {
        self.name = name
        self.primaryName = primaryName
    }

    public var description: String { name }

    /// Features of a zone's history, which zone draws weight toward so that
    /// zones with a rare feature turn up in a short run.
    public struct Tags: OptionSet, Hashable, Sendable {
        public let rawValue: UInt32

        public init(rawValue: UInt32) {
            self.rawValue = rawValue
        }

        /// No offset change after 1970.
        public static let fixed = Tags(rawValue: UInt32(HEGEL_TIMEZONE_TAG_FIXED))
        /// Every offset after 1970 is a whole number of hours.
        public static let wholeHour = Tags(rawValue: UInt32(HEGEL_TIMEZONE_TAG_WHOLE_HOUR))
        /// Some offset after 1970 has minutes (`+05:30`, `+05:45`).
        public static let fractional = Tags(rawValue: UInt32(HEGEL_TIMEZONE_TAG_FRACTIONAL))
        /// Some offset in the zone's history has seconds (local mean time).
        public static let seconds = Tags(rawValue: UInt32(HEGEL_TIMEZONE_TAG_SECONDS))
        /// One annual pair of one-hour transitions.
        public static let dst = Tags(rawValue: UInt32(HEGEL_TIMEZONE_TAG_DST))
        /// Daylight saving of a size other than one hour (Lord Howe's 30
        /// minutes, Troll's two hours).
        public static let otherDST = Tags(rawValue: UInt32(HEGEL_TIMEZONE_TAG_DST_OTHER))
        /// More than two offset changes in some year (Morocco's Ramadan
        /// rule).
        public static let multiple = Tags(rawValue: UInt32(HEGEL_TIMEZONE_TAG_MULTI))
        /// A change of standard offset (Europe/Moscow in 2011 and 2014).
        public static let baseChange = Tags(rawValue: UInt32(HEGEL_TIMEZONE_TAG_BASE_CHANGE))
        /// A transition at local midnight (America/Sao_Paulo).
        public static let midnight = Tags(rawValue: UInt32(HEGEL_TIMEZONE_TAG_MIDNIGHT))
        /// A gap or fold that spans local midnight (Asia/Pyongyang in 2015).
        public static let spansMidnight = Tags(
            rawValue: UInt32(HEGEL_TIMEZONE_TAG_SPANS_MIDNIGHT)
        )
        /// A skipped or doubled whole day (Pacific/Apia in 2011).
        public static let wholeDay = Tags(rawValue: UInt32(HEGEL_TIMEZONE_TAG_WHOLE_DAY))
        /// A transition that changes the abbreviation or DST flag but not
        /// the offset (Europe/Lisbon in 1992).
        public static let sameOffset = Tags(rawValue: UInt32(HEGEL_TIMEZONE_TAG_SAME_OFFSET))
        /// The `-00` undefined offset (`Factory`, `Etc/Unknown`).
        public static let undefined = Tags(rawValue: UInt32(HEGEL_TIMEZONE_TAG_UNDEFINED))
        /// A link to another zone's data (`Asia/Calcutta`).
        public static let link = Tags(rawValue: UInt32(HEGEL_TIMEZONE_TAG_LINK))
        /// A legacy name (`EST`, `EST5EDT`), left out of zone draws by
        /// default.
        public static let legacy = Tags(rawValue: UInt32(HEGEL_TIMEZONE_TAG_LEGACY))
        /// The POSIX-signed `Etc/GMT+5` family, where `+5` means UTC-5.
        public static let invertedSign = Tags(rawValue: UInt32(HEGEL_TIMEZONE_TAG_INVERTED_SIGN))
    }

    /// What a zone source knows about a name.
    public struct Info: Hashable, Sendable {
        /// The zone whose data applies: the link target for a link name,
        /// the name itself otherwise.
        public let primaryName: String
        /// Whether the name is a link to `primaryName`.
        public let isLink: Bool
        /// The name's place on the shrink ladder: `UTC` is 0, every name of
        /// the bundled database has its own rank, a name it lacks comes
        /// after all of those, and `Etc/Unknown` comes last.
        public let rank: Int
        public let tags: Tags

        init(_ raw: hegel_timezone_info_t) {
            primaryName = String(hegelString: raw.primary_name)
            isLink = raw.is_link
            rank = Int(raw.rank)
            tags = Tags(rawValue: raw.tags)
        }
    }

    /// The offset a zone has in force at an instant.
    public struct Offset: Hashable, Sendable {
        /// Unknown only in `Etc/Unknown`.
        public let offset: UTCOffset
        /// The tz database's daylight saving flag, which is informational:
        /// its main and rearguard data disagree on it for zones with
        /// negative daylight saving, such as Europe/Dublin.
        public let isDST: Bool
        /// Such as `EST` or `+0530`; `-00` in `Etc/Unknown`.
        public let abbreviation: String

        init(_ raw: hegel_timezone_offset_t) {
            offset = UTCOffset(seconds: raw.offset_seconds, known: raw.offset_known)
            isDST = raw.is_dst
            abbreviation = String(hegelString: raw.abbreviation)
        }
    }
}

/// A wall-clock time in a time zone, resolved to an instant.
///
/// Build a value of another library from `civil`, the zone's name and
/// `fold`, or for a gap from `timestamp`, never from the offsets, so that
/// a newer database on that side changes what a value means but never
/// makes it invalid.
public struct ZonedDateTime: Hashable, Sendable, CustomStringConvertible {
    /// The zone the wall-clock time is in.
    public let zone: Zone
    /// The wall-clock time.
    public let civil: LocalDateTime
    /// Whether the zone's clocks showed `civil` once, never or twice.
    public let kind: Kind
    /// For a gap or fold, the offset in force before the transition;
    /// `offset` otherwise.
    public let offsetBefore: UTCOffset
    /// For a gap or fold, the offset in force after the transition;
    /// `offset` otherwise.
    public let offsetAfter: UTCOffset
    /// Which instant of a repeated wall time is meant: the later when set.
    /// False for a unique or skipped wall time.
    public let fold: Bool
    /// The offset in force at `timestamp`, unknown in `Etc/Unknown` and in
    /// an opaque zone. For a gap this is `offsetAfter`, since the instant
    /// lies after the transition.
    public let offset: UTCOffset
    /// The instant `civil` resolves to: the unique one, the one `fold`
    /// picks, or for a gap the wall time read with `offsetBefore`, which
    /// moves it forward by the gap's length.
    public let timestamp: Timestamp

    /// How a wall-clock time maps to instants in its zone.
    public enum Kind: Hashable, Sendable, CaseIterable {
        /// Exactly one instant.
        case unique
        /// None: the clocks skipped it.
        case gap
        /// Two: the clocks repeated it.
        case fold

        init(_ raw: hegel_timezone_kind_t) {
            switch raw {
                case HEGEL_TIMEZONE_KIND_GAP: self = .gap
                case HEGEL_TIMEZONE_KIND_FOLD: self = .fold
                default: self = .unique
            }
        }

        var raw: hegel_timezone_kind_t {
            switch self {
                case .unique: HEGEL_TIMEZONE_KIND_UNIQUE
                case .gap: HEGEL_TIMEZONE_KIND_GAP
                case .fold: HEGEL_TIMEZONE_KIND_FOLD
            }
        }
    }

    /// Which instant a zoned datetime draw means by a wall-clock time the
    /// clocks repeated.
    public enum Ambiguous: Hashable, Sendable, CaseIterable {
        /// Either, shrinking to the earlier.
        case both
        case earlier
        case later

        var raw: UInt32 {
            let value =
                switch self {
                    case .both: HEGEL_AMBIGUOUS_BOTH
                    case .earlier: HEGEL_AMBIGUOUS_EARLIER
                    case .later: HEGEL_AMBIGUOUS_LATER
                }
            return UInt32(value.rawValue)
        }
    }

    /// The bounds of a zoned datetime draw: on the wall clock of whatever
    /// zone is drawn, or on the instant.
    public enum Bounds: Hashable, Sendable {
        case wallClock(ClosedRange<LocalDateTime>)
        case instants(ClosedRange<Timestamp>)
    }

    /// RFC 9557, as every Hegel frontend prints a zoned datetime:
    /// `2024-03-10T01:30:00-05:00[America/New_York]`, with `[gap]` for a
    /// wall time the clocks skipped and `[fold=0]` or `[fold=1]` for one
    /// they repeated.
    public var description: String {
        var value = raw
        return zone.name.withHegelString { name in
            engineText { hegel_format_zoned_datetime(nil, &value, name, $0) }
        }
    }

    init(_ raw: hegel_zoned_datetime_t, zone: Zone) {
        self.zone = zone
        civil = LocalDateTime(raw.civil)
        kind = Kind(raw.kind)
        offsetBefore = UTCOffset(seconds: raw.offset_before, known: raw.offset_known)
        offsetAfter = UTCOffset(seconds: raw.offset_after, known: raw.offset_known)
        fold = raw.fold
        offset = UTCOffset(seconds: raw.offset_seconds, known: raw.offset_known)
        timestamp = Timestamp(raw.timestamp)
    }

    init(_ raw: hegel_timezone_resolution_t, civil: LocalDateTime, zone: Zone) {
        self.zone = zone
        self.civil = civil
        kind = Kind(raw.kind)
        offsetBefore = UTCOffset(seconds: raw.offset_before, known: raw.offset_known)
        offsetAfter = UTCOffset(seconds: raw.offset_after, known: raw.offset_known)
        fold = false
        offset = UTCOffset(seconds: raw.offset_seconds, known: raw.offset_known)
        timestamp = Timestamp(raw.timestamp)
    }

    var raw: hegel_zoned_datetime_t {
        var value = hegel_zoned_datetime_t()
        value.civil = civil.raw
        value.offset_seconds = offset.rawSeconds
        value.offset_known = offset != .unknown
        value.fold = fold
        value.kind = kind.raw
        value.offset_before = offsetBefore.rawSeconds
        value.offset_after = offsetAfter.rawSeconds
        value.timestamp = timestamp.raw
        return value
    }
}

/// The time zones a zone or zoned datetime draw picks from.
///
/// By default every name of the default zone source, link names such as
/// `Asia/Calcutta` included and legacy names such as `EST5EDT` and
/// `Etc/Unknown` left out.
public struct Zones: Sendable {
    /// Only these names, each spelled exactly as the source spells it, or
    /// `Etc/Unknown`; nil for every name the flags allow.
    public var names: [String]?
    /// Whether link names are drawn.
    public var links: Bool
    /// Whether legacy names are drawn.
    public var legacy: Bool
    /// Whether `Etc/Unknown` is drawn.
    public var unknown: Bool
    /// Whether a name in `names` that the source does not know is drawn as
    /// an opaque zone, one only your own database knows: its wall-clock
    /// times are read as UTC, with an unknown offset.
    public var opaque: Bool
    /// The source to draw names from and resolve times against; nil for
    /// the default zone source as it is when the generator is built.
    public var source: ZoneSource?

    public init(
        names: [String]? = nil,
        links: Bool = true,
        legacy: Bool = false,
        unknown: Bool = false,
        opaque: Bool = false,
        source: ZoneSource? = nil
    ) {
        self.names = names
        self.links = links
        self.legacy = legacy
        self.unknown = unknown
        self.opaque = opaque
        self.source = source
    }
}

/// A time zone spec for `zones`, with the source it reads.
private struct ZoneSpec: Sendable {
    let object: EngineObject
    let source: ZoneSource

    init(_ zones: Zones) {
        let source = zones.source ?? .default
        self.source = source
        object = EngineObject(
            make: { hegel_timezone_spec_new($0, $1) },
            free: { _ = hegel_timezone_spec_free(nil, $0) },
            configure: { context, spec throws(EngineError) in
                if let names = zones.names {
                    try withHegelStrings(names) { (views, count) throws(EngineError) in
                        _ = try context.call {
                            hegel_timezone_spec_set_names($0, spec, views, count)
                        }
                    }
                }
                try context.call { hegel_timezone_spec_set_links($0, spec, zones.links) }
                try context.call { hegel_timezone_spec_set_legacy($0, spec, zones.legacy) }
                try context.call { hegel_timezone_spec_set_unknown($0, spec, zones.unknown) }
                try context.call { hegel_timezone_spec_set_opaque($0, spec, zones.opaque) }
                try context.call { hegel_timezone_spec_set_source($0, spec, source.raw) }
                try context.call { hegel_timezone_spec_validate($0, spec) }
            }
        )
    }
}

/// A zoned datetime spec.
private func zonedSpec(
    bounds: ZonedDateTime.Bounds?,
    precision: Precision,
    allowImaginary: Bool,
    ambiguous: ZonedDateTime.Ambiguous
) -> EngineObject {
    let imaginary = UInt32(
        (allowImaginary ? HEGEL_IMAGINARY_ALLOW : HEGEL_IMAGINARY_AVOID).rawValue
    )
    return EngineObject(
        make: { hegel_zoned_spec_new($0, $1) },
        free: { _ = hegel_zoned_spec_free(nil, $0) },
        configure: { context, spec throws(EngineError) in
            switch bounds {
                case .wallClock(let range):
                    try context.call {
                        hegel_zoned_spec_set_civil_bounds(
                            $0,
                            spec,
                            range.lowerBound.raw,
                            range.upperBound.raw
                        )
                    }
                case .instants(let range):
                    try context.call {
                        hegel_zoned_spec_set_instant_bounds(
                            $0,
                            spec,
                            range.lowerBound.raw,
                            range.upperBound.raw
                        )
                    }
                case nil:
                    break
            }
            try context.call { hegel_zoned_spec_set_precision($0, spec, precision.raw) }
            try context.call { hegel_zoned_spec_set_imaginary($0, spec, imaginary) }
            try context.call { hegel_zoned_spec_set_ambiguous($0, spec, ambiguous.raw) }
            try context.call { hegel_zoned_spec_validate($0, spec) }
        }
    )
}

extension Gen where Value == Zone {
    /// Time zones from `zones`. Half the draws are uniform over the names
    /// and half weighted toward zones with rare features. Shrinks down the
    /// source's rank ladder, to `UTC` when it is allowed.
    public static func zone(from zones: Zones = Zones()) -> Gen<Zone> {
        let spec = ZoneSpec(zones)
        return Gen(label: .zone) { tc, printer in
            let handle = try spec.object.handle()
            var name = hegel_owned_string_t()
            try tc.call { hegel_generate_timezone($0, tc.raw, handle, &name) }
            let value = try spec.source.zone(drawn: ownedString(&name), in: tc)
            printer.value(value)
            return value
        }
    }
}

extension Gen where Value == ZonedDateTime {
    /// Wall-clock times in a zone from `zones`, within `bounds`, the time a
    /// whole number of `precision` units.
    ///
    /// A wall time the clocks skipped is drawn unless `allowImaginary` is
    /// false, and `ambiguous` says which instant a repeated one means.
    /// One draw in twenty on average aims at a transition of the zone,
    /// which is how gaps, both folds and the boundary instants are
    /// reached. Shrinks down the zone ladder, then toward
    /// 2000-01-01T00:00:00, preferring a unique wall time to a repeated
    /// one.
    public static func zonedDateTime(
        zones: Zones = Zones(),
        in bounds: ZonedDateTime.Bounds? = nil,
        precision: Precision = .nanoseconds,
        allowImaginary: Bool = true,
        ambiguous: ZonedDateTime.Ambiguous = .both
    ) -> Gen<ZonedDateTime> {
        let zoneSpec = ZoneSpec(zones)
        let spec = zonedSpec(
            bounds: bounds,
            precision: precision,
            allowImaginary: allowImaginary,
            ambiguous: ambiguous
        )
        return Gen(label: .zonedDateTime) { tc, printer in
            let zoneHandle = try zoneSpec.object.handle()
            let handle = try spec.handle()
            var out = hegel_zoned_datetime_t()
            var name = hegel_owned_string_t()
            try tc.call {
                hegel_generate_zoned_datetime($0, tc.raw, zoneHandle, handle, &out, &name)
            }
            let zone = try zoneSpec.source.zone(drawn: ownedString(&name), in: tc)
            let value = ZonedDateTime(out, zone: zone)
            printer.value(value)
            return value
        }
    }

    /// Wall-clock times in the zone `zone` of `source`, or of the default
    /// zone source as it is when the generator is built, drawn as
    /// `zonedDateTime(zones:)` draws them once it has its zone. A name the
    /// source does not know is a usage error, never an opaque zone.
    public static func zonedDateTime(
        zone: String,
        source: ZoneSource? = nil,
        in bounds: ZonedDateTime.Bounds? = nil,
        precision: Precision = .nanoseconds,
        allowImaginary: Bool = true,
        ambiguous: ZonedDateTime.Ambiguous = .both
    ) -> Gen<ZonedDateTime> {
        zonedDateTime(
            zone: .just(zone),
            source: source,
            in: bounds,
            precision: precision,
            allowImaginary: allowImaginary,
            ambiguous: ambiguous
        )
    }

    /// Wall-clock times in a zone `zone` draws, looked up in `source` or
    /// the default zone source as it is when the generator is built, the
    /// zone shrinking as `zone` shrinks.
    public static func zonedDateTime(
        zone: Gen<String>,
        source: ZoneSource? = nil,
        in bounds: ZonedDateTime.Bounds? = nil,
        precision: Precision = .nanoseconds,
        allowImaginary: Bool = true,
        ambiguous: ZonedDateTime.Ambiguous = .both
    ) -> Gen<ZonedDateTime> {
        let source = source ?? .default
        let spec = zonedSpec(
            bounds: bounds,
            precision: precision,
            allowImaginary: allowImaginary,
            ambiguous: ambiguous
        )
        return Gen(label: Label.zonedDateTime.combined(with: zone.label)) { tc, printer in
            let handle = try spec.handle()
            let name = try tc.drawSilent(zone)
            var out = hegel_zoned_datetime_t()
            try name.withHegelString { view in
                try tc.call {
                    hegel_generate_zoned_datetime_for_zone(
                        $0,
                        tc.raw,
                        source.raw,
                        view,
                        handle,
                        &out
                    )
                }
            }
            let value = ZonedDateTime(out, zone: try source.zone(drawn: name, in: tc))
            printer.value(value)
            return value
        }
    }
}

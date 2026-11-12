import CHegel

/// Identifies the generator that opened a span of draws.
///
/// The shrinker treats spans with the same label as coming from the same
/// generator, so it can swap, duplicate and reorder them. A generator with
/// no components is labelled by name; one built from other generators
/// combines its own label with theirs, so that an array of integers and an
/// array of strings get different labels.
public struct Label: Hashable, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    /// The label for a generator identified by `name`.
    ///
    /// Use a prefix that names your library, such as `"mylib.money"`, to keep
    /// clear of Hegel's own names.
    public static func named(_ name: String) -> Label {
        var label: UInt64 = 0
        name.withHegelString { view in
            _ = hegel_label_from_name(nil, view, &label)
        }
        return Label(rawValue: label)
    }

    /// This label combined with the labels of a generator's components, in
    /// order.
    public func combined(with components: [Label]) -> Label {
        let labels = [rawValue] + components.map(\.rawValue)
        var label: UInt64 = 0
        labels.withUnsafeBufferPointer { buffer in
            _ = hegel_label_combine(nil, buffer.baseAddress, buffer.count, &label)
        }
        return Label(rawValue: label)
    }

    /// This label combined with the labels of a generator's components.
    public func combined(with components: Label...) -> Label {
        combined(with: components)
    }
}

extension Label {
    static let map = named("swift.map")
    static let flatMap = named("swift.flatMap")
    static let filter = named("swift.filter")
    static let filterAttempt = named("swift.filter.attempt")
    static let zip = named("swift.zip")
    static let oneOf = named("swift.oneOf")
    static let optional = named("swift.optional")
    static let array = named("swift.array")
    static let set = named("swift.set")
    static let dictionary = named("swift.dictionary")
    static let element = named("swift.element")
    static let just = named("swift.just")
    static let recursive = named("swift.recursive")
    static let recursiveNode = named("swift.recursive.node")
    static let deferred = named("swift.deferred")
    static let poolReusable = named("swift.pool.reusable")
    static let poolConsumed = named("swift.pool.consumed")
    static let stateMachineRule = named("swift.stateMachine.rule")
    static let bool = named("swift.bool")
    static let integer = named("swift.integer")
    static let floatingPoint = named("swift.floatingPoint")
    static let string = named("swift.string")
    static let bytes = named("swift.bytes")
    static let composite = named("swift.composite")
}

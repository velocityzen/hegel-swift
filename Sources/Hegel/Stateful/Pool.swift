import CHegel
import Synchronization

/// Values a test case has made, for later steps to draw from: the accounts a
/// state machine opened, the keys it inserted.
///
/// The engine chooses which value a draw gets, and shrinks that choice like
/// any other: toward earlier values, and toward fewer values overall.
///
/// ```swift
/// let keys = try tc.pool(of: String.self)
/// try keys.add("a")
/// let key = try tc.draw(keys.reusable, named: "key")
/// ```
///
/// A pool belongs to the test case that made it. The workers of a
/// `ConcurrentStateMachine` may share one: pass each worker's test case to
/// `add(_:using:)`.
public final class Pool<Value>: @unchecked Sendable {
    private let raw: OpaquePointer
    private unowned let testCase: TestCase
    private let lock = Mutex(())
    /// Guarded by `lock`.
    private var values: [Int64: Value] = [:]

    init(_ tc: TestCase) throws {
        var handle: OpaquePointer?
        try tc.call { hegel_new_pool($0, tc.raw, &handle) }
        guard let handle else {
            throw HegelError.engine("libhegel returned no pool handle")
        }
        raw = handle
        testCase = tc
    }

    deinit {
        hegel_pool_free(nil, raw)
    }

    /// The number of values a draw can get.
    public var count: Int { locked { values.count } }

    public var isEmpty: Bool { count == 0 }

    /// Adds `value` to the pool, drawing its id from `tc`: the test case of
    /// the rule adding it, or the one that made the pool when nil. A worker
    /// of a concurrent machine must pass its own.
    public func add(_ value: Value, using tc: TestCase? = nil) throws {
        let tc = tc ?? testCase
        // Under the lock, so no worker can draw the id before its value
        // is there.
        try lockedThrowing {
            var id: Int64 = 0
            try tc.call { hegel_pool_add($0, tc.raw, raw, &id) }
            values[id] = value
        }
    }

    private func locked<R>(_ body: () -> R) -> R {
        // The result leaves the lock through a local: `withLock` only hands
        // back results it can prove are not shared.
        var result: R?
        lock.withLock { _ in result = body() }
        return result!
    }

    private func lockedThrowing<R>(_ body: () throws -> R) throws -> R {
        var result: Result<R, any Error>?
        lock.withLock { _ in result = Result { try body() } }
        return try result!.get()
    }

    /// One of the pool's values, left in the pool. Drawing from an empty
    /// pool rejects the test case, or the state machine step.
    public var reusable: Gen<Value> {
        Gen(label: .poolReusable) { tc, printer in
            let (_, value) = try self.draw(tc, consume: false)
            printer.value(value)
            return value
        }
    }

    /// One of the pool's values, removed from the pool. Drawing from an
    /// empty pool rejects the test case, or the state machine step.
    public var consumed: Gen<Value> {
        Gen(label: .poolConsumed) { tc, printer in
            let (_, value) = try self.draw(tc, consume: true)
            printer.value(value)
            return value
        }
    }

    /// One of the pool's values for which `isIncluded` holds, removed from
    /// the pool.
    ///
    /// Use it instead of `consumed.filter(_:)`, which would remove the values
    /// it rejects. A few attempts are made; when all of them fail, the test
    /// case or step is rejected.
    public func consumed(
        where isIncluded: @escaping @Sendable (Value) throws -> Bool
    ) -> Gen<Value> {
        Gen(label: Label.filter.combined(with: .poolConsumed)) { tc, printer in
            var rejected: [Int64] = []
            var accepted: Value?
            do {
                for _ in 0..<filterAttempts where rejected.count < self.count {
                    try tc.startSpan(.filterAttempt)
                    try tc.startSpan(.poolConsumed)
                    let (id, value) = try self.draw(tc, consume: true, remove: false)
                    try tc.stopSpan()
                    if try isIncluded(value) {
                        try tc.stopSpan()
                        self.locked { self.values[id] = nil }
                        accepted = value
                        break
                    }
                    try tc.stopSpan(discard: true)
                    rejected.append(id)
                }
            } catch {
                try? self.restore(rejected, tc)
                throw error
            }
            try self.restore(rejected, tc)
            guard let accepted else {
                try tc.reject()
            }
            printer.value(accepted)
            return accepted
        }
    }

    /// Draws a value, removing it from the map when it is consumed, unless
    /// `remove` is false: a filter removes only the value it accepts.
    private func draw(
        _ tc: TestCase,
        consume: Bool,
        remove: Bool = true
    ) throws -> (id: Int64, value: Value) {
        try lockedThrowing {
            var id: Int64 = 0
            try tc.call { hegel_pool_generate($0, tc.raw, raw, consume, &id) }
            guard let value = values[id] else {
                throw HegelError.engine(
                    "libhegel drew pool variable \(id), which isn't in the pool"
                )
            }
            if consume, remove {
                values[id] = nil
            }
            return (id, value)
        }
    }

    /// Puts back values a filter consumed and then rejected.
    private func restore(_ ids: [Int64], _ tc: TestCase) throws {
        for id in ids {
            try tc.call { hegel_pool_restore($0, tc.raw, raw, id) }
        }
    }
}

extension TestCase {
    /// A new, empty pool of values for later draws to choose from.
    public func pool<Value>(of _: Value.Type = Value.self) throws -> Pool<Value> {
        try Pool(self)
    }
}

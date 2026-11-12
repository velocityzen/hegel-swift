import CHegel
import Synchronization

extension Gen {
    /// Values built recursively from `leaf`, such as trees and expressions.
    ///
    /// `branch` gets a generator of sub-values and returns a generator of one
    /// level of structure built from them:
    ///
    /// ```swift
    /// indirect enum Tree { case leaf(Int), node([Tree]) }
    ///
    /// let trees: Gen<Tree> = .recursive(leaf: Gen.int().map(Tree.leaf)) { subtree in
    ///     Gen.array(of: subtree, count: 1...3).map(Tree.node)
    /// }
    /// ```
    ///
    /// The engine decides where a value branches and where it bottoms out,
    /// so values have a spread of sizes, and a failing value shrinks toward
    /// a single leaf.
    ///
    /// - Parameters:
    ///   - maxDepth: Branches nest at most this deep. Sub-values at this
    ///     depth are always leaves, so `0` generates only leaves.
    ///   - maxLeaves: The most leaves one value may contain. A draw that
    ///     grows past it is discarded and drawn again, smaller; a test case
    ///     where that keeps happening is rejected.
    public static func recursive(
        maxDepth: Int = 32,
        maxLeaves: Int = 100,
        leaf: Gen<Value>,
        branch: @escaping @Sendable (_ subtree: Gen<Value>) -> Gen<Value>
    ) -> Gen<Value> {
        precondition(maxDepth >= 0, "maxDepth must not be negative")
        precondition(maxLeaves >= 1, "maxLeaves must be at least 1")
        return Gen(label: Label.recursive.combined(with: leaf.label)) { tc, printer in
            let baseDepth = tc.spanDepth
            let recursion = try Recursion(
                tc,
                maxDepth: UInt64(maxDepth),
                maxLeaves: UInt64(maxLeaves)
            )
            let tree = RecursiveTree(
                recursion: recursion,
                leaf: leaf,
                branch: branch,
                label: Label.recursiveNode.combined(with: leaf.label)
            )
            while true {
                do {
                    return try printer.speculate {
                        let value = try tc.draw(tree.node(depth: 0), printer: printer)
                        guard try recursion.finish(tc) else {
                            throw RecursionRestart(recursion: recursion, needsRetry: false)
                        }
                        return value
                    }
                } catch let restart as RecursionRestart where restart.recursion === recursion {
                    // The engine closed the attempt's spans as discarded.
                    tc.resetSpanDepth(to: baseDepth)
                    if restart.needsRetry {
                        try recursion.retry(tc)
                    }
                }
            }
        }
    }

    /// A generator that `make` builds the first time it is drawn from.
    ///
    /// Use it for generators that refer to themselves or to each other, which
    /// a definition can't do directly:
    ///
    /// ```swift
    /// static let json: Gen<JSON> = .oneOf(
    ///     Gen.int().map(JSON.number),
    ///     .deferred { Gen.array(of: json, count: 0...3).map(JSON.array) }
    /// )
    /// ```
    ///
    /// Nothing bounds how deep such a definition recurses except the engine's
    /// budget for a test case. Prefer `recursive(maxDepth:maxLeaves:leaf:branch:)`,
    /// which sizes values for you, when the recursion has one shape.
    public static func deferred(
        fileID: StaticString = #fileID,
        line: UInt = #line,
        column: UInt = #column,
        _ make: @escaping @Sendable () -> Gen<Value>
    ) -> Gen<Value> {
        let definition = Deferred(make)
        return Gen(
            label: Label.deferred.combined(with: .named("\(fileID):\(line):\(column)"))
        ) { tc, printer in
            try tc.draw(definition.generator, printer: printer)
        }
    }
}

/// The generator a `Gen.deferred` definition builds, made once.
private final class Deferred<Value>: Sendable {
    private let make: @Sendable () -> Gen<Value>
    private let built = Mutex<Gen<Value>?>(nil)

    init(_ make: @escaping @Sendable () -> Gen<Value>) {
        self.make = make
    }

    var generator: Gen<Value> {
        if let generator = built.withLock({ $0 }) {
            return generator
        }
        // Built outside the lock: `make` may draw on other deferred
        // definitions, or on this one.
        let generator = make()
        built.withLock { $0 = generator }
        return generator
    }
}

/// The sub-value generators of one recursive draw.
private struct RecursiveTree<Value>: Sendable {
    let recursion: Recursion
    let leaf: Gen<Value>
    let branch: @Sendable (Gen<Value>) -> Gen<Value>
    let label: Label

    func node(depth: UInt64) -> Gen<Value> {
        Gen(label: label) { tc, printer in
            if try recursion.branch(tc, depth: depth) {
                return try tc.draw(branch(node(depth: depth + 1)), printer: printer)
            }
            guard try recursion.leaf(tc) else {
                throw RecursionRestart(recursion: recursion, needsRetry: true)
            }
            return try tc.draw(leaf, printer: printer)
        }
    }
}

/// Unwinds a recursive draw back to its root, to start it again.
private struct RecursionRestart: Error {
    let recursion: Recursion
    /// Whether the attempt outgrew its leaf budget and the engine has to be
    /// told with `hegel_recursion_retry`. A mispriced attempt, which
    /// `hegel_recursion_finish` already discarded, needs no retry.
    let needsRetry: Bool
}

/// A `hegel_recursion_t`: the engine's state for one recursive value.
private final class Recursion: @unchecked Sendable {
    let raw: OpaquePointer

    init(_ tc: TestCase, maxDepth: UInt64, maxLeaves: UInt64) throws {
        var handle: OpaquePointer?
        try tc.call { hegel_new_recursion($0, tc.raw, maxDepth, maxLeaves, &handle) }
        guard let handle else {
            throw HegelError.engine("libhegel returned no recursion handle")
        }
        raw = handle
    }

    deinit {
        hegel_recursion_free(nil, raw)
    }

    /// Whether the sub-value at `depth` branches.
    func branch(_ tc: TestCase, depth: UInt64) throws -> Bool {
        var branches = false
        try tc.call { hegel_recursion_branch($0, tc.raw, raw, depth, &branches) }
        return branches
    }

    /// Counts a leaf; false when the attempt has outgrown its budget.
    func leaf(_ tc: TestCase) throws -> Bool {
        try tc.callAllowingRetry { hegel_recursion_leaf($0, tc.raw, raw) }
    }

    /// Starts the value again after a leaf budget overrun. Throws a
    /// rejection once the engine gives up on the test case.
    func retry(_ tc: TestCase) throws {
        try tc.call { hegel_recursion_retry($0, tc.raw, raw) }
    }

    /// Whether the engine accepts the finished value.
    func finish(_ tc: TestCase) throws -> Bool {
        try tc.callAllowingRetry { hegel_recursion_finish($0, tc.raw, raw) }
    }
}

import Hegel
import Testing

indirect enum Tree: Equatable, CustomStringConvertible {
    case leaf(Int)
    case node([Tree])

    var leaves: Int {
        switch self {
            case .leaf: 1
            case .node(let children): children.reduce(0) { $0 + $1.leaves }
        }
    }

    var depth: Int {
        switch self {
            case .leaf: 0
            case .node(let children): 1 + (children.map(\.depth).max() ?? 0)
        }
    }

    var description: String {
        switch self {
            case .leaf(let n): "\(n)"
            case .node(let children): "(\(children.map(\.description).joined(separator: " ")))"
        }
    }
}

let trees: Gen<Tree> = .recursive(leaf: Gen.int(in: 0...100).map(Tree.leaf)) { subtree in
    Gen.array(of: subtree, count: 1...3).map(Tree.node)
}

/// Mutually recursive generators through `deferred`.
enum Expr: CustomStringConvertible {
    case number(Int)
    case sum([Expr])

    var value: Int {
        switch self {
            case .number(let n): n
            case .sum(let terms): terms.reduce(0) { $0 + $1.value }
        }
    }

    var description: String {
        switch self {
            case .number(let n): "\(n)"
            case .sum(let terms): "(+ \(terms.map(\.description).joined(separator: " ")))"
        }
    }

    static let gen: Gen<Expr> = .oneOf(
        Gen.int(in: 0...10).map(Expr.number),
        .deferred { Gen.array(of: gen, count: 1...2).map(Expr.sum) }
    )
}

@Suite("Recursive generators")
struct RecursiveTests {
    @Test("a failing tree shrinks to a single leaf")
    func shrinksToLeaf() throws {
        let drawn = try minimalExample { tc in
            let tree = try tc.draw(trees, named: "tree")
            if case .leaf(let n) = tree, n < 50 {
                return
            }
            if case .node = tree {
                return
            }
            throw Failed()
        }
        #expect(drawn == ["let tree = 50"])
    }

    @Test("a failing tree shrinks to its smallest shape")
    func shrinksShape() throws {
        let drawn = try minimalExample { tc in
            let tree = try tc.draw(trees, named: "tree")
            if tree.leaves >= 3 {
                throw Failed()
            }
        }
        #expect(drawn == ["let tree = (0 0 0)"])
    }

    @Test("trees respect the depth and leaf bounds")
    func bounds() throws {
        let shallow: Gen<Tree> = .recursive(
            maxDepth: 2,
            maxLeaves: 10,
            leaf: Gen.int(in: 0...9).map(Tree.leaf)
        ) { subtree in
            Gen.array(of: subtree, count: 1...3).map(Tree.node)
        }
        try Property.check(settings: isolated) { tc in
            let tree = try tc.draw(shallow)
            #expect(tree.depth <= 2)
            #expect(tree.leaves <= 10)
        }
    }

    @Test("maxDepth 0 draws only leaves")
    func leavesOnly() throws {
        let leaves: Gen<Tree> = .recursive(maxDepth: 0, leaf: Gen.int().map(Tree.leaf)) { subtree in
            Gen.array(of: subtree).map(Tree.node)
        }
        try Property.check(settings: isolated) { tc in
            let tree = try tc.draw(leaves)
            #expect(tree.depth == 0)
        }
    }

    @Test("deferred generators can refer to themselves")
    func deferredRecursion() throws {
        let drawn = try minimalExample { tc in
            let expr = try tc.draw(Expr.gen, named: "expr")
            if case .sum = expr, expr.value > 10 {
                throw Failed()
            }
        }
        #expect(drawn == ["let expr = (+ 1 10)"])
    }
}

/// A stack that loses the bottom element once it holds three.
final class LeakyStack {
    private var items: [Int] = []

    var count: Int { items.count }

    func push(_ x: Int) {
        items.append(x)
        if items.count == 3 {
            items.removeFirst()
        }
    }

    func pop() -> Int? {
        items.popLast()
    }
}

struct StackModel {
    var expected: [Int] = []
    let stack = LeakyStack()
}

struct Mismatch: Error, CustomStringConvertible {
    var description: String
}

let stackMachine = StateMachine<StackModel>()
    .rule("push") { model, tc in
        let x = try tc.draw(.int(in: 0...100), named: "x")
        model.expected.append(x)
        model.stack.push(x)
    }
    .rule("pop") { model, tc in
        try tc.assume(!model.expected.isEmpty)
        let popped = model.stack.pop()
        let expected = model.expected.removeLast()
        if popped != expected {
            throw Mismatch(description: "popped \(popped ?? -1), expected \(expected)")
        }
    }

@Suite("State machines")
struct StateMachineTests {
    @Test("a failing machine shrinks to the fewest steps")
    func shrinksSteps() throws {
        let drawn = try minimalExample { tc in
            try stackMachine.run(tc, from: StackModel())
        }
        #expect(
            drawn == [
                "Step 1: push {",
                "  let x = 0",
                "}",
                "Step 2: push {",
                "  let x = 0",
                "}",
                "Step 3: push {",
                "  let x = 0",
                "}",
                "Step 4: pop {",
                "}",
                "Step 5: pop {",
                "}",
                "Step 6: pop {",
                "}",
                "Rule pop failed:",
            ]
        )
    }

    @Test("an invariant fails at the step that breaks it")
    func invariantFails() throws {
        let machine = stackMachine.invariant("count", everyStep: true) { model, _ in
            if model.stack.count != model.expected.count {
                throw Mismatch(description: "count \(model.stack.count) != \(model.expected.count)")
            }
        }
        let drawn = try minimalExample { tc in
            try machine.run(tc, from: StackModel())
        }
        #expect(drawn.last == "Invariant count failed:")
        #expect(drawn.filter { $0.hasPrefix("Step") }.count == 3)
    }

    @Test("a rule that rejects is skipped, not the test case")
    func rejectedRules() throws {
        let machine = StateMachine<Int>()
            .rule("never") { _, tc in try tc.reject() }
            .rule("count") { n, _ in n += 1 }
        let outcome = try Property.run(settings: isolated) { tc in
            let n = try machine.run(tc, from: 0)
            if n > 3 {
                throw Failed()
            }
        }
        let failure = try #require(outcome.failure)
        let steps = failure.counterexamples[0].drawn.filter { $0.hasSuffix(": count {") }
        #expect(steps.count == 4)
    }

    @Test("pools hand back values the machine added")
    func pools() throws {
        struct Bank {
            var balances: [String: Int] = [:]
            var accounts: Pool<String>
        }
        let bank = StateMachine<Bank>()
            .rule("open") { bank, tc in
                let name = try tc.draw(.element(of: ["a", "b", "c"]), named: "name")
                try tc.assume(bank.balances[name] == nil)
                bank.balances[name] = 0
                try bank.accounts.add(name)
            }
            .rule("deposit") { bank, tc in
                let name = try tc.draw(bank.accounts.reusable, named: "account")
                let amount = try tc.draw(.int(in: 1...100), named: "amount")
                bank.balances[name, default: 0] += amount
                // The bug: big deposits are lost.
                if amount > 50 {
                    throw Mismatch(description: "lost a deposit")
                }
            }
            .rule("close") { bank, tc in
                let name = try tc.draw(bank.accounts.consumed, named: "account")
                bank.balances[name] = nil
            }
        let drawn = try minimalExample { tc in
            try bank.run(tc, from: Bank(accounts: try tc.pool()))
        }
        #expect(
            drawn == [
                "Step 1: open {",
                "  let name = \"a\"",
                "}",
                "Step 2: deposit {",
                "  let account = \"a\"",
                "  let amount = 51",
                "}",
                "Rule deposit failed:",
            ]
        )
    }

    @Test("a filtered consuming draw leaves rejected values in the pool")
    func consumedWhere() throws {
        try Property.check(settings: isolated) { tc in
            let pool = try tc.pool(of: Int.self)
            for n in 0..<5 {
                try pool.add(n)
            }
            let even = try tc.draw(pool.consumed(where: { $0.isMultiple(of: 2) }))
            #expect(even.isMultiple(of: 2))
            #expect(pool.count == 4)
        }
    }
}

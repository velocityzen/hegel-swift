import Hegel
import Testing

/// The generator examples from README.md, kept compiling and working.
@Suite("README examples")
struct ReadmeTests {
    struct User {
        var name: String
        var age: Int
    }

    @Test("composed generators")
    func generators() throws {
        let users: Gen<User> = zip(.string(of: .ascii, count: 1...20), .int(in: 0...120))
            .map(User.init)

        let sortedPairs = zip(Gen.int(), Gen.int()).filter { $0 <= $1 }

        let intervals = Gen { tc in
            let lo = try tc.draw(.int(in: 0...100))
            let hi = try tc.draw(.int(in: lo...100))
            return lo...hi
        }

        try Property.check(settings: isolated) { tc in
            let user = try tc.draw(users, named: "user")
            #expect((1...20).contains(user.name.unicodeScalars.count))
            let (a, b) = try tc.draw(sortedPairs)
            #expect(a <= b)
            let interval = try tc.draw(intervals)
            #expect(interval.lowerBound >= 0)
        }
    }

    @Test("Property.run without Swift Testing")
    func run() throws {
        let outcome = try Property.run(settings: Settings(testCases: 200).merging(isolated)) { tc in
            let n = try tc.draw(.int(), named: "n")
            if n.magnitude > UInt(Int.max) {
                throw Failed()
            }
        }
        #expect(outcome.failure != nil)
        #expect(outcome.failure?.report().contains("let n = -9223372036854775808") == true)
    }

    @Test("a state machine over a pool")
    func bankMachine() throws {
        struct Bank {
            var balances: [String: Int] = [:]
            var accounts: Pool<String>
        }

        let bank = StateMachine<Bank>()
            .rule("open") { bank, tc in
                let name = try tc.draw(.string(of: .ascii, count: 1...8), named: "name")
                try tc.assume(bank.balances[name] == nil)
                bank.balances[name] = 0
                try bank.accounts.add(name)
            }
            .rule("close") { bank, tc in
                let name = try tc.draw(bank.accounts.consumed, named: "account")
                bank.balances[name] = nil
            }
            .invariant("one balance per account", everyStep: true) { bank, _ in
                #expect(bank.balances.count == bank.accounts.count)
            }

        try Property.check(settings: isolated) { tc in
            try bank.run(tc, from: Bank(accounts: try tc.pool()))
        }
    }
}

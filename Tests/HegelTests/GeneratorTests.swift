import Hegel
import Testing

/// Runs `body` over generated test cases and returns the first failing
/// example's drawn lines.
func minimalExample(_ body: (TestCase) throws -> Void) throws -> [String] {
    let outcome = try Property.run(settings: isolated, body)
    return try #require(outcome.failure).counterexamples[0].drawn
}

@Suite("Generators")
struct GeneratorTests {
    @Test("integers stay in range")
    func integerBounds() throws {
        try Property.check(settings: isolated) { tc in
            let n = try tc.draw(Gen<Int8>.integer(in: -5...5))
            #expect((-5...5).contains(n))
            let u = try tc.draw(Gen<UInt64>.integer(in: (UInt64.max - 3)...UInt64.max))
            #expect(u >= UInt64.max - 3)
            let wide = try tc.draw(
                Gen<Int128>.integer(in: Int128(Int64.min) * 4...Int128(Int64.min) * 2)
            )
            #expect(wide <= Int128(Int64.min) * 2)
        }
    }

    @Test("doubles in a range are finite and in range")
    func doubleBounds() throws {
        try Property.check(settings: isolated) { tc in
            let x = try tc.draw(.double(in: 0...1))
            #expect((0...1).contains(x))
            let f = try tc.draw(.float(in: -1...1))
            #expect((-1...1).contains(f))
        }
    }

    @Test("map prints the mapped value")
    func mapPrints() throws {
        let drawn = try minimalExample { tc in
            let s = try tc.draw(Gen.int(in: 0...100).map { "n\($0)" }, named: "s")
            if s.count > 2 {
                throw Failed()
            }
        }
        #expect(drawn == [#"let s = "n10""#])
    }

    @Test("filter keeps only matching values")
    func filter() throws {
        try Property.check(settings: isolated) { tc in
            let even = try tc.draw(Gen.int(in: 0...1000).filter { $0.isMultiple(of: 2) })
            #expect(even.isMultiple(of: 2))
        }
    }

    @Test("zip draws a tuple and prints it")
    func zipPrints() throws {
        let drawn = try minimalExample { tc in
            let (a, b) = try tc.draw(zip(Gen.int(in: 0...10), Gen.bool()), named: "pair")
            if a > 3 && b {
                throw Failed()
            }
        }
        #expect(drawn == ["let pair = (4, true)"])
    }

    @Test("sets have distinct elements")
    func sets() throws {
        try Property.check(settings: isolated) { tc in
            let set = try tc.draw(.set(of: .int(in: 0...5), count: 3...3))
            #expect(set.count == 3)
        }
    }

    @Test("dictionaries print as literals")
    func dictionaries() throws {
        let drawn = try minimalExample { tc in
            let d = try tc.draw(.dictionary(keys: .int(in: 0...9), values: .bool()), named: "d")
            if d.values.contains(true) {
                throw Failed()
            }
        }
        #expect(drawn == ["let d = [0: true]"])
    }

    @Test("oneOf and optional")
    func choices() throws {
        let drawn = try minimalExample { tc in
            let x = try tc.draw(.optional(.oneOf(.just(1), .int(in: 5...9))), named: "x")
            if let x, x > 1 {
                throw Failed()
            }
        }
        #expect(drawn == ["let x = 5"])
    }

    @Test("strings respect their alphabet and count")
    func strings() throws {
        try Property.check(settings: isolated) { tc in
            let s = try tc.draw(.string(of: .characters("ab"), count: 2...4))
            #expect((2...4).contains(s.unicodeScalars.count))
            let onlyAB = s.allSatisfy { $0 == "a" || $0 == "b" }
            #expect(onlyAB)
            let ascii = try tc.draw(.string(of: .ascii))
            let allASCII = ascii.unicodeScalars.allSatisfy { $0.isASCII }
            #expect(allASCII)
        }
    }

    @Test("regex strings match")
    func regex() throws {
        try Property.check(settings: isolated) { tc in
            let s = try tc.draw(.matching("[0-9]{3}-[a-z]+"))
            #expect(try /[0-9]{3}-[a-z]+/.wholeMatch(in: s) != nil)
        }
    }

    @Test("a string failure shrinks and prints quoted")
    func stringShrinks() throws {
        let drawn = try minimalExample { tc in
            let s = try tc.draw(.string(of: .ascii), named: "s")
            if s.contains("x") {
                throw Failed()
            }
        }
        #expect(drawn == [#"let s = "x""#])
    }

    @Test("closure generators compose and print their value")
    func composite() throws {
        struct Point: Equatable { var x: Int; var y: Int }
        let points = Gen { tc in
            Point(x: try tc.draw(.int(in: 0...10)), y: try tc.draw(.int(in: 0...10)))
        }
        let drawn = try minimalExample { tc in
            let p = try tc.draw(points, named: "p")
            if p.x + p.y > 5 {
                throw Failed()
            }
        }
        #expect(drawn == ["let p = Point(x: 0, y: 6)"])
    }

    @Test("flatMap draws from the derived generator")
    func flatMap() throws {
        try Property.check(settings: isolated) { tc in
            let (n, xs) = try tc.draw(
                Gen.int(in: 0...5).flatMap { n in
                    Gen.array(of: .int(), count: n...n).map { (n, $0) }
                }
            )
            #expect(xs.count == n)
        }
    }

    @Test("bytes and characters")
    func bytesAndCharacters() throws {
        try Property.check(settings: isolated) { tc in
            let bytes = try tc.draw(.bytes(count: 1...8))
            #expect((1...8).contains(bytes.count))
            let c = try tc.draw(.character(of: .characters("xyz")))
            #expect("xyz".contains(c))
        }
    }
}

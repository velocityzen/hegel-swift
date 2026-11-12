import HegelTesting
import Testing

/// The lines a failing property's report shows for its draws.
private func drawnLines(_ body: @escaping (TestCase) throws -> Void) throws -> [String] {
    let settings = Settings(derandomize: true, database: .disabled)
    let failure = try #require(try Property.run(settings: settings, body).failure)
    return failure.counterexamples[0].drawn
}

private let three = Gen.int(in: 3...3)

@Suite("#draw")
struct DrawMacroTests {
    @Test("is named after the binding it initializes")
    func namesTheBinding() throws {
        let drawn = try drawnLines { tc in
            let n = try #draw(three, from: tc)
            var count = try #draw(three, from: tc)
            count += n
            let typed: Int = try #draw(three, from: tc)
            _ = typed
            throw Failed()
        }
        #expect(drawn == ["let n = 3", "let count = 3", "let typed = 3"])
    }

    @Test("names each binding of a multi-binding declaration")
    func multipleBindings() throws {
        let drawn = try drawnLines { tc in
            let a = try #draw(three, from: tc), b = try #draw(three, from: tc)
            _ = (a, b)
            throw Failed()
        }
        #expect(drawn == ["let a = 3", "let b = 3"])
    }

    @Test("is unnamed outside a plain binding")
    func unnamed() throws {
        let drawn = try drawnLines { tc in
            let (a, b) = (try #draw(three, from: tc), 0)
            let xs = try [1].map { _ in try #draw(three, from: tc) }
            _ = try #draw(three, from: tc)
            _ = (a, b, xs)
            throw Failed()
        }
        #expect(drawn == ["let draw_1 = 3", "let draw_2 = 3", "let draw_3 = 3"])
    }

    @Test("nested in an initializer, takes that binding's name")
    func nestedInInitializer() throws {
        let drawn = try drawnLines { tc in
            let xs = [try #draw(three, from: tc)]
            _ = xs
            throw Failed()
        }
        #expect(drawn == ["let xs = 3"])
    }

    @Test("an explicit tc.draw name is unaffected")
    func explicitName() throws {
        let drawn = try drawnLines { tc in
            let n = try #draw(three, from: tc)
            let m = try tc.draw(three, named: "chosen")
            _ = (n, m)
            throw Failed()
        }
        #expect(drawn == ["let n = 3", "let chosen = 3"])
    }

    @Test(".hegel", .hegel(database: .disabled))
    func inAProperty() throws {
        let failure = #expect(throws: HegelTestFailure.self) {
            try property { tc in
                let xs = try #draw(.array(of: .int(in: 0...9)), from: tc)
                if xs.count > 1 {
                    throw Failed()
                }
            }
        }
        #expect(failure?.description.contains("let xs = [0, 0]") == true)
    }
}

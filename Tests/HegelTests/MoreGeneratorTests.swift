import Foundation
import Testing

@testable import Hegel

@Suite("Dates and times")
struct TimeGeneratorTests {
    @Test("dates stay in range and shrink to the bound nearest 2000")
    func dates() throws {
        let range =
            CalendarDate(year: 2010, month: 1, day: 1)...CalendarDate(year: 2030, month: 6, day: 30)
        try Property.check(settings: isolated) { tc in
            let date = try tc.draw(.calendarDate(in: range))
            #expect(range.contains(date))
        }
        let drawn = try minimalExample { tc in
            let date = try tc.draw(.calendarDate(), named: "date")
            if date.day == 31 {
                throw Failed()
            }
        }
        #expect(drawn == ["let date = 1999-12-31"])
    }

    @Test("days since the epoch round-trip")
    func dayArithmetic() throws {
        #expect(CalendarDate(year: 1970, month: 1, day: 1).daysSinceEpoch == 0)
        #expect(CalendarDate(year: 2000, month: 3, day: 1).daysSinceEpoch == 11_017)
        #expect(CalendarDate(year: 1969, month: 12, day: 31).daysSinceEpoch == -1)
        try Property.check(settings: isolated) { tc in
            let date = try tc.draw(.calendarDate(), named: "date")
            #expect(CalendarDate(daysSinceEpoch: date.daysSinceEpoch) == date)
        }
    }

    @Test("times shrink toward midnight and print in ISO 8601")
    func times() throws {
        let drawn = try minimalExample { tc in
            let time = try tc.draw(.timeOfDay(), named: "time")
            if time >= TimeOfDay(hour: 12, minute: 30) {
                throw Failed()
            }
        }
        #expect(drawn == ["let time = 12:30:00"])
        #expect(
            TimeOfDay(hour: 1, minute: 2, second: 3, nanosecond: 250_000_000).description
                == "01:02:03.25"
        )
    }

    @Test("datetimes stay in range")
    func dateTimes() throws {
        let start = LocalDateTime(
            date: CalendarDate(year: 2024, month: 2, day: 28),
            time: TimeOfDay(hour: 23)
        )
        let end = LocalDateTime(
            date: CalendarDate(year: 2024, month: 3, day: 1),
            time: TimeOfDay(hour: 1)
        )
        try Property.check(settings: isolated) { tc in
            let value = try tc.draw(.localDateTime(in: start...end))
            #expect((start...end).contains(value))
        }
    }

    @Test("Foundation dates stay in range and convert through UTC")
    func foundationDates() throws {
        let lower = Date(timeIntervalSince1970: -86_400 * 3.5)
        let upper = Date(timeIntervalSince1970: 1_000_000_000.123)
        try Property.check(settings: isolated) { tc in
            let date = try tc.draw(.date(in: lower...upper))
            #expect((lower...upper).contains(date))
            let back = LocalDateTime(utc: date).utcInstant
            #expect(abs(back.timeIntervalSince(date)) < 1e-6)
        }
        let drawn = try minimalExample { tc in
            _ = try tc.draw(Gen.date(), named: "date")
            throw Failed()
        }
        #expect(drawn == ["let date = 2000-01-01 00:00:00 +0000"])
    }
}

@Suite("Identifiers")
struct IdentifierGeneratorTests {
    @Test("versioned UUIDs set the version and variant")
    func uuids() throws {
        try Property.check(settings: isolated) { tc in
            let id = try tc.draw(.uuid(version: 4)).uuid
            #expect(id.6 >> 4 == 4)
            #expect(id.8 >> 6 == 0b10)
            let any = try tc.draw(.uuid())
            #expect(any != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)))
        }
    }

    @Test("IPv4 addresses shrink and print dotted")
    func ipv4() throws {
        let drawn = try minimalExample { tc in
            let address = try tc.draw(.ipv4, named: "address")
            if address.bytes[0] >= 10 {
                throw Failed()
            }
        }
        #expect(drawn == ["let address = 10.0.0.0"])
    }

    @Test("IPv6 addresses print as RFC 5952 says")
    func ipv6Text() {
        func address(_ groups: [UInt16]) -> String {
            IPv6Address(bytes: groups.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xff)] }).description
        }
        #expect(address([0, 0, 0, 0, 0, 0, 0, 0]) == "::")
        #expect(address([0, 0, 0, 0, 0, 0, 0, 1]) == "::1")
        #expect(address([0x2001, 0xdb8, 0, 0, 0, 0, 0, 1]) == "2001:db8::1")
        #expect(address([1, 0, 0, 2, 0, 0, 0, 3]) == "1:0:0:2::3")
        #expect(address([1, 0, 0, 2, 0, 0, 3, 4]) == "1::2:0:0:3:4")
        #expect(address([1, 0, 2, 3, 4, 5, 6, 7]) == "1:0:2:3:4:5:6:7")
        #expect(address([0, 0, 0, 0, 0, 0xffff, 0xc000, 0x0201]) == "::ffff:192.0.2.1")
    }

    @Test("IPv6 addresses are drawn")
    func ipv6() throws {
        let drawn = try minimalExample { tc in
            let address = try tc.draw(.ipv6, named: "address")
            if address.bytes[15] != 0 {
                throw Failed()
            }
        }
        #expect(drawn == ["let address = ::1"])
    }
}

@Suite("Grammars")
struct GrammarGeneratorTests {
    static let arithmetic = #"""
        start: expr
        expr: NUMBER | expr OP expr | "(" expr ")"
        OP: "+" | "-" | "*"
        NUMBER: /[0-9]/
        """#

    @Test("strings follow the grammar and shrink inside it")
    func arithmetic() throws {
        try Property.check(settings: isolated) { tc in
            let text = try tc.draw(.grammar(Self.arithmetic))
            #expect(!text.isEmpty)
            #expect(text.allSatisfy { "0123456789+-*()".contains($0) })
        }
        let drawn = try minimalExample { tc in
            let text = try tc.draw(.grammar(Self.arithmetic), named: "text")
            if text.contains("*") {
                throw Failed()
            }
        }
        #expect(drawn == [#"let text = "0*0""#])
    }

    @Test("declared terminals take values from their generators")
    func terminals() throws {
        let grammar = Gen.grammar(
            #"""
            start: NAME ("," NAME)*
            %declare NAME
            """#,
            terminals: ["NAME": .element(of: ["x", "y"])]
        )
        try Property.check(settings: isolated) { tc in
            let text = try tc.draw(grammar)
            let names = text.split(separator: ",", omittingEmptySubsequences: false)
            #expect(names.allSatisfy { $0 == "x" || $0 == "y" })
        }
    }

    @Test("imports come from the given files, or Lark's bundled ones")
    func imports() throws {
        let grammar = Gen.grammar(
            #"""
            start: WORD "=" DIGIT
            %import lib.words.WORD
            %import common.DIGIT
            """#,
            imports: ["lib/words.lark": #"WORD: "a" | "b""#]
        )
        try Property.check(settings: isolated) { tc in
            let text = try tc.draw(grammar)
            #expect(["a=", "b="].contains(String(text.dropLast())))
        }
    }

    @Test("a grammar that doesn't compile is a usage error")
    func invalid() {
        #expect(throws: HegelError.self) {
            try Property.run(settings: isolated) { tc in
                _ = try tc.draw(.grammar("start: undefined_rule"))
            }
        }
    }
}

@testable import Hegel
import Testing

@Suite("count-gated reach claims")
struct ReachAfterTests {
    @Test("a run judges every plain claim and exactly the gated claims its count is due for")
    func claimsToJudge() throws {
        let label = Gen.oneOf(.string(), Gen.int(in: 0...5).map { "label \($0)" })
        try Property.check(settings: isolated) { tc in
            let labels = try tc.draw(.array(of: label), named: "labels")
            let gated = try tc.draw(
                .dictionary(keys: .int(), values: .array(of: label)),
                named: "gated"
            )
            let passingCases = try tc.draw(.int(), named: "passingCases")

            let judged = Property.reachClaims(labels, after: gated, passingCases: passingCases)

            let due = Set(gated.filter { $0.key <= passingCases }.values.joined())
            #expect(Set(judged) == Set(labels).union(due))
            #expect(Set(judged).count == judged.count)
            var seen = Set<String>()
            let plain = labels.filter { seen.insert($0).inserted }
            #expect(Array(judged.prefix(plain.count)) == plain)
        }
    }
}

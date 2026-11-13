import HegelTesting
import Testing

@Suite("reach claims", .hegel(database: .disabled))
struct HegelReachTests {
    @Test(.capturingIssues, .hegel)
    func unmetClaimIsAnIssue() throws {
        let issues = try capture {
            try property(reaching: ["huge"]) { tc in
                let n = try tc.draw(.int(in: 0...100), named: "n")
                if n > 1000 {
                    try tc.event("huge")
                }
            }
        }
        try #require(issues.count == 1)
        #expect(issues[0].commentText.hasPrefix("Unreached: "))
        #expect(issues[0].commentText.contains("\"huge\""))
    }

    @Test(.capturingIssues, .hegel)
    func metClaimIsNoIssue() async throws {
        let issues = try await capture {
            try await property(reaching: ["big"]) { tc in
                let n = try tc.draw(.int(in: 0...100), named: "n")
                if n > 50 {
                    try tc.event("big")
                }
                await Task.yield()
            }
        }
        #expect(issues.isEmpty)
    }
}

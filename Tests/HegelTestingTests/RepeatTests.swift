import HegelTesting
import Testing

@Suite("repeat and concurrently", .hegel(database: .disabled))
struct HegelRepeatTests {
    @Test(.capturingIssues, .hegel)
    func repeatReportsTheShrunkExpectation() throws {
        let issues = try capture {
            try property { tc in
                var total = 0
                try tc.repeat { tc in
                    total += try tc.draw(.int(in: 0...10), named: "n")
                    #expect(total <= 15)
                }
            }
        }
        try #require(issues.count == 1)
        let comment = issues[0].commentText
        #expect(comment.contains("// Repetition #2"))
        #expect(!comment.contains("// Repetition #3"))
    }

    @Test(.capturingIssues, .hegel)
    func concurrentlyReportsTheShrunkExpectation() async throws {
        let issues = try await capture {
            try await property { tc in
                _ = try await tc.concurrently(workers: 2) { worker, tc in
                    let n = try tc.draw(.int(in: 0...10), named: "n")
                    #expect(worker == 0 || n <= 3)
                }
            }
        }
        try #require(issues.count == 1)
        // The workers draw concurrently, so worker 1's value may be named
        // `n` or `n_2` depending on which worker draws first.
        #expect(issues[0].commentText.contains(/\[worker 1 [^\]]*\] let n(_2)? = 4/))
    }
}

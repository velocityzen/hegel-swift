import CHegel

extension TestCase {
    /// Runs `body` with fault injection paused, for a check that must see
    /// the system under test without a fault landing in the middle of it.
    ///
    /// Inside [Antithesis](https://antithesis.com/), this asks the fuzzer to
    /// stop injecting faults before `body` and to resume after it, by
    /// running the program named in `ANTITHESIS_FAULT_CONTROL` with
    /// `--pause` and `--unpause`. Outside Antithesis, where that variable is
    /// unset, it just runs `body`.
    ///
    /// Throws a usage error when the fault-control program exists but
    /// cannot be run or fails. When `body` throws, its error is the one
    /// rethrown.
    public func withFaultsPaused<Result>(_ body: () throws -> Result) throws -> Result {
        guard explicit == nil else {
            return try body()
        }
        try pauseFaults()
        let result: Result
        do {
            result = try body()
        } catch {
            try? unpauseFaults()
            throw error
        }
        try unpauseFaults()
        return result
    }

    /// Runs async `body` with fault injection paused. See the synchronous
    /// `withFaultsPaused(_:)`.
    public func withFaultsPaused<Result>(_ body: () async throws -> Result) async throws -> Result {
        guard explicit == nil else {
            return try await body()
        }
        try pauseFaults()
        let result: Result
        do {
            result = try await body()
        } catch {
            try? unpauseFaults()
            throw error
        }
        try unpauseFaults()
        return result
    }

    func pauseFaults() throws {
        try call { hegel_pause_faults($0, raw) }
    }

    func unpauseFaults() throws {
        try call { hegel_unpause_faults($0, raw) }
    }
}

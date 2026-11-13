import Synchronization

/// A progress signal for `TestCase.withStallDetection(after:_:)`: the work
/// under test calls `beat()` at each step it makes, such as a read, a
/// finished transform or a delivered value. It tells a slow test case, which
/// keeps beating, from a stuck one.
public final class Heartbeat: Sendable {
    private let start = ContinuousClock.now
    private let beats = Atomic<Int>(0)
    /// When the last beat was, in nanoseconds since `start`.
    private let lastBeat = Atomic<Int64>(0)
    /// The longest gap between two beats so far, in nanoseconds.
    private let longestBeatGap = Atomic<Int64>(0)

    init() {}

    /// The number of beats so far.
    public var count: Int {
        beats.load(ordering: .relaxed)
    }

    /// Records a step of progress.
    public func beat() {
        let now = elapsed()
        let previous = lastBeat.exchange(now, ordering: .acquiringAndReleasing)
        raiseLongestGap(to: now - previous)
        beats.add(1, ordering: .relaxed)
    }

    /// Starts the clock over without counting a beat, when the work starts
    /// running: the time its task waited to be scheduled is not the work's.
    func restart() {
        lastBeat.store(elapsed(), ordering: .releasing)
    }

    /// The time since the last beat, or since the start before the first.
    var sinceLastBeat: Duration {
        .nanoseconds(elapsed() - lastBeat.load(ordering: .acquiring))
    }

    /// The longest the work went without a beat, counting the time since
    /// the last one.
    var longestGap: Duration {
        max(.nanoseconds(longestBeatGap.load(ordering: .acquiring)), sinceLastBeat)
    }

    private func elapsed() -> Int64 {
        let (seconds, attoseconds) = start.duration(to: .now).components
        return seconds * 1_000_000_000 + attoseconds / 1_000_000_000
    }

    private func raiseLongestGap(to gap: Int64) {
        var current = longestBeatGap.load(ordering: .relaxed)
        while gap > current {
            let (exchanged, original) = longestBeatGap.compareExchange(
                expected: current,
                desired: gap,
                ordering: .acquiringAndReleasing
            )
            if exchanged {
                return
            }
            current = original
        }
    }
}

/// The failure of a test case whose work stopped making progress: its
/// heartbeat did not beat for `limit`.
///
/// Stalls at different `withStallDetection` calls are different bugs, so
/// the origin is the call's location.
public struct Stalled: Error, FailureOrigin, CustomStringConvertible {
    /// How long the work went without a beat.
    public let limit: Duration
    /// How many beats it made before it stalled.
    public let beats: Int
    /// Where `withStallDetection` was called, as `file:line`.
    public let location: String

    public var failureOrigin: String {
        "Stalled at \(location)"
    }

    public var description: String {
        "Stalled: no progress for \(limit) after \(beats) heartbeat\(beats == 1 ? "" : "s"), at \(location)"
    }
}

extension TestCase {
    /// Runs `body` and turns a hang into a test failure: when `body`'s
    /// heartbeat goes `limit` without a beat, its task is cancelled and this
    /// throws `Stalled`.
    ///
    /// A lost wakeup makes async code wait forever, and Hegel can neither
    /// report nor shrink a test case that never returns. Call
    /// `heartbeat.beat()` at each step of progress, so slow work that keeps
    /// beating is not mistaken for stuck work:
    ///
    /// ```swift
    /// try await property { tc in
    ///     let jobs = try tc.draw(.array(of: .int()), named: "jobs")
    ///     let results = try await tc.withStallDetection(after: .seconds(5)) { heartbeat in
    ///         try await pool.run(jobs, onEach: { _ in heartbeat.beat() })
    ///     }
    ///     #expect(results.count == jobs.count)
    /// }
    /// ```
    ///
    /// `body` runs in a task of its own, which is abandoned rather than
    /// awaited once it stalls: a hang that ignores cancellation would
    /// otherwise hang the test too. So `body` can't use this test case;
    /// draw what it needs first.
    ///
    /// Every stalling shrink candidate would cost the full `limit`, so
    /// once a test case has stalled, the cases the engine tries while
    /// shrinking get a shorter limit: a few times the longest gap between
    /// beats seen in passing cases, and at least 100 milliseconds. The
    /// cases a failure report is built from still get the full `limit`, so
    /// a reported stall is always a full one.
    ///
    /// - Parameters:
    ///   - limit: How long `body` may go without a beat. Allow for a busy
    ///     machine: a few seconds for work whose steps take milliseconds.
    ///   - body: The work under test. Its value is returned, and its error
    ///     rethrown.
    public func withStallDetection<Value: Sendable>(
        after limit: Duration,
        fileID: String = #fileID,
        line: Int = #line,
        _ body: @escaping @Sendable (_ heartbeat: Heartbeat) async throws -> Value
    ) async throws -> Value {
        precondition(limit > .zero, "a stall limit must be positive")
        let effectiveLimit = run?.stalls.limit(for: limit) ?? limit
        let heartbeat = Heartbeat()
        let (outcomes, delivery) = AsyncStream.makeStream(of: StallOutcome<Value>.self)
        let work = Task.detached {
            heartbeat.restart()
            let result: Result<Value, any Error>
            do {
                result = .success(try await body(heartbeat))
            } catch {
                result = .failure(error)
            }
            // Measured here, before the waiting task is scheduled to read it.
            delivery.yield(.finished(result, longestGap: heartbeat.longestGap))
        }
        let watchdog = Task.detached {
            let poll = min(max(effectiveLimit / 20, .milliseconds(1)), .milliseconds(10))
            while !Task.isCancelled {
                try? await Task.sleep(for: poll)
                if heartbeat.sinceLastBeat >= effectiveLimit {
                    delivery.yield(.stalled)
                    return
                }
            }
        }
        let outcome = await withTaskCancellationHandler {
            var iterator = outcomes.makeAsyncIterator()
            return await iterator.next()
        } onCancel: {
            work.cancel()
        }
        watchdog.cancel()
        switch outcome {
            case .finished(let result, let longestGap)?:
                run?.stalls.record(longestGap)
                return try result.get()
            case .stalled?:
                work.cancel()
                run?.stalls.noteStall()
                throw Stalled(
                    limit: effectiveLimit,
                    beats: heartbeat.count,
                    location: "\(fileID):\(line)"
                )
            case nil:
                // The waiting task was cancelled, which ends the stream.
                work.cancel()
                throw CancellationError()
        }
    }
}

private enum StallOutcome<Value: Sendable>: Sendable {
    case finished(Result<Value, any Error>, longestGap: Duration)
    case stalled
}

/// What one property run has learned about its stalls: the longest gap
/// between heartbeats in a passing test case, and whether any case stalled.
final class StallLog: Sendable {
    /// A shortened limit is this many times the longest passing gap.
    static let shrinkFactor = 4
    /// And never shorter than this.
    static let shrinkFloor: Duration = .milliseconds(100)

    private struct State {
        var longestPassingGap: Duration?
        var sawStall = false
    }

    private let state = Mutex(State())

    /// The limit for a test case that is not reported: `full` until a case
    /// has stalled and a passing case has measured its heartbeat, then a few
    /// times the longest passing gap.
    func shrinkLimit(_ full: Duration) -> Duration {
        state.withLock { state in
            guard state.sawStall, let gap = state.longestPassingGap else {
                return full
            }
            return min(full, max(Self.shrinkFloor, gap * Self.shrinkFactor))
        }
    }

    func noteStall() {
        state.withLock { $0.sawStall = true }
    }

    func recordPassing(_ gap: Duration) {
        state.withLock { state in
            state.longestPassingGap = max(state.longestPassingGap ?? .zero, gap)
        }
    }
}

/// One test case's view of its run's `StallLog`. Shared by the case's
/// handles: its clones and blocks.
final class CaseStalls: Sendable {
    private let log: StallLog
    /// Whether a failure report can be built from this case, which then
    /// always gets the full limit.
    private let reported: Bool
    /// The longest heartbeat gap of this case's finished stall checks.
    private let longestGap = Mutex<Duration?>(nil)

    init(log: StallLog, reported: Bool) {
        self.log = log
        self.reported = reported
    }

    func limit(for full: Duration) -> Duration {
        reported ? full : log.shrinkLimit(full)
    }

    func record(_ gap: Duration) {
        longestGap.withLock { $0 = max($0 ?? .zero, gap) }
    }

    func noteStall() {
        log.noteStall()
    }

    /// Adds this case's gaps to the log, once it has passed.
    func commitPassing() {
        if let gap = longestGap.withLock({ $0 }) {
            log.recordPassing(gap)
        }
    }
}

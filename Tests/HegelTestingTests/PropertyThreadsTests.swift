import Dispatch
import Hegel
import Synchronization
import Testing

@testable import HegelTesting

/// Executors one to eight threads wide, reused across test cases: their
/// threads live as long as the process.
private let executors = (1...8).map { PropertyThreads(width: $0) }

/// An executor of a task's own, one thread wide.
private let ownExecutor = PropertyThreads(width: 1)

/// What the tasks on an executor saw, shared between them.
private final class Occupancy: Sendable {
    struct Seen {
        /// Tasks holding a thread now.
        var holding = 0
        /// The most tasks that held a thread at once.
        var most = 0
        /// Times a task ran on a thread not the executor's.
        var offThreads = 0
        /// Tasks that waited in vain for `busy` tasks to hold a thread at
        /// once.
        var starved = 0
        var finished = 0
    }

    private let state = Mutex(Seen())
    /// Opened when `busy` tasks hold a thread at once.
    private let peaked = DispatchSemaphore(value: 0)
    private let busy: Int
    private let tasks: Int

    init(busy: Int, tasks: Int) {
        self.busy = busy
        self.tasks = tasks
    }

    var seen: Seen { state.withLock { $0 } }

    /// Runs a task on `executor`, suspending `yields` times, each a job of
    /// its own, then holding its thread, as a synchronous property does,
    /// until `busy` tasks hold one at once.
    func run(on executor: PropertyThreads, yields: Int) async {
        for _ in 0..<yields {
            check(executor)
            await Task.yield()
        }
        check(executor)
        hold()
    }

    /// Blocks the calling thread until `busy` tasks hold one at once.
    private func hold() {
        let opens = state.withLock { seen in
            seen.holding += 1
            seen.most = max(seen.most, seen.holding)
            return seen.holding == busy
        }
        if opens {
            for _ in 0..<tasks {
                peaked.signal()
            }
        }
        let timedOut = peaked.wait(timeout: .now() + .seconds(10)) == .timedOut
        state.withLock { seen in
            seen.holding -= 1
            seen.finished += 1
            if timedOut {
                seen.starved += 1
            }
        }
    }

    private func check(_ executor: PropertyThreads) {
        if !executor.ownsCurrentThread {
            state.withLock { $0.offThreads += 1 }
        }
    }
}

@Suite("Hegel's threads", .hegel)
struct PropertyThreadsTests {
    @Test func runEveryJobOnAtMostTheirWidthOfThreads() async throws {
        try await property(reaching: ["more tasks than threads", "every thread busy at once"]) {
            tc in
            let width = try tc.draw(.int(in: 1...executors.count), named: "width")
            let executor = executors[width - 1]
            // Each task's suspensions before it holds its thread.
            let yields = try tc.draw(.array(of: .int(in: 0...3), count: 0...24), named: "yields")
            // A correct executor runs `width` of them at once, or all of
            // them if fewer.
            let busy = min(yields.count, width)
            let occupancy = Occupancy(busy: busy, tasks: yields.count)
            await withTaskGroup { group in
                for count in yields {
                    group.addTask {
                        await withTaskExecutorPreference(executor) {
                            await occupancy.run(on: executor, yields: count)
                        }
                    }
                }
            }
            let seen = occupancy.seen
            #expect(seen.finished == yields.count)
            #expect(seen.offThreads == 0, "tasks ran off the executor's threads")
            #expect(seen.most == busy, "\(seen.most) tasks held a thread at once")
            #expect(seen.starved == 0, "\(seen.starved) tasks waited for a thread in vain")
            if yields.count > width {
                try tc.event("more tasks than threads")
            }
            if width > 1, busy == width {
                try tc.event("every thread busy at once")
            }
        }
    }

    @Test func runASynchronousTest() throws {
        #expect(PropertyThreads.shared.ownsCurrentThread)
        try property { tc in
            _ = try tc.draw(.int(), named: "n")
            #expect(PropertyThreads.shared.ownsCurrentThread)
        }
    }

    @Test func handAnAsyncPropertyToTheCooperativePool() async throws {
        #expect(PropertyThreads.shared.isPreferred)
        try await property { tc in
            let yields = try tc.draw(.int(in: 0...3), named: "yields")
            for _ in 0..<yields {
                #expect(!PropertyThreads.shared.ownsCurrentThread)
                await Task.yield()
            }
            #expect(!PropertyThreads.shared.ownsCurrentThread)
            #expect(!PropertyThreads.shared.isPreferred)
        }
        #expect(PropertyThreads.shared.isPreferred)
    }

    @Test func leaveATaskItsOwnExecutor() async throws {
        let test = try #require(Test.current)
        try await withTaskExecutorPreference(ownExecutor) {
            try await HegelTrait.hegel.provideScope(for: test, testCase: nil) {
                #expect(ownExecutor.isPreferred)
                try property { tc in
                    _ = try tc.draw(.int(), named: "n")
                    #expect(ownExecutor.ownsCurrentThread)
                }
                try await property { tc in
                    _ = try tc.draw(.int(), named: "n")
                    #expect(ownExecutor.ownsCurrentThread)
                    await Task.yield()
                    #expect(ownExecutor.ownsCurrentThread)
                }
            }
        }
    }
}

/// Not under `.hegel`, so that this test's own task runs on the cooperative
/// pool.
@Suite("synchronous properties and the cooperative pool")
struct CooperativePoolTests {
    @Test func synchronousPropertiesLeaveTheCooperativePoolFree() async throws {
        let test = try #require(Test.current)
        let width = PropertyThreads.shared.width
        let holding = Atomic(0)
        let offThreads = Atomic(0)
        let starved = Atomic(0)
        let release = DispatchSemaphore(value: 0)
        // A property waits as long as the others take to start, which other
        // tests' properties on Hegel's threads can make slow.
        let trait = HegelTrait.hegel(
            testCases: 1,
            database: .disabled,
            suppressHealthChecks: .tooSlow
        )
        try await withThrowingTaskGroup { group in
            for _ in 0..<width {
                group.addTask {
                    try await trait.provideScope(for: test, testCase: nil) {
                        try property { tc in
                            _ = try tc.draw(.int(), named: "n")
                            if !PropertyThreads.shared.ownsCurrentThread {
                                offThreads.add(1, ordering: .relaxed)
                            }
                            holding.add(1, ordering: .relaxed)
                            // Holds its thread until this task has seen every
                            // property hold one.
                            if release.wait(timeout: .now() + .seconds(60)) == .timedOut {
                                starved.add(1, ordering: .relaxed)
                            }
                        }
                    }
                }
            }
            // The properties hold `width` threads: on the cooperative pool,
            // every thread it has, and this task couldn't run until they
            // gave up.
            while holding.load(ordering: .relaxed) < width {
                try await Task.sleep(for: .milliseconds(10))
            }
            // An async property runs meanwhile.
            let scope = HegelScope(
                settings: Settings(testCases: 50, database: .disabled),
                test: test
            )
            try await HegelScope.$current.withValue(scope) {
                try await property { tc in
                    _ = try tc.draw(.int(), named: "n")
                    await Task.yield()
                }
            }
            for _ in 0..<width {
                release.signal()
            }
            try await group.waitForAll()
        }
        #expect(offThreads.load(ordering: .relaxed) == 0)
        #expect(
            starved.load(ordering: .relaxed) == 0,
            "the synchronous properties held the cooperative pool"
        )
    }
}

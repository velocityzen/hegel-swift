import Dispatch
import Synchronization

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif os(Windows)
    import WinSDK
#endif

/// A task executor on threads of Hegel's own, for test code that blocks its
/// thread.
///
/// A synchronous `property` holds its thread for its whole run. Swift's
/// cooperative pool has one thread per core, so synchronous properties
/// running in parallel can hold every one of them. Async properties and
/// Swift Testing's own reporting then wait until one ends, long enough for
/// the TooSlow health check to fail the async properties. `.hegel` runs each
/// test under a preference for this executor, so a synchronous body blocks
/// one of these threads instead, and the async `property` hands its run
/// back to the cooperative pool.
///
/// It starts a thread when a job arrives and every thread is busy, up to
/// one per core: synchronous properties run as many at once as they did on
/// the cooperative pool. Its threads live as long as the process.
final class PropertyThreads: TaskExecutor {
    static let shared = PropertyThreads(width: ProcessInfo.processInfo.activeProcessorCount)

    /// The most threads it runs.
    let width: Int
    private let state = Mutex(State())
    /// Counts the jobs in `state.jobs`, for the threads to wait on.
    private let queued = DispatchSemaphore(value: 0)

    private struct State {
        var jobs: [UnownedJob] = []
        var threads = 0
        /// The threads not running a job, those starting included.
        var idle = 0
        var threadIDs: Set<UInt> = []
    }

    init(width: Int) {
        self.width = max(1, width)
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        let starts = state.withLock { state in
            state.jobs.append(job)
            guard state.jobs.count > state.idle, state.threads < width else {
                return false
            }
            state.threads += 1
            state.idle += 1
            return true
        }
        if starts {
            startThread { self.work() }
        }
        queued.signal()
    }

    /// Whether the calling thread is one of this executor's.
    var ownsCurrentThread: Bool {
        let id = currentThreadID()
        return state.withLock { $0.threadIDs.contains(id) }
    }

    /// Whether the current task prefers this executor.
    var isPreferred: Bool {
        PropertyThreads.currentPreference == asUnownedTaskExecutor()
    }

    /// The current task's executor preference, if it has one.
    static var currentPreference: UnownedTaskExecutor? {
        withUnsafeCurrentTask { $0?.unownedTaskExecutor }
    }

    private func work() {
        let executor = asUnownedTaskExecutor()
        let id = currentThreadID()
        state.withLock { _ = $0.threadIDs.insert(id) }
        while true {
            queued.wait()
            let job = state.withLock { state in
                state.idle -= 1
                return state.jobs.removeFirst()
            }
            job.runSynchronously(on: executor)
            state.withLock { $0.idle += 1 }
        }
    }
}

/// A thread's body, passed to it through its entry point's context.
private final class ThreadBody {
    let run: () -> Void

    init(_ run: @escaping () -> Void) {
        self.run = run
    }
}

private func threadMain(_ context: UnsafeMutableRawPointer?) {
    guard let context else {
        return
    }
    Unmanaged<ThreadBody>.fromOpaque(context).takeRetainedValue().run()
}

/// Starts `body` on a detached thread of its own, with a stack as large as
/// a main thread's: a property may recurse as deep as code on the main
/// thread.
private func startThread(_ body: @escaping () -> Void) {
    let context = Unmanaged.passRetained(ThreadBody(body)).toOpaque()
    let stackSize = 8 << 20
    #if os(Windows)
        let handle = CreateThread(
            nil,
            SIZE_T(stackSize),
            { context in
                threadMain(context)
                return 0
            },
            context,
            DWORD(STACK_SIZE_PARAM_IS_A_RESERVATION),
            nil
        )
        guard let handle else {
            fatalError("Hegel couldn't start a thread: error \(GetLastError())")
        }
        CloseHandle(handle)
    #else
        var attributes = pthread_attr_t()
        pthread_attr_init(&attributes)
        defer { pthread_attr_destroy(&attributes) }
        pthread_attr_setstacksize(&attributes, stackSize)
        pthread_attr_setdetachstate(&attributes, Int32(PTHREAD_CREATE_DETACHED))
        #if canImport(Darwin)
            var thread: pthread_t?
        #else
            var thread = pthread_t()
        #endif
        let result = pthread_create(
            &thread,
            &attributes,
            { context in
                threadMain(context)
                return nil
            },
            context
        )
        guard result == 0 else {
            fatalError("Hegel couldn't start a thread: error \(result)")
        }
    #endif
}

/// Identifies the calling thread among the threads alive.
private func currentThreadID() -> UInt {
    #if os(Windows)
        UInt(GetCurrentThreadId())
    #elseif canImport(Darwin)
        UInt(bitPattern: pthread_self())
    #else
        UInt(pthread_self())
    #endif
}

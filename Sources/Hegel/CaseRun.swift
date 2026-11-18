import Synchronization

/// What a test case shares with the run that drives it, across all of the
/// case's handles: its clones for `concurrently` workers and its blocks for
/// state machine steps.
final class CaseRun: Sendable {
    /// The run's stall log, as this case sees it.
    let stalls: CaseStalls
    /// Whether the engine uses the full diagnostic of this case if it
    /// fails, so its completion must carry one.
    let wantsDetail: Bool
    /// The labels this case recorded with `event`.
    private let eventLabels = Mutex<Set<String>>([])

    init(stalls: CaseStalls, wantsDetail: Bool = false) {
        self.stalls = stalls
        self.wantsDetail = wantsDetail
    }

    func recordEvent(_ label: String) {
        eventLabels.withLock { _ = $0.insert(label) }
    }

    var events: Set<String> {
        eventLabels.withLock { $0 }
    }
}

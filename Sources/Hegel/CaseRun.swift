import Synchronization

/// What a test case shares with the run that drives it, across all of the
/// case's handles: its clones for `concurrently` workers and its blocks for
/// state machine steps.
final class CaseRun: Sendable {
    /// The run's stall log, as this case sees it.
    let stalls: CaseStalls
    /// The labels this case recorded with `event`.
    private let eventLabels = Mutex<Set<String>>([])

    init(stalls: CaseStalls) {
        self.stalls = stalls
    }

    func recordEvent(_ label: String) {
        eventLabels.withLock { _ = $0.insert(label) }
    }

    var events: Set<String> {
        eventLabels.withLock { $0 }
    }
}

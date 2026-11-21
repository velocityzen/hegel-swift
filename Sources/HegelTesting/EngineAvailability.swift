internal import Hegel
internal import Testing

/// Skips the running test when this build has no engine, as on iOS, saying
/// why. Swift Testing reports the test as skipped rather than failed, so a
/// test target can keep its properties on every platform it builds for.
func skipWithoutEngine(_ sourceLocation: SourceLocation) throws {
    guard let platform = enginelessPlatform else {
        return
    }
    let reason = HegelError.engineUnavailable(platform: platform).description
    try Test.cancel(Comment(rawValue: reason), sourceLocation: sourceLocation)
}

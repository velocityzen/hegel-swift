/// Whether this build links libhegel, so that properties can run.
///
/// libhegel is built for macOS on Apple silicon, Linux and Windows. On iOS,
/// tvOS, watchOS, visionOS and Mac Catalyst (devices and simulators) Hegel
/// links a stub engine instead, so a test target that uses Hegel still builds
/// there. A property can't run: `Property.run` and `Property.check` throw
/// `HegelError.engineUnavailable`, and HegelTesting's `property` skips its
/// test.
public var isEngineAvailable: Bool {
    enginelessPlatform == nil
}

/// The platform this build has no engine for, or nil when libhegel is linked.
package let enginelessPlatform: String? = {
    #if HEGEL_NO_ENGINE
        #if targetEnvironment(macCatalyst)
            "Mac Catalyst"
        #elseif os(iOS)
            "iOS"
        #elseif os(tvOS)
            "tvOS"
        #elseif os(watchOS)
            "watchOS"
        #elseif os(visionOS)
            "visionOS"
        #elseif os(Android)
            "Android"
        #elseif os(WASI)
            "WASI"
        #elseif os(OpenBSD)
            "OpenBSD"
        #else
            "this platform"
        #endif
    #else
        nil
    #endif
}()

/// Throws `HegelError.engineUnavailable` when this build has no engine.
func requireEngine() throws(HegelError) {
    if let platform = enginelessPlatform {
        throw .engineUnavailable(platform: platform)
    }
}

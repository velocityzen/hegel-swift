import Synchronization

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#elseif os(Windows)
    import WinSDK
#endif

/// Which `hegel.toml` the engine reads.
///
/// libhegel loads its config once per process, the first time it resolves
/// settings: the file `HEGEL_CONFIG` names, or else the nearest `hegel.toml`
/// in the current directory or above. A test process that starts outside
/// the package, as Xcode's does, finds none, so the `.hegel` trait points
/// `HEGEL_CONFIG` at the package's own before then.
package final class EngineConfig: Sendable {
    /// Where the engine's `hegel.toml` comes from.
    package enum Source: Equatable, Sendable {
        /// The nearest `hegel.toml` in the current directory or above.
        case search
        /// The file a `HEGEL_CONFIG` set outside Hegel names.
        case environment(String)
        /// The file Hegel set `HEGEL_CONFIG` to.
        case chosen(String)
    }

    /// The variable libhegel reads.
    package static let variable = "HEGEL_CONFIG"

    /// The process's, over its real environment.
    package static let shared = EngineConfig(environment: .process)

    private struct State {
        /// Whether the engine may have loaded its config.
        var resolved = false
        /// Whether a choice was made.
        var decided = false
        /// The file Hegel set `HEGEL_CONFIG` to.
        var chosen: String?
    }

    private let state = Mutex(State())
    private let environment: Environment

    package init(environment: Environment) {
        self.environment = environment
    }

    /// Where the engine's `hegel.toml` comes from, or will.
    package var source: Source {
        state.withLock { source(in: $0) }
    }

    /// Points the engine at the `hegel.toml` at `config`, or, given nil,
    /// leaves it to search from the current directory. Only the first call
    /// decides, and only before the engine resolves settings. A
    /// `HEGEL_CONFIG` set outside Hegel stays as it is.
    ///
    /// Returns where the engine's `hegel.toml` comes from afterwards.
    @discardableResult
    package func choose(_ config: String?) -> Source {
        state.withLock { state in
            if !state.resolved, !state.decided {
                state.decided = true
                if let config, isUnset {
                    environment.set(Self.variable, config)
                    state.chosen = config
                }
            }
            return source(in: state)
        }
    }

    /// Marks that the engine is about to resolve settings, and may load its
    /// config: a later choice can't apply. A choice being made meanwhile
    /// sets the variable before the engine reads it.
    func resolving() {
        state.withLock { $0.resolved = true }
    }

    private var isUnset: Bool {
        environment.get(Self.variable)?.isEmpty ?? true
    }

    private func source(in state: State) -> Source {
        if let chosen = state.chosen {
            return .chosen(chosen)
        }
        if let value = environment.get(Self.variable), !value.isEmpty {
            return .environment(value)
        }
        return .search
    }
}

extension EngineConfig {
    /// Reads and writes environment variables.
    package struct Environment: Sendable {
        package var get: @Sendable (String) -> String?
        package var set: @Sendable (String, String) -> Void

        package init(
            get: @escaping @Sendable (String) -> String?,
            set: @escaping @Sendable (String, String) -> Void
        ) {
            self.get = get
            self.set = set
        }

        /// The process's environment, as libhegel reads it: through
        /// `getenv`, or on Windows `GetEnvironmentVariableW`, which doesn't
        /// see the C runtime's copy.
        package static let process = Environment(get: processVariable, set: setProcessVariable)
    }
}

private func processVariable(_ name: String) -> String? {
    #if os(Windows)
        name.withCString(encodedAs: UTF16.self) { name in
            let size = GetEnvironmentVariableW(name, nil, 0)
            guard size > 0 else {
                return nil
            }
            var buffer = [WCHAR](repeating: 0, count: Int(size))
            let count = GetEnvironmentVariableW(name, &buffer, size)
            return String(decoding: buffer.prefix(Int(count)), as: UTF16.self)
        }
    #else
        getenv(name).map { String(cString: $0) }
    #endif
}

private func setProcessVariable(_ name: String, _ value: String) {
    #if os(Windows)
        name.withCString(encodedAs: UTF16.self) { name in
            value.withCString(encodedAs: UTF16.self) { value in
                _ = SetEnvironmentVariableW(name, value)
            }
        }
    #else
        setenv(name, value, 1)
    #endif
}

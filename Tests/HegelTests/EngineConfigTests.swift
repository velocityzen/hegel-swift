import Foundation
import Synchronization
import Testing

@testable import Hegel

#if os(Windows)
    import WinSDK
#endif

/// An environment in memory that records each variable set.
private final class Variables: Sendable {
    private let values: Mutex<[String: String]>
    private let writes = Mutex<[String]>([])

    init(_ values: [String: String]) {
        self.values = Mutex(values)
    }

    var environment: EngineConfig.Environment {
        EngineConfig.Environment(
            get: { name in self.values.withLock { $0[name] } },
            set: { name, value in
                self.values.withLock { $0[name] = value }
                self.writes.withLock { $0.append("\(name)=\(value)") }
            }
        )
    }

    var written: [String] { writes.withLock { $0 } }
}

/// A path to a `hegel.toml`.
private let configPath = Gen.array(
    of: Gen.array(of: .element(of: Array("ab-_. éZ0")), count: 0...6).map { "d" + String($0) },
    count: 0...3
)
.map { "/" + ($0 + ["hegel.toml"]).joined(separator: "/") }

private enum Step: CustomStringConvertible {
    /// `.hegel` chooses a config, or leaves the engine searching.
    case choose(String?)
    /// The engine resolves settings.
    case resolve

    var description: String {
        switch self {
            case .choose(let path?): "choose(\(path))"
            case .choose(nil): "choose(nil)"
            case .resolve: "resolve"
        }
    }
}

@Suite("the engine's config")
struct EngineConfigTests {
    @Test("only the first choice before the engine resolves settings applies, over no HEGEL_CONFIG")
    func choosesOnceBeforeTheEngineLoadsItsConfig() throws {
        try Property.check(
            settings: isolated,
            reaching: [
                "set HEGEL_CONFIG", "kept a HEGEL_CONFIG set outside Hegel", "left the search",
                "chose too late", "chose again",
            ]
        ) { tc in
            let outside = try tc.draw(
                Gen<String?>.oneOf(.just(nil), .just(""), configPath.map { Optional($0) }),
                named: "outside"
            )
            let steps = try tc.draw(
                .array(
                    of: Gen<Step>.oneOf(
                        .just(.resolve),
                        Gen<String?>.oneOf(.just(nil), configPath.map { Optional($0) }).map(
                            Step.choose
                        )
                    ),
                    count: 0...6
                ),
                named: "steps"
            )
            let variables = Variables(outside.map { [EngineConfig.variable: $0] } ?? [:])
            let config = EngineConfig(environment: variables.environment)

            var resolved = false
            var decided = false
            var chosen: String?
            func expected() -> EngineConfig.Source {
                if let chosen {
                    return .chosen(chosen)
                }
                if let outside, !outside.isEmpty {
                    return .environment(outside)
                }
                return .search
            }
            for step in steps {
                switch step {
                    case .resolve:
                        config.resolving()
                        resolved = true
                    case .choose(let path):
                        let source = config.choose(path)
                        if resolved {
                            try tc.event("chose too late")
                        } else if decided {
                            try tc.event("chose again")
                        } else {
                            decided = true
                            if let path, outside?.isEmpty ?? true {
                                chosen = path
                                try tc.event("set HEGEL_CONFIG")
                            } else if path != nil {
                                try tc.event("kept a HEGEL_CONFIG set outside Hegel")
                            } else {
                                try tc.event("left the search")
                            }
                        }
                        #expect(source == expected())
                }
                #expect(config.source == expected())
                #expect(
                    variables.written == chosen.map { ["\(EngineConfig.variable)=\($0)"] } ?? []
                )
            }
        }
    }

    @Test("resolving settings ends the choice")
    func resolvingSettingsEndsTheChoice() throws {
        let variables = Variables([:])
        let config = EngineConfig(environment: variables.environment)
        _ = try EngineSettings(isolated, databaseKey: nil, location: nil, config: config)
        #expect(config.choose("/package/hegel.toml") == .search)
        #expect(variables.written.isEmpty)
    }

    #if os(Windows)
        /// libhegel reads `HEGEL_CONFIG` with `GetEnvironmentVariableW`, which
        /// doesn't see the C runtime's copy of the environment.
        @Test("a variable set on Windows is one libhegel reads")
        func setsTheProcessEnvironment() throws {
            try Property.check(settings: isolated) { tc in
                let value = try tc.draw(
                    .string(count: 0...20).map { "v" + $0.filter { $0 != "\u{0}" } },
                    named: "value"
                )
                let name = "HEGEL_SWIFT_TEST_\(UUID().uuidString.replacing("-", with: "_"))"
                let process = EngineConfig.Environment.process
                #expect(process.get(name) == nil)
                process.set(name, value)
                #expect(process.get(name) == value)
                let read = name.withCString(encodedAs: UTF16.self) { name in
                    var buffer = [UInt16](repeating: 0, count: 1024)
                    let count = GetEnvironmentVariableW(name, &buffer, DWORD(buffer.count))
                    return String(decoding: buffer.prefix(Int(count)), as: UTF16.self)
                }
                #expect(read == value)
            }
        }
    #endif
}

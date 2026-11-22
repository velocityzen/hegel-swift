import Hegel
import Synchronization
import Testing

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// The directory of the package a test belongs to, so that a run finds its
/// files from there rather than from the current directory.
///
/// `swift test` runs a package's tests from its directory, and the engine
/// finds `hegel.toml` and its database from the current directory. A test
/// run started elsewhere, as Xcode starts one, would read no `hegel.toml`
/// and store its failures where `swift test` doesn't look.
enum PackageDirectory {
    private static let found = Mutex<[String: String?]>([:])
    private static let chosen = Mutex<Set<String>>([])
    private static let checked = Mutex<Set<String>>([])

    /// Where the engine's `hegel.toml` came from, when it isn't the
    /// package's.
    enum Reading: Equatable {
        /// The nearest from the current directory, if any.
        case search(found: String?)
        /// The one a `HEGEL_CONFIG` set outside Hegel names.
        case environment(String)
        /// Another package's, which Hegel chose first.
        case chosen(String)
    }

    /// The package of the file at `filePath`: the nearest directory above
    /// it that holds a `Package.swift`, or nil when none does, as when the
    /// tests run on a machine other than the one that built them.
    static func of(_ filePath: String) -> String? {
        if let directory = found.withLock({ $0[filePath] }) {
            return directory
        }
        let directory = ancestors(of: filePath).first {
            exists(Settings.joinPath($0, "Package.swift"))
        }
        found.withLock { $0[filePath] = directory }
        return directory
    }

    /// The directories above `path`, nearest first, ending with its root.
    static func ancestors(of path: String) -> [String] {
        var directories: [String] = []
        var rest = Substring(path)
        while let cut = rest.lastIndex(where: isSeparator) {
            let parent = rest[..<cut]
            // The root keeps its separator: `/`, or a drive's `C:\`.
            if parent.isEmpty || parent.last == ":" {
                directories.append(String(rest[...cut]))
                break
            }
            directories.append(String(parent))
            rest = parent
        }
        return directories
    }

    /// The `hegel.toml` the engine reads in `directory`: the nearest one in
    /// it or above it.
    static func config(from directory: String) -> String? {
        ([directory] + ancestors(of: directory))
            .lazy
            .map { Settings.joinPath($0, "hegel.toml") }
            .first(where: exists)
    }

    /// The `hegel.toml` of the package in `package`: the nearest one in it
    /// or above it, from its real directory.
    static func ownConfig(of package: String) -> String? {
        // From the real directory, so that it walks up through its real
        // parents, as the engine does from the current directory.
        config(from: canonical(package))
    }

    /// Points the engine at the package's `hegel.toml`, once for each
    /// package, if the engine wouldn't find it from `currentDirectory`. The
    /// engine loads one for the whole process, so the first package with a
    /// `hegel.toml` decides.
    static func chooseConfig(
        package: String,
        currentDirectory: String = FileManager.default.currentDirectoryPath,
        engine: EngineConfig = .shared
    ) {
        guard chosen.withLock({ $0.insert(package).inserted }) else {
            return
        }
        guard let own = ownConfig(of: package) else {
            return
        }
        let found = config(from: canonical(currentDirectory))
        engine.choose(found == own ? nil : own)
    }

    /// The `hegel.toml` of the package in `package` when the engine doesn't
    /// read it, with where the engine's comes from instead.
    static func unseenConfig(
        package: String,
        currentDirectory: String,
        engine: EngineConfig.Source
    ) -> (config: String, reading: Reading)? {
        guard let own = ownConfig(of: package) else {
            return nil
        }
        let reading: Reading
        let read: String?
        switch engine {
            case .search:
                read = config(from: canonical(currentDirectory))
                reading = .search(found: read)
            case .environment(let path):
                // The engine opens a relative path from the current
                // directory.
                let absolute =
                    Settings.isAbsolutePath(path)
                    ? path : Settings.joinPath(currentDirectory, path)
                read = canonical(absolute)
                reading = .environment(path)
            case .chosen(let path):
                read = path
                reading = .chosen(path)
        }
        return read == own ? nil : (own, reading)
    }

    /// Warns, once for each package, when the engine doesn't read the
    /// package's `hegel.toml`: its profiles and default profile don't apply.
    static func warnIfConfigUnseen(
        package: String,
        currentDirectory: String = FileManager.default.currentDirectoryPath,
        engine: EngineConfig.Source = EngineConfig.shared.source,
        sourceLocation: SourceLocation
    ) {
        guard checked.withLock({ $0.insert(package).inserted }),
            let unseen = unseenConfig(
                package: package,
                currentDirectory: currentDirectory,
                engine: engine
            )
        else {
            return
        }
        let (reason, remedy) =
            switch unseen.reading {
                case .search(let found):
                    (
                        """
                        looking from the current directory, \(currentDirectory), the engine \
                        \(found.map { "reads \($0)" } ?? "finds none")
                        """,
                        " Set HEGEL_CONFIG to it to apply them."
                    )
                case .environment(let path):
                    ("HEGEL_CONFIG names \(path)", "")
                case .chosen(let path):
                    (
                        """
                        another package's tests chose \(path), and the engine reads one \
                        hegel.toml for the whole test process
                        """,
                        " Run these tests in a process of their own to apply them."
                    )
            }
        Issue.record(
            Comment(
                rawValue: """
                    Hegel doesn't read \(unseen.config): \(reason), so its profiles and \
                    default profile don't apply to these tests.\(remedy)
                    """
            ),
            severity: .warning,
            sourceLocation: sourceLocation
        )
    }

    private static func isSeparator(_ character: Character) -> Bool {
        character == "/" || character == Settings.pathSeparator
    }

    private static func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    /// `path` with its symbolic links resolved, in the platform's own form:
    /// on Windows, `C:\Users\…` rather than a file URL's `/C:/Users/…`.
    static func canonical(_ path: String) -> String {
        let resolved = URL(filePath: path).resolvingSymlinksInPath().path(percentEncoded: false)
        #if os(Windows)
            var native = Substring(resolved)
            if native.first == "/", native.dropFirst(2).first == ":" {
                native = native.dropFirst()
            }
            return String(native.map { $0 == "/" ? Settings.pathSeparator : $0 })
        #else
            return resolved
        #endif
    }
}

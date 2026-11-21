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
    private static let checked = Mutex<Set<String>>([])

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

    /// The `hegel.toml` of the package in `package` when the engine, looking
    /// from `currentDirectory`, doesn't read it, with the one it reads
    /// instead, if any.
    static func unseenConfig(
        package: String,
        currentDirectory: String
    ) -> (config: String, seen: String?)? {
        // From the real directories, so that each walks up through its real
        // parents, as the engine does from the current directory.
        guard let own = config(from: canonical(package)) else {
            return nil
        }
        let seen = config(from: canonical(currentDirectory))
        return seen == own ? nil : (own, seen)
    }

    /// Warns, once for each package, when the engine doesn't read the
    /// package's `hegel.toml`: its profiles and default profile don't apply.
    static func warnIfConfigUnseen(
        package: String,
        currentDirectory: String = FileManager.default.currentDirectoryPath,
        sourceLocation: SourceLocation
    ) {
        guard checked.withLock({ $0.insert(package).inserted }),
            let unseen = unseenConfig(package: package, currentDirectory: currentDirectory)
        else {
            return
        }
        let finds = unseen.seen.map { "reads \($0) instead" } ?? "finds none"
        Issue.record(
            Comment(
                rawValue: """
                    Hegel doesn't read \(unseen.config): the engine looks for hegel.toml \
                    from the current directory, \(currentDirectory), and \(finds). The \
                    profiles and default profile it sets don't apply to these tests. Run \
                    them from \(package), as `swift test` does.
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

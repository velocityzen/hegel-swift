import Foundation
import Hegel
import Synchronization
import Testing

@testable import HegelTesting

/// A file or directory name: never `.` or `..`, and on Windows, which
/// can't create one, never ending in a space or a dot.
private let pathComponent = Gen.array(of: .element(of: Array("ab-_. éZ0")), count: 0...6)
    .map { characters in
        var name = "d" + String(characters)
        #if os(Windows)
            while name.last == " " || name.last == "." {
                name.removeLast()
            }
        #endif
        return name
    }

/// `name` in the directory at `directory`.
private func file(_ name: String, in directory: String) -> String {
    Settings.joinPath(directory, name)
}

/// An environment in memory that records each value set.
private final class Variables: Sendable {
    private let values = Mutex<[String: String]>([:])
    private let writes = Mutex<[String]>([])

    var environment: EngineConfig.Environment {
        EngineConfig.Environment(
            get: { name in self.values.withLock { $0[name] } },
            set: { name, value in
                self.values.withLock { $0[name] = value }
                self.writes.withLock { $0.append(value) }
            }
        )
    }

    var written: [String] { writes.withLock { $0 } }
}

/// A fresh temporary directory to build a tree of directories in.
private struct Tree {
    let root: String

    init() throws {
        root =
            FileManager.default.temporaryDirectory
            .appendingPathComponent("hegel-tree-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    /// The directory at `names` below the root.
    func path(_ names: some Sequence<String>) -> String {
        ([root] + names).joined(separator: "/")
    }

    func makeDirectory(_ names: some Sequence<String>) throws {
        try FileManager.default.createDirectory(
            atPath: path(names),
            withIntermediateDirectories: true
        )
    }

    /// Creates the file `name` in the directory at `names`.
    func touch(_ name: String, in names: some Sequence<String>) throws {
        try makeDirectory(names)
        let file = path(names) + "/" + name
        guard FileManager.default.createFile(atPath: file, contents: Data()) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    func remove() {
        try? FileManager.default.removeItem(atPath: root)
    }
}

/// `path` with its symbolic links resolved, as the engine sees it.
private func real(_ path: String) -> String {
    PackageDirectory.canonical(path)
}

@Suite("package directory", .hegel)
struct PackageDirectoryTests {
    @Test func listsEveryDirectoryAboveAPath() throws {
        try property { tc in
            let names = try tc.draw(.array(of: pathComponent, count: 1...6), named: "names")
            let path = "/" + names.joined(separator: "/")
            let above = (0..<names.count).reversed().map {
                "/" + names[..<$0].joined(separator: "/")
            }
            #expect(PackageDirectory.ancestors(of: path) == above)
        }
    }

    @Test func resolvesAPathInThePlatformsOwnForm() throws {
        #if os(Windows)
            let claims: [String] = []
        #else
            let claims = ["through a link"]
        #endif
        try property(reaching: claims) { tc in
            let names = try tc.draw(.array(of: pathComponent, count: 0...4), named: "names")
            #if os(Windows)
                let throughLink = false
            #else
                let throughLink = try tc.draw(.bool(), named: "throughLink")
            #endif
            let tree = try Tree()
            defer { tree.remove() }
            try tree.makeDirectory(names)
            var path = tree.path(names)
            if throughLink {
                path = tree.root + "/link"
                try FileManager.default.createSymbolicLink(
                    atPath: path,
                    withDestinationPath: tree.path(names)
                )
                try tc.event("through a link")
            }

            let resolved = PackageDirectory.canonical(path)
            let separator = String(Settings.pathSeparator)
            #expect(FileManager.default.fileExists(atPath: resolved))
            #expect(Settings.isAbsolutePath(resolved))
            #expect(!resolved.hasSuffix(separator + "link"))
            #expect(resolved.hasSuffix(names.map { separator + $0 }.joined()))
            #if os(Windows)
                // A drive's path, such as `C:\Users\…`.
                #expect(resolved.dropFirst().first == ":")
                #expect(!resolved.contains("/"))
            #endif
        }
    }

    @Test func findsTheNearestPackageAboveAFile() throws {
        try property(reaching: ["no package", "nested packages"]) { tc in
            let names = try tc.draw(.array(of: pathComponent, count: 0...6), named: "names")
            // Whether the directory at each depth, the root's included,
            // holds a Package.swift.
            let packages = try tc.draw(
                .array(of: .bool(), count: (names.count + 1)...(names.count + 1)),
                named: "packages"
            )
            let tree = try Tree()
            defer { tree.remove() }
            try tree.makeDirectory(names)
            for (depth, isPackage) in packages.enumerated() where isPackage {
                try tree.touch("Package.swift", in: names.prefix(depth))
            }

            let file = tree.path(names) + "/File.swift"
            let nearest = packages.lastIndex(of: true).map { tree.path(names.prefix($0)) }
            // Nothing above the tree is a package.
            try #require(
                PackageDirectory.of(tree.root + "/File.swift")
                    == packages.first.flatMap { $0 ? tree.root : nil }
            )
            #expect(PackageDirectory.of(file) == nearest)
            if nearest == nil {
                try tc.event("no package")
            }
            if packages.filter({ $0 }).count > 1 {
                try tc.event("nested packages")
            }
        }
    }

    // Each claim needs a source and a tree to line up, so more cases than
    // the default.
    @Test(.hegel(testCases: 400))
    func tellsWhenTheEngineDoesntReadThePackagesConfig() throws {
        var claims = [
            "the engine finds none", "the engine finds another", "HEGEL_CONFIG names another",
            "HEGEL_CONFIG names a relative path", "another package's was chosen",
            "the engine reads it", "the package has none",
        ]
        #if !os(Windows)
            claims.append("the package is reached through a link")
        #endif
        try property(reaching: claims) { tc in
            // Two names, so that the two paths often share directories.
            let name = Gen.element(of: ["a", "b"])
            let package = try tc.draw(.array(of: name, count: 0...4), named: "package")
            let current = try tc.draw(.array(of: name, count: 0...4), named: "current")
            // Every directory either path passes through, nearest the root
            // first, and whether each holds a hegel.toml.
            let directories = Set(
                (0...package.count).map { Array(package.prefix($0)) }
                    + (0...current.count).map { Array(current.prefix($0)) }
            ).sorted { $0.lexicographicallyPrecedes($1) }
            let configs = try tc.draw(
                .array(of: .bool(), count: directories.count...directories.count),
                named: "configs"
            )
            // Where the engine's hegel.toml comes from: its search from the
            // current directory, or a file in one of the directories that
            // HEGEL_CONFIG names or Hegel chose for another package.
            let source = try tc.draw(
                .element(of: ["search", "HEGEL_CONFIG", "chosen"]),
                named: "source"
            )
            let named = try tc.draw(.element(of: directories), named: "named")
            let relative = try tc.draw(.bool(), named: "relative")
            #if os(Windows)
                let throughLink = false
            #else
                let throughLink = try tc.draw(.bool(), named: "throughLink")
            #endif
            let tree = try Tree()
            defer { tree.remove() }
            try tree.makeDirectory(package)
            try tree.makeDirectory(current)
            let holding = Set(zip(directories, configs).filter(\.1).map(\.0))
            for directory in holding {
                try tree.touch("hegel.toml", in: directory)
            }
            var packagePath = tree.path(package)
            if throughLink {
                packagePath = tree.root + "/link"
                try FileManager.default.createSymbolicLink(
                    atPath: packagePath,
                    withDestinationPath: tree.path(package)
                )
            }

            /// The hegel.toml nearest `names`, as the engine finds it.
            func nearest(_ names: [String]) -> String? {
                (0...names.count).reversed()
                    .map { Array(names.prefix($0)) }
                    .first(where: holding.contains)
                    .map { file("hegel.toml", in: real(tree.path($0))) }
            }
            let own = nearest(package)
            let namedConfig = file("hegel.toml", in: real(tree.path(named)))
            let engine: EngineConfig.Source
            let read: String?
            let reading: PackageDirectory.Reading
            switch source {
                case "search":
                    engine = .search
                    read = nearest(current)
                    reading = .search(found: read)
                case "HEGEL_CONFIG":
                    // The engine opens a relative path from the current
                    // directory.
                    let path =
                        relative && named.starts(with: current)
                        ? (named.dropFirst(current.count) + ["hegel.toml"]).joined(separator: "/")
                        : file("hegel.toml", in: tree.path(named))
                    engine = .environment(path)
                    read = namedConfig
                    reading = .environment(path)
                    if !Settings.isAbsolutePath(path) {
                        try tc.event("HEGEL_CONFIG names a relative path")
                    }
                default:
                    engine = .chosen(namedConfig)
                    read = namedConfig
                    reading = .chosen(namedConfig)
            }
            let unseen = PackageDirectory.unseenConfig(
                package: packagePath,
                currentDirectory: tree.path(current),
                engine: engine
            )

            if let own, own != read {
                #expect(unseen?.config == own)
                #expect(unseen?.reading == reading)
                switch reading {
                    case .search(found: nil): try tc.event("the engine finds none")
                    case .search: try tc.event("the engine finds another")
                    case .environment: try tc.event("HEGEL_CONFIG names another")
                    case .chosen: try tc.event("another package's was chosen")
                }
            } else {
                #expect(unseen == nil)
                try tc.event(own == nil ? "the package has none" : "the engine reads it")
            }
            if throughLink {
                try tc.event("the package is reached through a link")
            }
        }
    }

    @Test func pointsTheEngineAtThePackagesConfig() throws {
        try property(
            reaching: [
                "pointed the engine at it", "the engine finds it", "another package's applies",
                "no hegel.toml",
            ]
        ) { tc in
            let name = Gen.element(of: ["a", "b"])
            let first = try tc.draw(.array(of: name, count: 0...3), named: "first")
            let second = try tc.draw(.array(of: name, count: 0...3), named: "second")
            let current = try tc.draw(.array(of: name, count: 0...3), named: "current")
            let directories = Set(
                [first, second, current].flatMap { names in
                    (0...names.count).map { Array(names.prefix($0)) }
                }
            ).sorted { $0.lexicographicallyPrecedes($1) }
            let configs = try tc.draw(
                .array(of: .bool(), count: directories.count...directories.count),
                named: "configs"
            )
            let tree = try Tree()
            defer { tree.remove() }
            for names in [first, second, current] {
                try tree.makeDirectory(names)
            }
            let holding = Set(zip(directories, configs).filter(\.1).map(\.0))
            for directory in holding {
                try tree.touch("hegel.toml", in: directory)
            }
            func nearest(_ names: [String]) -> String? {
                (0...names.count).reversed()
                    .map { Array(names.prefix($0)) }
                    .first(where: holding.contains)
                    .map { file("hegel.toml", in: real(tree.path($0))) }
            }

            // Two packages' tests in one process, the first prepared first.
            let variables = Variables()
            let engine = EngineConfig(environment: variables.environment)
            for package in [first, second] {
                PackageDirectory.chooseConfig(
                    package: tree.path(package),
                    currentDirectory: tree.path(current),
                    engine: engine
                )
            }

            // The first package with a hegel.toml decides.
            let found = nearest(current)
            let (deciding, other) = nearest(first) == nil ? (second, first) : (first, second)
            let applied = nearest(deciding)
            #expect(variables.written == (applied == found ? [] : applied.map { [$0] } ?? []))
            func unseen(_ package: [String]) -> (config: String, reading: PackageDirectory.Reading)?
            {
                PackageDirectory.unseenConfig(
                    package: tree.path(package),
                    currentDirectory: tree.path(current),
                    engine: engine.source
                )
            }
            #expect(unseen(deciding) == nil)
            if let applied, let otherConfig = nearest(other), otherConfig != applied {
                #expect(unseen(other)?.config == otherConfig)
                #expect(
                    unseen(other)?.reading
                        == (applied == found ? .search(found: found) : .chosen(applied))
                )
                try tc.event("another package's applies")
            } else {
                #expect(unseen(other) == nil)
            }
            switch applied {
                case nil: try tc.event("no hegel.toml")
                case found: try tc.event("the engine finds it")
                default: try tc.event("pointed the engine at it")
            }
        }
    }

    @Test(.capturingIssues) func warnsOnceForEachPackage() throws {
        let tree = try Tree()
        defer { tree.remove() }
        for name in ["first", "second", "third"] {
            try tree.touch("hegel.toml", in: [name])
        }
        try tree.makeDirectory(["elsewhere"])
        try tree.makeDirectory(["first", "inner"])
        let elsewhere = tree.path(["elsewhere"])
        let chosen = file("hegel.toml", in: real(tree.path(["chosen"])))
        // Each package, where the engine's hegel.toml comes from, and what
        // the warning says of it.
        let packages: [(name: String, engine: EngineConfig.Source, says: String)] = [
            ("first", .search, elsewhere),
            ("second", .environment("custom.toml"), "HEGEL_CONFIG names custom.toml"),
            ("third", .chosen(chosen), chosen),
        ]

        let issues = capture {
            for package in packages {
                for _ in 0..<2 {
                    PackageDirectory.warnIfConfigUnseen(
                        package: tree.path([package.name]),
                        currentDirectory: elsewhere,
                        engine: package.engine,
                        sourceLocation: #_sourceLocation
                    )
                }
            }
            // A package whose hegel.toml the engine reads gets no warning.
            PackageDirectory.warnIfConfigUnseen(
                package: tree.path(["first", "inner"]),
                currentDirectory: tree.path(["first"]),
                engine: .search,
                sourceLocation: #_sourceLocation
            )
        }

        try #require(issues.count == packages.count)
        for (issue, package) in zip(issues, packages) {
            #expect(issue.severity == .warning)
            #expect(
                issue.commentText.contains(file("hegel.toml", in: real(tree.path([package.name]))))
            )
            #expect(issue.commentText.contains(package.says))
        }
    }

    /// The package's own hegel.toml defines the `package-config` profile,
    /// which the engine knows wherever the test process started.
    @Test(.hegel(profile: "package-config"))
    func readsThePackagesConfig() throws {
        try property { tc in
            _ = try tc.draw(.int(), named: "n")
        }
        let package = try #require(HegelScope.current?.settings.projectDirectory)
        let unseen = PackageDirectory.unseenConfig(
            package: package,
            currentDirectory: FileManager.default.currentDirectoryPath,
            engine: EngineConfig.shared.source
        )
        #expect(unseen == nil)
    }

    @Test func runsPropertiesInTheTestsPackage() throws {
        let scope = try #require(HegelScope.current)
        let directory = try #require(scope.settings.projectDirectory)
        let separator = String(Settings.pathSeparator)
        #expect(FileManager.default.fileExists(atPath: directory + separator + "Package.swift"))
        #expect(#filePath.hasPrefix(directory + separator))
    }

    @Test(.hegel(Settings(projectDirectory: "/elsewhere")))
    func keepsATestsOwnProjectDirectory() throws {
        #expect(HegelScope.current?.settings.projectDirectory == "/elsewhere")
    }
}

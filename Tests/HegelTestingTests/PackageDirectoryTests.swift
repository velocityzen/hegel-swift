import Foundation
import Hegel
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

    @Test func tellsWhenTheEngineDoesntReadThePackagesConfig() throws {
        var claims = [
            "the engine reads none", "the engine reads another", "the engine reads it",
            "the package has none",
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
            let seen = nearest(current)
            let unseen = PackageDirectory.unseenConfig(
                package: packagePath,
                currentDirectory: tree.path(current)
            )

            if let own, own != seen {
                #expect(unseen?.config == own)
                #expect(unseen?.seen == seen)
                try tc.event(seen == nil ? "the engine reads none" : "the engine reads another")
            } else {
                #expect(unseen == nil)
                try tc.event(own == nil ? "the package has none" : "the engine reads it")
            }
            if throughLink {
                try tc.event("the package is reached through a link")
            }
        }
    }

    @Test(.capturingIssues) func warnsOnceForEachPackage() throws {
        let tree = try Tree()
        defer { tree.remove() }
        try tree.touch("hegel.toml", in: ["package"])
        try tree.makeDirectory(["elsewhere"])
        try tree.makeDirectory(["package", "inner"])
        let package = tree.path(["package"])
        let elsewhere = tree.path(["elsewhere"])

        let issues = capture {
            for _ in 0..<2 {
                PackageDirectory.warnIfConfigUnseen(
                    package: package,
                    currentDirectory: elsewhere,
                    sourceLocation: #_sourceLocation
                )
            }
            // A package whose hegel.toml the engine reads gets no warning.
            PackageDirectory.warnIfConfigUnseen(
                package: tree.path(["package", "inner"]),
                currentDirectory: package,
                sourceLocation: #_sourceLocation
            )
        }

        try #require(issues.count == 1)
        #expect(issues[0].severity == .warning)
        #expect(issues[0].commentText.contains(file("hegel.toml", in: real(package))))
        #expect(issues[0].commentText.contains(elsewhere))
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

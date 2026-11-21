import Foundation
import Testing

@testable import Hegel

/// A file or directory name: never `.` or `..`.
private let pathComponent = Gen.array(of: .element(of: Array("ab-_. éZ0")), count: 0...6)
    .map { "d" + String($0) }

/// A path relative to the current directory.
private let relativePath = Gen.array(of: pathComponent, count: 1...3)
    .map { $0.joined(separator: "/") }

/// An absolute path.
private let absolutePath = relativePath.map { "/" + $0 }

@Suite("project directory")
struct ProjectDirectoryTests {
    @Test("a relative database resolves against the project directory, and nothing else moves")
    func anchorsARelativeDatabase() throws {
        let separator = String(Settings.pathSeparator)
        try Property.check(
            settings: isolated,
            reaching: ["the default location", "a relative path", "an absolute path", "disabled"]
        ) { tc in
            // The profiles disagree on the database: `ci` and `workload`
            // disable it.
            let profile = try tc.draw(
                .element(of: [nil, "development", "ci", "workload", "base"]),
                named: "profile"
            )
            let database = try tc.draw(
                Gen<Settings.Database?>.oneOf(
                    .just(nil),
                    .just(.default),
                    .just(.disabled),
                    relativePath.map { .path($0) },
                    absolutePath.map { .path($0) }
                ),
                named: "database"
            )
            let directory = try tc.draw(absolutePath, named: "directory")
            let settings = Settings(profile: profile, database: database)
            var inProject = settings
            inProject.projectDirectory = directory

            let resolved = try EngineSettings(settings, databaseKey: nil, location: nil).database
            let anchored = try EngineSettings(inProject, databaseKey: nil, location: nil).database

            switch resolved {
                case nil:
                    #expect(anchored == directory + separator + ".hegel/examples")
                    try tc.event("the default location")
                case let path? where path.isEmpty:
                    #expect(anchored == "")
                    try tc.event("disabled")
                case let path? where path.hasPrefix("/"):
                    #expect(anchored == path)
                    try tc.event("an absolute path")
                case let path?:
                    #expect(anchored == directory + separator + path)
                    try tc.event("a relative path")
            }
        }
    }

    @Test("a run stores its failures in the project directory and replays them from there")
    func storesFailuresInTheProject() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hegel-project-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: directory) }
        // `development` keeps the default database, where the `ci` profile
        // a CI server selects disables it.
        let settings = Settings(profile: "development", projectDirectory: directory)

        // Runs a property that fails for n >= 500 and returns the first n it
        // drew.
        func firstDraw() throws -> Int? {
            var first: Int?
            let outcome = try Property.run(settings: settings, databaseKey: "project") { tc in
                let n = try tc.draw(.int(), named: "n")
                first = first ?? n
                if n >= 500 {
                    throw Failed()
                }
            }
            #expect(outcome.failure != nil)
            return first
        }

        _ = try firstDraw()
        let stored = try FileManager.default.subpathsOfDirectory(
            atPath: directory + "/.hegel/examples"
        )
        #expect(!stored.isEmpty)
        #expect(try firstDraw() == 500)
    }
}

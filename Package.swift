// swift-tools-version: 6.3

import CompilerPluginSupport
import Foundation
import PackageDescription

// The libhegel release this package is built against. Updated, together
// with the checksums below, by Scripts/bump-libhegel.sh (run by the
// libhegel-bump workflow); do not edit by hand.
let libhegelVersion = "0.53.0"
let xcframeworkChecksum = "aee420be50f43fa3c6cb73fd3a1677cb85051e53ef0aff08b523882eb84e5053"
let artifactbundleChecksum = "36b0261fc19739f58b8409c3d58d84fb53b8a537ba861671a1f9bbc914782b99"

// libhegel ships as two binary targets: an XCFramework for macOS and a
// static-library artifact bundle for Linux and Windows. Releases of this
// package download them from the `libhegel-<version>` release of this
// repository. After Scripts/package-libhegel.sh, the local copies in
// Artifacts/ are used instead, so a checkout can build against a libhegel
// that is not released yet.
let packageDirectory = Context.packageDirectory
let releaseURL =
    "https://github.com/velocityzen/hegel-swift/releases/download/libhegel-\(libhegelVersion)"

/// The binary target for one libhegel artifact, or nil when Artifacts/
/// exists without it: a Linux or Windows host packages only the bundle, and
/// its build mustn't depend on the XCFramework of a release that may not be
/// published yet.
func libhegelTarget(name: String, artifact: String, checksum: String) -> Target? {
    let local = "Artifacts/\(artifact)"
    if FileManager.default.fileExists(atPath: "\(packageDirectory)/Artifacts") {
        let exists = FileManager.default.fileExists(atPath: "\(packageDirectory)/\(local)")
        return exists ? .binaryTarget(name: name, path: local) : nil
    }
    return .binaryTarget(name: name, url: "\(releaseURL)/\(artifact).zip", checksum: checksum)
}

// Each engine is a dependency only for the platforms it is built for, so
// the choice follows the build's target, not its host, and cross-compiling
// gets the right one.
let engines: [(target: Target?, platforms: [Platform])] = [
    (
        libhegelTarget(
            name: "CHegelApple",
            artifact: "CHegel.xcframework",
            checksum: xcframeworkChecksum
        ),
        [.macOS]
    ),
    (
        libhegelTarget(
            name: "CHegelLinux",
            artifact: "CHegel.artifactbundle",
            checksum: artifactbundleChecksum
        ),
        [.linux, .windows]
    ),
]

// Everywhere else Hegel links `CHegel`: libhegel's header and a stub of its
// functions that fail (libhegel/stub.c). Hegel and HegelTesting build there,
// and `HEGEL_NO_ENGINE` makes a property report that the engine isn't
// available instead of running.
let enginelessPlatforms: [Platform] = [
    .iOS, .macCatalyst, .tvOS, .watchOS, .visionOS, .android, .wasi, .openbsd,
]

let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
]

let package = Package(
    name: "hegel-swift",
    platforms: [
        .macOS(.v26), .iOS(.v26), .tvOS(.v26), .watchOS(.v26), .visionOS(.v26),
    ],
    products: [
        .library(name: "Hegel", targets: ["Hegel"]),
        .library(name: "HegelTesting", targets: ["HegelTesting"]),
    ],
    dependencies: [
        // For the `#draw` macro in HegelTesting. The range is wide so that a
        // package with its own macros can share one swift-syntax.
        .package(url: "https://github.com/swiftlang/swift-syntax.git", "603.0.0"..<"700.0.0")
    ],
    targets: engines.compactMap(\.target) + [
        .target(
            name: "CHegel",
            path: "libhegel",
            publicHeadersPath: "."
        ),
        .target(
            name: "Hegel",
            dependencies: engines.compactMap { engine in
                engine.target.map {
                    .target(name: $0.name, condition: .when(platforms: engine.platforms))
                }
            } + [.target(name: "CHegel", condition: .when(platforms: enginelessPlatforms))],
            swiftSettings: swiftSettings + [
                .define("HEGEL_NO_ENGINE", .when(platforms: enginelessPlatforms))
            ]
        ),
        .macro(
            name: "HegelMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "HegelTesting",
            dependencies: ["Hegel", "HegelMacros"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "HegelTests",
            dependencies: ["Hegel"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "HegelTestingTests",
            dependencies: ["Hegel", "HegelTesting"],
            swiftSettings: swiftSettings
        ),
    ]
)

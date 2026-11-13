// swift-tools-version: 6.3

import CompilerPluginSupport
import Foundation
import PackageDescription

// The libhegel release this package is built against. Updated, together
// with the checksums below, by Scripts/bump-libhegel.sh (run by the
// libhegel-bump workflow); do not edit by hand.
let libhegelVersion = "0.51.5"
let xcframeworkChecksum = "d1dc99d26d70bd31ad97b3d3ad6db33231575bce6bc819f86e137a860a53d936"
let artifactbundleChecksum = "be2e691445b1a828cbdcc28b1d22c9f4e5ac9b83d84e05747321a6dc96b43900"

// libhegel ships as two binary targets: an XCFramework for Apple platforms
// and a static-library artifact bundle for Linux and Windows. Releases of this package
// download them from the `libhegel-<version>` release of this repository.
// After Scripts/package-libhegel.sh, the local copies in Artifacts/ are used
// instead, so a checkout can build against a libhegel that is not released
// yet.
let packageDirectory = Context.packageDirectory
let releaseURL =
    "https://github.com/velocityzen/hegel-swift/releases/download/libhegel-\(libhegelVersion)"

func libhegelTarget(name: String, artifact: String, checksum: String) -> Target {
    let localPath = "Artifacts/\(artifact)"
    if FileManager.default.fileExists(atPath: "\(packageDirectory)/\(localPath)") {
        return .binaryTarget(name: name, path: localPath)
    }
    return .binaryTarget(name: name, url: "\(releaseURL)/\(artifact).zip", checksum: checksum)
}

let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
]

// Only the host's engine is declared, so a Linux or Windows build never
// downloads the XCFramework and a macOS build never downloads the bundle.
#if os(Linux) || os(Windows)
    let engine = libhegelTarget(
        name: "CHegelLinux",
        artifact: "CHegel.artifactbundle",
        checksum: artifactbundleChecksum
    )
#else
    let engine = libhegelTarget(
        name: "CHegelApple",
        artifact: "CHegel.xcframework",
        checksum: xcframeworkChecksum
    )
#endif

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
    targets: [
        engine,
        .target(
            name: "Hegel",
            dependencies: [.target(name: engine.name)],
            swiftSettings: swiftSettings
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

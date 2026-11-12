// swift-tools-version: 6.3

import Foundation
import PackageDescription

// The libhegel release this package is built against. Updated, together
// with the checksums below, by Scripts/bump-libhegel.sh (run by the
// libhegel-bump workflow); do not edit by hand.
let libhegelVersion = "0.51.1"
let xcframeworkChecksum = "e417af970ddf5753b2f0905d8951ca3c5e5d680ac4bd8234000c87d3363fafcc"
let artifactbundleChecksum = "d272af588a73033b9bac13db0b0fbde8a8a4f2a9f43bcba16bf08f9fb6171067"

// libhegel ships as two binary targets: an XCFramework for Apple platforms
// and a static-library artifact bundle for Linux. Releases of this package
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

// Only the host's engine is declared, so a Linux build never downloads the
// XCFramework and a macOS build never downloads the Linux bundle.
#if os(Linux)
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
    targets: [
        engine,
        .target(
            name: "Hegel",
            dependencies: [.target(name: engine.name)],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "HegelTesting",
            dependencies: ["Hegel"],
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

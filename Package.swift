// swift-tools-version: 6.3

import Foundation
import PackageDescription

// The libhegel release this package is built against. Updated, together
// with the checksums below, by Scripts/bump-libhegel.sh (run by the
// libhegel-bump workflow); do not edit by hand.
let libhegelVersion = "0.51.1"
let xcframeworkChecksum = "78f7a3613b476a2f5b86ef161b5e9e6d4c91cbea0b04800b13ef218ddb0fed33"
let artifactbundleChecksum = "a476bdeb02906d2e82ab24b212bcf75f9fa6daba606948b3d4311cb9d950036f"

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

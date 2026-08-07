// swift-tools-version: 5.10
import PackageDescription

// Three targets, not one. The core is a library so that BOTH executables and
// the test target can import it — an executable target cannot be imported, and
// that is the only reason the tuning harness had to live outside the package.
//
//   ClockItCore   library     everything except the app entry point
//   ClockIt       executable  main.swift only
//   ClockItTuner  executable  the throwaway threshold harness
//
// Named ClockIt throughout — package, library, both executables, tests. The
// bundle identifier in the packaging script should match.
let package = Package(
    name: "ClockIt",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Phase 2 adds:
        // .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", from: "3.31.4")
        //
        // WhisperKit moved: argmaxinc/WhisperKit was renamed to
        // argmaxinc/argmax-oss-swift at v1.0.0 (May 2026), where WhisperKit
        // became one product alongside ArgmaxOSS, TTSKit and SpeakerKit. The
        // old URL still redirects, but SwiftPM derives package identity from
        // the URL's last path component, so pointing at the old name means
        // `package:` below has to lie about which package it is. Use the real one.
        //
        // The range is up-to-next-minor, spelled as an explicit Range because
        // `.upToNextMinor(from:)` is deprecated at tools-version 5.6+. v1.1.0
        // is very new (2026-08-06) and Transcriber.swift is verified against it
        // specifically; `from: "1.1.0"` would have floated the whole 1.x line
        // underneath a file whose call sites we checked by hand.
        .package(
            url: "https://github.com/argmaxinc/argmax-oss-swift.git",
            "1.1.0" ..< "1.2.0"
        )
    ],
    targets: [
        .target(
            name: "ClockItCore",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift")
            ]
        ),
        .executableTarget(
            name: "ClockIt",
            dependencies: ["ClockItCore"]
        ),
        // Throwaway. Delete the target and the directory together once the
        // thresholds are settled — nothing in the app depends on it.
        .executableTarget(
            name: "ClockItTuner",
            dependencies: ["ClockItCore"]
        ),
        .testTarget(
            name: "ClockItCoreTests",
            dependencies: ["ClockItCore"]
        )
    ]
)

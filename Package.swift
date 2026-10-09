// swift-tools-version:5.9
import PackageDescription

// GlEnc — DXV3 / HAP / ProRes / H.264 / HEVC / MJPEG encoder for macOS.
//
// Public mirror. DXVKit (the clean-room MIT DXV codec: Sources/CDXVKit + Sources/DXVKit)
// and Glance's GlanceCore / GlancePlayback / SnappyC are copied in as source from their
// tagged releases (see THIRD-PARTY-NOTICES.md); the development repository consumes the
// same code as pinned SwiftPM dependencies. The test suite lives in the development
// repository.

let package = Package(
    name: "GlEnc",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "GlEnc", targets: ["GlEnc"]),
        .library(name: "GlEncCore", targets: ["GlEncCore"]),
        .executable(name: "glenc-cli", targets: ["glenc-cli"]),
    ],
    dependencies: [
        // CLI argument parsing (Apache-2.0); only glenc-cli depends on it.
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        // DXVKit 1.0.0 — C99 core (src/ + include/dxvkit.h) and its Swift API. MIT.
        .target(
            name: "CDXVKit",
            path: "Sources/CDXVKit",
            sources: ["src"],
            publicHeadersPath: "include"
        ),
        .target(
            name: "DXVKit",
            dependencies: ["CDXVKit"],
            path: "Sources/DXVKit"
        ),
        // Glance 0.17.1 — vendored C Snappy (BSD-3), GlanceCore, GlancePlayback. MIT.
        .target(name: "SnappyC", path: "Sources/SnappyC"),
        .target(
            name: "GlanceCore",
            dependencies: ["SnappyC", "DXVKit"],
            path: "Sources/GlanceCore"
        ),
        .target(
            name: "GlancePlayback",
            dependencies: ["GlanceCore"],
            path: "Sources/GlancePlayback"
        ),
        // GlEnc.
        .target(
            name: "GlEncCore",
            dependencies: ["GlanceCore", "DXVKit"],
            path: "Sources/GlEncCore"
        ),
        .executableTarget(
            name: "GlEnc",
            dependencies: ["GlEncCore", "GlanceCore", "GlancePlayback"],
            path: "Sources/GlEnc",
            exclude: ["Info.plist"]
        ),
        .executableTarget(
            name: "glenc-cli",
            dependencies: [
                "GlEncCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/glenc-cli"
        ),
    ]
)

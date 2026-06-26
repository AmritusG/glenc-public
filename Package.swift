// swift-tools-version:5.9
import PackageDescription

// GlEnc — DXV3 encoder. See HANDOVER.md and DECISIONS-2026-05-09.md.
//
// Two product targets:
//   - GlEnc:     SwiftUI macOS app (drop zone, queue, format picker).
//   - GlEncCore: Pure-Swift encoder backend (no AppKit). Holds the
//                DXT1/DXT5/HQ encoders, BC1/BC4/BC5 block encoders,
//                LZ writer, and the hand-rolled MOV atom writer.
//
// GlanceCore + GlancePlayback are VENDORED in-tree (Sources/GlanceCore,
// Sources/GlancePlayback) from AmritusG/glance @ e134a3a (v0.7.0) — the
// decoders are the round-trip validation oracle and the preview engine.
// The external glance package dependency has been removed; GlEnc is
// self-contained (resolved graph: swift-snappy + swift-system only).

let package = Package(
    name: "GlEnc",
    platforms: [
        // GlEnc targets macOS 14 (SwiftUI + the vendored GlancePlayback's
        // CAOpenGLLayer preview path).
        .macOS(.v14),
    ],
    products: [
        .executable(name: "GlEnc", targets: ["GlEnc"]),
        .library(name: "GlEncCore", targets: ["GlEncCore"]),
        // Headless CLI over GlEncCore — DXV/HAP minting from the command
        // line, no GUI. Drives the exact `CoreEncoder` dispatch the app uses.
        .executable(name: "glenc-cli", targets: ["glenc-cli"]),
    ],
    dependencies: [
        // CLI argument parsing. Apache-2.0 (permissive — safe for Loombda
        // to link transitively). ONLY the `glenc-cli` executable depends on
        // it; GlEncCore's dependency graph stays unchanged.
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        // Snappy — HAP de/compression. BSD-3, wraps Google's C snappy-c.
        // The vendored GlanceCore decodes HAP via this same package, and
        // our tests round-trip SnappyCompressor output through it.
        //
        // v0.10.1 — pinned to a FORK that fixes a catastrophic per-call
        // buffer leak: upstream lovetodream/swift-snappy 1.0.0 wraps the
        // de/compress output in `Data(bytesNoCopy:..., deallocator:
        // .none)`, so the buffer is never freed (~1.98 MB leaked per
        // 1080p HAP frame decode → GBs during HAP preview playback). The
        // bug is unfixed upstream (only release is 1.0.0, Dec 2022; main
        // still has it). The fork tags 1.0.1 with `.none` → `.custom {
        // ptr,_ in ptr.deallocate() }`.
        .package(url: "https://github.com/AmritusG/swift-snappy.git", from: "1.0.1"),
    ],
    targets: [
        // Vendored from AmritusG/glance @ e134a3a (v0.7.0). Kept as separate
        // modules named GlanceCore / GlancePlayback so existing `import`
        // lines are unchanged. Per-file licenses are in the source headers
        // and THIRD-PARTY-NOTICES.md (FFmpeg dxv.c ports → LGPL-2.1-or-later;
        // liblzf port → BSD-2-Clause; the rest MIT).
        .target(
            name: "GlanceCore",
            dependencies: [
                .product(name: "Snappy", package: "swift-snappy"),
            ],
            path: "Sources/GlanceCore"
        ),
        .target(
            name: "GlancePlayback",
            dependencies: ["GlanceCore"],
            path: "Sources/GlancePlayback"
        ),
        .target(
            name: "GlEncCore",
            dependencies: [
                "GlanceCore",
            ],
            path: "Sources/GlEncCore"
        ),
        .executableTarget(
            name: "GlEnc",
            dependencies: [
                "GlEncCore",
                "GlanceCore",
                // Live preview pane uses the vendored playback engine
                // (DXVPlayer + DXVRenderer + FrameClock) inside a
                // CAOpenGLLayer-backed NSView.
                "GlancePlayback",
            ],
            path: "Sources/GlEnc",
            exclude: ["Info.plist"]
        ),
        // Thin headless front-end. Parses args, makes ONE call into
        // GlEncCore's `CoreEncoder`, maps result to an exit code. No encode
        // logic here — it lives in GlEncCore, shared with the GUI.
        .executableTarget(
            name: "glenc-cli",
            dependencies: [
                "GlEncCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/glenc-cli"
        ),
        .testTarget(
            name: "GlEncTests",
            dependencies: [
                "GlEncCore",
                "GlEnc",
                "GlanceCore",
                "GlancePlayback",
                // Round-trip oracle for SnappyCompressor.
                .product(name: "Snappy", package: "swift-snappy"),
            ],
            path: "Tests/GlEncTests"
        ),
    ]
)

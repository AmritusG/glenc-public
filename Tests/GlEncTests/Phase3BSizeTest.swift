/*
 * Phase 3B prep — real-content size measurement.
 *
 * Drives the DXT5 encoder over a single real-world clip (the Pass B
 * priming follow-up, ShroomiesKingdom_5s.mov ProRes 4444 intermediate)
 * and writes the encoded output to reference/dxt5/realworld-glenc.mov
 * for size comparison against reference/dxt5/realworld-alley.mov. Wall-
 * clock encode time is captured for the v0.3.1 perf-budget conversation.
 *
 * Not a regression test — disabled by default via the env-gate to keep
 * the normal `swift test` run fast. Re-arm with:
 *
 *   GLENC_RUN_PHASE3B=1 swift test --filter Phase3BSizeTest
 */

import XCTest
import Foundation
import CoreMedia
import AVFoundation
@testable import GlEncCore

final class Phase3BSizeTest: XCTestCase {

    private static let referenceDir: URL = {
        URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("reference/dxt5")
    }()

    func testEncodeRealWorldClipAndSaveOutput() async throws {
        guard ProcessInfo.processInfo.environment["GLENC_RUN_PHASE3B"] != nil else {
            throw XCTSkip("Set GLENC_RUN_PHASE3B=1 to run the Phase 3B size measurement.")
        }

        let sourceMOV = Self.referenceDir
            .appendingPathComponent("realworld-source/ShroomiesKingdom_5s.mov")
        guard FileManager.default.fileExists(atPath: sourceMOV.path) else {
            throw XCTSkip("reference/dxt5/realworld-source/ShroomiesKingdom_5s.mov missing (local-only media, stripped from the public seed) — supply your own clip via scripts/make-corpus.sh [path]")
        }
        let outURL = Self.referenceDir.appendingPathComponent("realworld-glenc.mov")
        if FileManager.default.fileExists(atPath: outURL.path) {
            try FileManager.default.removeItem(at: outURL)
        }

        let asset = AVURLAsset(url: sourceMOV)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = videoTracks.first else {
            XCTFail("source has no video track")
            return
        }
        let size = try await track.load(.naturalSize)
        let fps = try await track.load(.nominalFrameRate)
        let w = Int(size.width.rounded())
        let h = Int(size.height.rounded())
        print("[ph3b] source: \(w)×\(h) @ \(fps)fps")

        let pipeline = EncodePipeline(
            sourceURL: sourceMOV,
            encoder: DXT5Encoder(),
            makeWriter: { ww, hh, ff in
                try DXVMOVWriter(
                    destURL: outURL, format: .dxt5,
                    presentationWidth: ww, presentationHeight: hh, fps: ff,
                    writerVersion: "GlEnc 0.3.0")
            },
            sourceAlphaInfo: .last)

        let t0 = Date()
        try await pipeline.run()
        let elapsed = Date().timeIntervalSince(t0)

        let outSize = (try FileManager.default.attributesOfItem(
            atPath: outURL.path)[.size] as? Int) ?? 0
        print("[ph3b] glenc output: \(outSize) bytes")
        print("[ph3b] wall-clock encode time: \(String(format: "%.2fs", elapsed))")
        print("[ph3b] saved to: \(outURL.path)")

        XCTAssertGreaterThan(outSize, 1_000_000, "output suspiciously small")
    }

    /// Phase 5C.2 validation gate. Re-encode ShroomiesKingdom through
    /// the LEGACY FFmpeg-path BC1 (BC1Config.useClusterFit = false) so
    /// the user can A/B compare in Resolume Arena against the current
    /// ClusterFit output at reference/dxt5/realworld-glenc.mov. Output
    /// lands in ~/Movies/GlEnc-scratch/ where Arena's file picker can
    /// navigate to it (per feedback_test_artifact_locations.md). Test
    /// is removed after the Arena verdict ships; gated by
    /// GLENC_5C2_AB_TEST so it doesn't appear in normal runs.
    func testReencodeRealWorldClipWithFFmpegPath_Phase5C2AB() async throws {
        guard ProcessInfo.processInfo.environment["GLENC_5C2_AB_TEST"] != nil else {
            throw XCTSkip("Set GLENC_5C2_AB_TEST=1 to run the Phase 5C.2 Arena A/B re-encode")
        }
        let sourceMOV = Self.referenceDir
            .appendingPathComponent("realworld-source/ShroomiesKingdom_5s.mov")
        guard FileManager.default.fileExists(atPath: sourceMOV.path) else {
            throw XCTSkip("reference/dxt5/realworld-source/ShroomiesKingdom_5s.mov missing (local-only media, stripped from the public seed) — supply your own clip via scripts/make-corpus.sh [path]")
        }
        let scratchDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Movies/GlEnc-scratch")
        try FileManager.default.createDirectory(at: scratchDir,
                                                withIntermediateDirectories: true)
        let outURL = scratchDir.appendingPathComponent("shroomies-ffmpegpath.mov")
        if FileManager.default.fileExists(atPath: outURL.path) {
            try FileManager.default.removeItem(at: outURL)
        }

        // Toggle the BC1 path to the legacy FFmpeg-byte-identity encoder
        // for the duration of this encode, then restore.
        let priorFlag = BC1Config.useClusterFit
        BC1Config.useClusterFit = false
        defer { BC1Config.useClusterFit = priorFlag }

        let pipeline = EncodePipeline(
            sourceURL: sourceMOV,
            encoder: DXT5Encoder(),
            makeWriter: { ww, hh, ff in
                try DXVMOVWriter(
                    destURL: outURL, format: .dxt5,
                    presentationWidth: ww, presentationHeight: hh, fps: ff,
                    writerVersion: "GlEnc 0.5.0-pre-5C2-ABtest-ffmpegpath")
            },
            sourceAlphaInfo: .last)

        let t0 = Date()
        try await pipeline.run()
        let elapsed = Date().timeIntervalSince(t0)

        let outSize = (try FileManager.default.attributesOfItem(
            atPath: outURL.path)[.size] as? Int) ?? 0
        print("[5C.2 AB] FFmpeg-path encode: \(outSize) bytes in \(String(format: "%.2fs", elapsed))")
        print("[5C.2 AB] saved to: \(outURL.path)")
        XCTAssertGreaterThan(outSize, 1_000_000, "output suspiciously small")
    }

    /// Per-frame size comparison between GlEnc and Alley outputs. Reads
    /// each .mov via the test's MOVFrameExtractor and dumps the per-
    /// frame DXV3 packet sizes (12-byte header + LZ payload). The header
    /// is constant 12 bytes across all frames in both encoders, so the
    /// ratios reflect LZ-payload differences directly.
    func testMeasureRealWorldPerFrameStats() throws {
        guard ProcessInfo.processInfo.environment["GLENC_RUN_PHASE3B"] != nil else {
            throw XCTSkip("Set GLENC_RUN_PHASE3B=1 to run the Phase 3B measurement.")
        }
        let glencURL = Self.referenceDir.appendingPathComponent("realworld-glenc.mov")
        let alleyURL = Self.referenceDir.appendingPathComponent("realworld-alley.mov")
        guard FileManager.default.fileExists(atPath: glencURL.path),
              FileManager.default.fileExists(atPath: alleyURL.path) else {
            throw XCTSkip("reference/dxt5/realworld-{glenc,alley}.mov missing (GlEnc-produced / Resolume-Alley artifacts, stripped from the public seed) — regenerate via Phase3BSizeTest.testEncodeRealWorldClipAndSaveOutput (needs the local-only source clip)")
        }
        let glenc = try MOVFrameExtractor(url: glencURL)
        let alley = try MOVFrameExtractor(url: alleyURL)
        XCTAssertEqual(glenc.frameCount, alley.frameCount,
                       "frame count mismatch — Alley has \(alley.frameCount), GlEnc has \(glenc.frameCount)")

        let n = min(glenc.frameCount, alley.frameCount)
        var glencSizes: [Int] = []
        var alleySizes: [Int] = []
        var ratios: [Double] = []
        var totalGlenc = 0
        var totalAlley = 0
        for i in 0..<n {
            let g = glenc.frameData(at: i).count
            let a = alley.frameData(at: i).count
            glencSizes.append(g)
            alleySizes.append(a)
            ratios.append(Double(g) / Double(a))
            totalGlenc += g
            totalAlley += a
        }

        let glencFileSize = (try FileManager.default.attributesOfItem(atPath: glencURL.path)[.size] as? Int) ?? 0
        let alleyFileSize = (try FileManager.default.attributesOfItem(atPath: alleyURL.path)[.size] as? Int) ?? 0

        print("=== Phase 3B real-world size comparison ===")
        print("[clip] ShroomiesKingdom_5s.mov, 150 frames, 3840×2160 @ 30fps")
        print(String(format: "[file]   GlEnc: %d bytes (%.2f MB)", glencFileSize, Double(glencFileSize)/1_048_576))
        print(String(format: "[file]   Alley: %d bytes (%.2f MB)", alleyFileSize, Double(alleyFileSize)/1_048_576))
        print(String(format: "[file]   ratio: %.3fx", Double(glencFileSize) / Double(alleyFileSize)))
        print("---")
        print(String(format: "[payload] GlEnc total: %d bytes (%.2f MB)", totalGlenc, Double(totalGlenc)/1_048_576))
        print(String(format: "[payload] Alley total: %d bytes (%.2f MB)", totalAlley, Double(totalAlley)/1_048_576))
        print(String(format: "[payload] ratio:       %.3fx", Double(totalGlenc) / Double(totalAlley)))
        print("---")
        let meanG = Double(totalGlenc) / Double(n)
        let meanA = Double(totalAlley) / Double(n)
        let sortedG = glencSizes.sorted()
        let sortedA = alleySizes.sorted()
        let medianG = sortedG[n/2]
        let medianA = sortedA[n/2]
        let maxG = sortedG.last!
        let maxA = sortedA.last!
        let varG = glencSizes.reduce(0.0) { $0 + (Double($1) - meanG) * (Double($1) - meanG) } / Double(n)
        let varA = alleySizes.reduce(0.0) { $0 + (Double($1) - meanA) * (Double($1) - meanA) } / Double(n)
        print(String(format: "[per-frame GlEnc] mean=%9.0f  median=%9d  max=%9d  stddev=%.0f",
                     meanG, medianG, maxG, varG.squareRoot()))
        print(String(format: "[per-frame Alley] mean=%9.0f  median=%9d  max=%9d  stddev=%.0f",
                     meanA, medianA, maxA, varA.squareRoot()))
        print("---")
        let sortedRatios = ratios.sorted()
        let medianR = sortedRatios[n/2]
        let p10 = sortedRatios[n/10]
        let p90 = sortedRatios[(n*9)/10]
        let minR = sortedRatios.first!
        let maxR = sortedRatios.last!
        let meanR = ratios.reduce(0, +) / Double(n)
        print(String(format: "[per-frame ratio] mean=%.3fx  median=%.3fx  p10=%.3fx  p90=%.3fx  min=%.3fx  max=%.3fx",
                     meanR, medianR, p10, p90, minR, maxR))
        print("---")
        // Histogram bins.
        var bins: [String: Int] = [
            "≤1.5x": 0, "1.5-2.0x": 0, "2.0-3.0x": 0,
            "3.0-5.0x": 0, "5.0-10.0x": 0, "10.0-20.0x": 0, ">20.0x": 0,
        ]
        for r in ratios {
            switch r {
            case ..<1.5:        bins["≤1.5x"]! += 1
            case 1.5..<2.0:     bins["1.5-2.0x"]! += 1
            case 2.0..<3.0:     bins["2.0-3.0x"]! += 1
            case 3.0..<5.0:     bins["3.0-5.0x"]! += 1
            case 5.0..<10.0:    bins["5.0-10.0x"]! += 1
            case 10.0..<20.0:   bins["10.0-20.0x"]! += 1
            default:            bins[">20.0x"]! += 1
            }
        }
        let order = ["≤1.5x", "1.5-2.0x", "2.0-3.0x", "3.0-5.0x", "5.0-10.0x", "10.0-20.0x", ">20.0x"]
        print("[ratio histogram]")
        for k in order {
            print(String(format: "  %@: %3d frames (%.1f%%)", k, bins[k]!, 100.0 * Double(bins[k]!) / Double(n)))
        }

        // Show worst 5 frames for inspection.
        let worstIdx = ratios.enumerated().sorted { $0.element > $1.element }.prefix(5)
        print("[worst 5 frames by ratio]")
        for (i, r) in worstIdx {
            print(String(format: "  frame %3d: glenc=%9d  alley=%9d  ratio=%.3fx", i, glencSizes[i], alleySizes[i], r))
        }
    }
}

/*
 * Phase 5C.4 measurement — refined BC4 vs simple BC4 on real-content
 * HQ + Normal-alpha corpora.
 *
 * Phase 5C.3 implemented an rgbcx-style 7×7 endpoint refinement
 * search for BC4. SSIM gain on synthetic + DXT1-only corpora was
 * sub-perceptual (+0.000012 on YCG6 testsrc2) because those corpora
 * don't surface non-constant BC4 chroma blocks at scale: testsrc2
 * has flat color stripes that hit the constant-block fast path, and
 * ShroomiesKingdom_29 is DXT1-only with α=255 throughout.
 *
 * Phase 5C.3.5 built two paired real-content corpora from
 * ShroomiesKingdom_05 (DXT5 + YG10, same source, frame-aligned).
 * Real motion-graphic alpha-bearing content WITH saturated chroma
 * transitions — exactly where refined BC4 should demonstrate value.
 *
 * This file runs four measurements:
 *   (a) DXT5 paired corpus — refined BC4 ON vs OFF.
 *   (b) YG10 corpus — refined BC4 ON vs OFF.
 *   (c) YG10 vs DXT5 quality comparison (same source content).
 *   (d) Per-channel LSB-Δ breakdown (R/G/B/α) for the Phase 5B
 *       "all colours except red lose saturation" diagnosis.
 *
 * Gated by GLENC_RUN_5C4_MEASUREMENT=1 to keep ~10 min of 4K encode
 * wall-clock out of normal test runs.
 */

import XCTest
import Foundation
import CoreVideo
import CoreGraphics
import CoreMedia
import ImageIO
@testable import GlEncCore
import GlanceCore

final class Phase5C4MeasurementTests: XCTestCase {

    private static let referenceDir: URL = {
        URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("reference")
    }()

    private static let frameCount = 30
    private static let w = 3840
    private static let h = 2160
    // 4K is 16-aligned on both axes — no padded coded dims needed.
    private static let codedW = 3840
    private static let codedH = 2160

    // MARK: - (a) DXT5 paired corpus

    func testRefinedBC4_DXT5_RealContent() throws {
        guard ProcessInfo.processInfo.environment["GLENC_RUN_5C4_MEASUREMENT"] == "1" else {
            throw XCTSkip("Set GLENC_RUN_5C4_MEASUREMENT=1 to run Phase 5C.4 measurements (~10-15 min)")
        }
        let cor = Self.referenceDir.appendingPathComponent("realworld-dxt5-paired-corpus/source")
        guard FileManager.default.fileExists(atPath: cor.appendingPathComponent("frame_0001.png").path) else {
            throw XCTSkip("realworld-dxt5-paired-corpus missing")
        }
        print("=== Phase 5C.4 (a) DXT5 paired corpus — refined BC4 ON vs OFF ===")

        let priorFlag = BC4Config.useRefinement
        defer { BC4Config.useRefinement = priorFlag }

        // Encode once with refinement OFF, once ON. Capture per-frame
        // metrics so they're directly comparable.
        BC4Config.useRefinement = false
        let off = try measureDXT5(corpusDir: cor, label: "refined-OFF")

        BC4Config.useRefinement = true
        let on  = try measureDXT5(corpusDir: cor, label: "refined-ON ")

        reportABSummary(label: "DXT5 paired", off: off, on: on)
    }

    // MARK: - (b) YG10 corpus

    func testRefinedBC4_YG10_RealContent() throws {
        guard ProcessInfo.processInfo.environment["GLENC_RUN_5C4_MEASUREMENT"] == "1" else {
            throw XCTSkip("Set GLENC_RUN_5C4_MEASUREMENT=1 to run Phase 5C.4 measurements (~10-15 min)")
        }
        let cor = Self.referenceDir.appendingPathComponent("realworld-yg10-corpus/source")
        guard FileManager.default.fileExists(atPath: cor.appendingPathComponent("frame_0001.png").path) else {
            throw XCTSkip("realworld-yg10-corpus missing")
        }
        print("=== Phase 5C.4 (b) YG10 corpus — refined BC4 ON vs OFF ===")

        let priorFlag = BC4Config.useRefinement
        defer { BC4Config.useRefinement = priorFlag }

        BC4Config.useRefinement = false
        let off = try measureYG10(corpusDir: cor, label: "refined-OFF")

        BC4Config.useRefinement = true
        let on  = try measureYG10(corpusDir: cor, label: "refined-ON ")

        reportABSummary(label: "YG10", off: off, on: on)
    }

    // MARK: - (c) YG10 vs DXT5 quality comparison

    func testYG10VsDXT5_QualityComparison() throws {
        guard ProcessInfo.processInfo.environment["GLENC_RUN_5C4_MEASUREMENT"] == "1" else {
            throw XCTSkip("Set GLENC_RUN_5C4_MEASUREMENT=1 to run Phase 5C.4 measurements")
        }
        print("=== Phase 5C.4 (c) YG10 vs DXT5 quality on same source frames ===")
        // The two paired corpora are decoded from different DXV3 variants
        // of the same source moment. Measuring SSIM(GlEnc-encoded,
        // source PNG) for each variant tells us how much real-content
        // quality HQ buys vs Normal on this specific scene.
        let yg10Cor = Self.referenceDir.appendingPathComponent("realworld-yg10-corpus/source")
        let dxt5Cor = Self.referenceDir.appendingPathComponent("realworld-dxt5-paired-corpus/source")
        guard FileManager.default.fileExists(atPath: yg10Cor.appendingPathComponent("frame_0001.png").path),
              FileManager.default.fileExists(atPath: dxt5Cor.appendingPathComponent("frame_0001.png").path)
        else {
            throw XCTSkip("paired corpora missing")
        }
        // Run at the default refined setting.
        BC4Config.useRefinement = true
        let yg10 = try measureYG10(corpusDir: yg10Cor, label: "YG10 vs YG10-source")
        let dxt5 = try measureDXT5(corpusDir: dxt5Cor, label: "DXT5 vs DXT5-source")
        print(String(format: "[5C.4-c] YG10 mean SSIM = %.6f (min %.6f)",
                     yg10.meanSSIM, yg10.minSSIM))
        print(String(format: "[5C.4-c] DXT5 mean SSIM = %.6f (min %.6f)",
                     dxt5.meanSSIM, dxt5.minSSIM))
        print(String(format: "[5C.4-c] YG10 mean ΔR=%.3f ΔG=%.3f ΔB=%.3f Δα=%.3f LSB",
                     yg10.meanR, yg10.meanG, yg10.meanB, yg10.meanA))
        print(String(format: "[5C.4-c] DXT5 mean ΔR=%.3f ΔG=%.3f ΔB=%.3f Δα=%.3f LSB",
                     dxt5.meanR, dxt5.meanG, dxt5.meanB, dxt5.meanA))
    }

    // MARK: - (d) Per-channel breakdown

    /// Single-frame deep dive: load YG10 frame 1 from the paired
    /// corpus, encode through YG10Encoder twice (refined OFF vs ON),
    /// decode each, report per-channel mean and max LSB Δ. The
    /// Phase 5B Arena observation — "all colours except red lose
    /// saturation" — should manifest as the BC4-affected channels
    /// (G/B in cyan, R/B in magenta, etc.) carrying the largest
    /// deltas when refinement is OFF; refinement should narrow them.
    func testPerChannelDeltaBreakdown() throws {
        guard ProcessInfo.processInfo.environment["GLENC_RUN_5C4_MEASUREMENT"] == "1" else {
            throw XCTSkip("Set GLENC_RUN_5C4_MEASUREMENT=1 to run Phase 5C.4 measurements")
        }
        let cor = Self.referenceDir.appendingPathComponent("realworld-yg10-corpus/source")
        let pngURL = cor.appendingPathComponent("frame_0001.png")
        guard FileManager.default.fileExists(atPath: pngURL.path) else {
            throw XCTSkip("realworld-yg10-corpus missing")
        }
        print("=== Phase 5C.4 (d) per-channel breakdown on YG10 frame 1 ===")
        let priorFlag = BC4Config.useRefinement
        defer { BC4Config.useRefinement = priorFlag }

        let sourceRGBA = try loadPNGAsRGBA(url: pngURL, w: Self.w, h: Self.h)

        BC4Config.useRefinement = false
        let offDecoded = try encodeYG10Frame(sourceRGBA: sourceRGBA)
        let offStats = perChannelStats(source: sourceRGBA, decoded: offDecoded)
        print(String(format: "[5C.4-d] refined OFF: meanΔ R=%.3f G=%.3f B=%.3f α=%.3f | maxΔ R=%d G=%d B=%d α=%d",
                     offStats.meanR, offStats.meanG, offStats.meanB, offStats.meanA,
                     offStats.maxR, offStats.maxG, offStats.maxB, offStats.maxA))

        BC4Config.useRefinement = true
        let onDecoded = try encodeYG10Frame(sourceRGBA: sourceRGBA)
        let onStats = perChannelStats(source: sourceRGBA, decoded: onDecoded)
        print(String(format: "[5C.4-d] refined ON : meanΔ R=%.3f G=%.3f B=%.3f α=%.3f | maxΔ R=%d G=%d B=%d α=%d",
                     onStats.meanR, onStats.meanG, onStats.meanB, onStats.meanA,
                     onStats.maxR, onStats.maxG, onStats.maxB, onStats.maxA))
        print(String(format: "[5C.4-d] DELTA      : meanΔ R=%+.3f G=%+.3f B=%+.3f α=%+.3f LSB",
                     onStats.meanR - offStats.meanR,
                     onStats.meanG - offStats.meanG,
                     onStats.meanB - offStats.meanB,
                     onStats.meanA - offStats.meanA))
    }

    // MARK: - Phase 5C.4.5: ClusterFit BC1 A/B on real content

    /// DXT5 paired corpus, ClusterFit BC1 ON vs OFF, with refined
    /// BC4 forced OFF (per 5C.4 verdict). Isolates BC1 algorithm
    /// effect on the same real-content corpus used in 5C.4.
    func testClusterFitBC1_DXT5_RealContent() throws {
        guard ProcessInfo.processInfo.environment["GLENC_RUN_5C45_MEASUREMENT"] == "1" else {
            throw XCTSkip("Set GLENC_RUN_5C45_MEASUREMENT=1 to run Phase 5C.4.5 measurements (~5-10 min)")
        }
        let cor = Self.referenceDir.appendingPathComponent("realworld-dxt5-paired-corpus/source")
        guard FileManager.default.fileExists(atPath: cor.appendingPathComponent("frame_0001.png").path) else {
            throw XCTSkip("realworld-dxt5-paired-corpus missing")
        }
        print("=== Phase 5C.4.5 (a) DXT5 paired corpus — ClusterFit BC1 ON vs OFF (refined BC4 off) ===")

        let priorBC1 = BC1Config.useClusterFit
        let priorBC4 = BC4Config.useRefinement
        defer {
            BC1Config.useClusterFit = priorBC1
            BC4Config.useRefinement = priorBC4
        }
        // Force refined BC4 off to isolate BC1 effect (5C.4 verdict).
        BC4Config.useRefinement = false

        BC1Config.useClusterFit = false
        let ffmpegBC1 = try measureDXT5(corpusDir: cor, label: "BC1-ffmpeg")

        BC1Config.useClusterFit = true
        let clusterFitBC1 = try measureDXT5(corpusDir: cor, label: "BC1-cluster")

        reportABSummary(label: "DXT5 BC1-A/B", off: ffmpegBC1, on: clusterFitBC1)
    }

    /// DXT1-only ShroomiesKingdom_29 corpus, ClusterFit BC1 ON vs OFF.
    /// DXT1 doesn't carry alpha (α=255 throughout) and doesn't invoke
    /// BC4 at all — pure BC1 isolation on a second real-content
    /// dataset.
    func testClusterFitBC1_DXT1_RealContent() throws {
        guard ProcessInfo.processInfo.environment["GLENC_RUN_5C45_MEASUREMENT"] == "1" else {
            throw XCTSkip("Set GLENC_RUN_5C45_MEASUREMENT=1 to run Phase 5C.4.5 measurements")
        }
        let cor = Self.referenceDir.appendingPathComponent("realworld-corpus/source")
        guard FileManager.default.fileExists(atPath: cor.appendingPathComponent("frame_0001.png").path) else {
            throw XCTSkip("realworld-corpus missing")
        }
        print("=== Phase 5C.4.5 (b) DXT1 ShroomiesKingdom_29 corpus — ClusterFit BC1 ON vs OFF ===")

        let priorBC1 = BC1Config.useClusterFit
        let priorBC4 = BC4Config.useRefinement
        defer {
            BC1Config.useClusterFit = priorBC1
            BC4Config.useRefinement = priorBC4
        }
        // BC4 setting is irrelevant for DXT1 (no BC4 use) but keep
        // parity with the DXT5 test so the comparison is clean.
        BC4Config.useRefinement = false

        BC1Config.useClusterFit = false
        let ffmpegBC1 = try measureDXT1(corpusDir: cor, label: "BC1-ffmpeg")

        BC1Config.useClusterFit = true
        let clusterFitBC1 = try measureDXT1(corpusDir: cor, label: "BC1-cluster")

        reportABSummary(label: "DXT1 BC1-A/B", off: ffmpegBC1, on: clusterFitBC1)
    }

    /// DXT1 corpus measurement. Encodes each source PNG through
    /// DXT1Encoder, decodes via DXVPacketDecoder.decompressDXT1 +
    /// CPURender.cgImageFromDXT, computes SSIM + per-channel Δ.
    /// DXT1 forces α=255 at encode and decode (no alpha plane).
    private func measureDXT1(corpusDir: URL, label: String) throws -> CorpusStats {
        let t0 = Date()
        var ssims: [Double] = []
        var sumR = 0.0, sumG = 0.0, sumB = 0.0, sumA = 0.0
        var mxR = 0, mxG = 0, mxB = 0, mxA = 0
        var n: Int64 = 0
        let blocks = (Self.codedW / 4) * (Self.codedH / 4)
        let enc = DXT1Encoder()
        try enc.prepare(width: Self.w, height: Self.h, fps: 30, hasAlpha: false)

        for i in 1...Self.frameCount {
            let pngURL = corpusDir.appendingPathComponent(String(format: "frame_%04d.png", i))
            var sourceRGBA = try loadPNGAsRGBA(url: pngURL, w: Self.w, h: Self.h)
            // Force α=255 in source (DXT1's α is opaque by definition).
            for j in stride(from: 3, to: sourceRGBA.count, by: 4) {
                sourceRGBA[j] = 255
            }
            let frame = try makeBGRAPixelFrame(
                rgba: sourceRGBA, w: Self.w, h: Self.h,
                alphaInfo: .noneSkipLast)
            let pkt = try enc.encode(frame: frame)
            let (_, payload) = try DXVPacketDecoder.parseHeader(pkt)
            let bc1 = try DXVPacketDecoder.decompressDXT1(payload, expectedSize: blocks * 8)
            let cgImage = try CPURender.cgImageFromDXT(
                dxtBytes: bc1, variant: .dxt1,
                width: Self.codedW, height: Self.codedH)
            let decoded = try extractRGBA(cgImage: cgImage, w: Self.codedW, h: Self.codedH)

            let s = ssim8x8BT709(a: decoded, b: sourceRGBA,
                                 width: Self.w, height: Self.h)
            ssims.append(s)
            let st = perChannelStats(source: sourceRGBA, decoded: decoded)
            sumR += st.meanR; sumG += st.meanG; sumB += st.meanB; sumA += st.meanA
            mxR = max(mxR, st.maxR); mxG = max(mxG, st.maxG); mxB = max(mxB, st.maxB); mxA = max(mxA, st.maxA)
            n += 1
        }
        try enc.finish()

        let frames = Double(max(1, n))
        let elapsed = Date().timeIntervalSince(t0)
        let mean = ssims.reduce(0, +) / Double(ssims.count)
        let minS = ssims.min() ?? 0
        print(String(format: "[5C.4.5 DXT1 %@] mean SSIM=%.6f min=%.6f | meanΔRGBA=(%.3f, %.3f, %.3f, %.3f) | maxΔRGBA=(%d, %d, %d, %d) | %.2fs",
                     label, mean, minS,
                     sumR/frames, sumG/frames, sumB/frames, sumA/frames,
                     mxR, mxG, mxB, mxA, elapsed))
        return CorpusStats(meanSSIM: mean, minSSIM: minS,
                           meanR: sumR/frames, meanG: sumG/frames,
                           meanB: sumB/frames, meanA: sumA/frames,
                           maxR: mxR, maxG: mxG, maxB: mxB, maxA: mxA,
                           elapsedSec: elapsed)
    }

    // MARK: - Per-corpus measurement

    struct CorpusStats {
        let meanSSIM: Double, minSSIM: Double
        let meanR: Double, meanG: Double, meanB: Double, meanA: Double
        let maxR: Int, maxG: Int, maxB: Int, maxA: Int
        let elapsedSec: Double
    }

    private func measureDXT5(corpusDir: URL, label: String) throws -> CorpusStats {
        let t0 = Date()
        var ssims: [Double] = []
        var sumR = 0.0, sumG = 0.0, sumB = 0.0, sumA = 0.0
        var mxR = 0, mxG = 0, mxB = 0, mxA = 0
        var n: Int64 = 0
        let blocks = (Self.codedW / 4) * (Self.codedH / 4)
        let enc = DXT5Encoder()
        try enc.prepare(width: Self.w, height: Self.h, fps: 30, hasAlpha: true)

        for i in 1...Self.frameCount {
            let pngURL = corpusDir.appendingPathComponent(String(format: "frame_%04d.png", i))
            let sourceRGBA = try loadPNGAsRGBA(url: pngURL, w: Self.w, h: Self.h)
            let frame = try makeBGRAPixelFrame(rgba: sourceRGBA,
                                               w: Self.w, h: Self.h,
                                               alphaInfo: .premultipliedFirst)
            let pkt = try enc.encode(frame: frame)
            let (_, payload) = try DXVPacketDecoder.parseHeader(pkt)
            let bc3 = try DXVPacketDecoder.decompressDXT5(payload, expectedSize: blocks * 16)
            let cgImage = try CPURender.cgImageFromDXT(
                dxtBytes: bc3, variant: .dxt5,
                width: Self.codedW, height: Self.codedH)
            let decoded = try extractRGBA(cgImage: cgImage, w: Self.codedW, h: Self.codedH)

            let s = ssim8x8BT709(a: decoded, b: sourceRGBA,
                                 width: Self.w, height: Self.h)
            ssims.append(s)
            let st = perChannelStats(source: sourceRGBA, decoded: decoded)
            sumR += st.meanR; sumG += st.meanG; sumB += st.meanB; sumA += st.meanA
            mxR = max(mxR, st.maxR); mxG = max(mxG, st.maxG); mxB = max(mxB, st.maxB); mxA = max(mxA, st.maxA)
            n += 1
        }
        try enc.finish()

        let frames = Double(max(1, n))
        let elapsed = Date().timeIntervalSince(t0)
        let mean = ssims.reduce(0, +) / Double(ssims.count)
        let minS = ssims.min() ?? 0
        print(String(format: "[5C.4 DXT5 %@] mean SSIM=%.6f min=%.6f | meanΔRGBA=(%.3f, %.3f, %.3f, %.3f) | maxΔRGBA=(%d, %d, %d, %d) | %.2fs",
                     label, mean, minS,
                     sumR/frames, sumG/frames, sumB/frames, sumA/frames,
                     mxR, mxG, mxB, mxA, elapsed))
        return CorpusStats(meanSSIM: mean, minSSIM: minS,
                           meanR: sumR/frames, meanG: sumG/frames,
                           meanB: sumB/frames, meanA: sumA/frames,
                           maxR: mxR, maxG: mxG, maxB: mxB, maxA: mxA,
                           elapsedSec: elapsed)
    }

    private func measureYG10(corpusDir: URL, label: String) throws -> CorpusStats {
        let t0 = Date()
        var ssims: [Double] = []
        var sumR = 0.0, sumG = 0.0, sumB = 0.0, sumA = 0.0
        var mxR = 0, mxG = 0, mxB = 0, mxA = 0
        var n: Int64 = 0
        let enc = YG10Encoder()
        try enc.prepare(width: Self.w, height: Self.h, fps: 30, hasAlpha: true)

        for i in 1...Self.frameCount {
            let pngURL = corpusDir.appendingPathComponent(String(format: "frame_%04d.png", i))
            let sourceRGBA = try loadPNGAsRGBA(url: pngURL, w: Self.w, h: Self.h)
            let frame = try makeBGRAPixelFrame(rgba: sourceRGBA,
                                               w: Self.w, h: Self.h,
                                               alphaInfo: .premultipliedFirst)
            let pkt = try enc.encode(frame: frame)
            let (_, payload) = try DXVPacketDecoder.parseHeader(pkt)
            let result = try DXVHQDecoder.decompressYG10(
                payload: payload,
                codedWidth: Self.codedW, codedHeight: Self.codedH)
            let cgImage = try CPURender.cgImageFromHQ(
                y: result.y, co: result.co, cg: result.cg, a: result.a,
                width: Self.codedW, height: Self.codedH,
                chromaWidth: Self.codedW / 2, chromaHeight: Self.codedH / 2)
            let decoded = try extractRGBA(cgImage: cgImage, w: Self.codedW, h: Self.codedH)

            let s = ssim8x8BT709(a: decoded, b: sourceRGBA,
                                 width: Self.w, height: Self.h)
            ssims.append(s)
            let st = perChannelStats(source: sourceRGBA, decoded: decoded)
            sumR += st.meanR; sumG += st.meanG; sumB += st.meanB; sumA += st.meanA
            mxR = max(mxR, st.maxR); mxG = max(mxG, st.maxG); mxB = max(mxB, st.maxB); mxA = max(mxA, st.maxA)
            n += 1
        }
        try enc.finish()

        let frames = Double(max(1, n))
        let elapsed = Date().timeIntervalSince(t0)
        let mean = ssims.reduce(0, +) / Double(ssims.count)
        let minS = ssims.min() ?? 0
        print(String(format: "[5C.4 YG10 %@] mean SSIM=%.6f min=%.6f | meanΔRGBA=(%.3f, %.3f, %.3f, %.3f) | maxΔRGBA=(%d, %d, %d, %d) | %.2fs",
                     label, mean, minS,
                     sumR/frames, sumG/frames, sumB/frames, sumA/frames,
                     mxR, mxG, mxB, mxA, elapsed))
        return CorpusStats(meanSSIM: mean, minSSIM: minS,
                           meanR: sumR/frames, meanG: sumG/frames,
                           meanB: sumB/frames, meanA: sumA/frames,
                           maxR: mxR, maxG: mxG, maxB: mxB, maxA: mxA,
                           elapsedSec: elapsed)
    }

    /// Single-frame YG10 encode + decode → return decoded RGBA bytes
    /// at codedW × codedH (== presentation dims for 4K).
    private func encodeYG10Frame(sourceRGBA: [UInt8]) throws -> [UInt8] {
        let enc = YG10Encoder()
        try enc.prepare(width: Self.w, height: Self.h, fps: 30, hasAlpha: true)
        let frame = try makeBGRAPixelFrame(rgba: sourceRGBA,
                                           w: Self.w, h: Self.h,
                                           alphaInfo: .premultipliedFirst)
        let pkt = try enc.encode(frame: frame)
        try enc.finish()
        let (_, payload) = try DXVPacketDecoder.parseHeader(pkt)
        let result = try DXVHQDecoder.decompressYG10(
            payload: payload,
            codedWidth: Self.codedW, codedHeight: Self.codedH)
        let cgImage = try CPURender.cgImageFromHQ(
            y: result.y, co: result.co, cg: result.cg, a: result.a,
            width: Self.codedW, height: Self.codedH,
            chromaWidth: Self.codedW / 2, chromaHeight: Self.codedH / 2)
        return try extractRGBA(cgImage: cgImage, w: Self.codedW, h: Self.codedH)
    }

    // MARK: - Reporting

    private func reportABSummary(label: String, off: CorpusStats, on: CorpusStats) {
        print(String(format: "[5C.4 %@ summary] mean SSIM off→on: %.6f → %.6f  (Δ %+.6f)",
                     label, off.meanSSIM, on.meanSSIM, on.meanSSIM - off.meanSSIM))
        print(String(format: "[5C.4 %@ summary] meanΔR off→on: %.3f → %.3f  (Δ %+.3f)",
                     label, off.meanR, on.meanR, on.meanR - off.meanR))
        print(String(format: "[5C.4 %@ summary] meanΔG off→on: %.3f → %.3f  (Δ %+.3f)",
                     label, off.meanG, on.meanG, on.meanG - off.meanG))
        print(String(format: "[5C.4 %@ summary] meanΔB off→on: %.3f → %.3f  (Δ %+.3f)",
                     label, off.meanB, on.meanB, on.meanB - off.meanB))
        print(String(format: "[5C.4 %@ summary] meanΔα off→on: %.3f → %.3f  (Δ %+.3f)",
                     label, off.meanA, on.meanA, on.meanA - off.meanA))
        print(String(format: "[5C.4 %@ summary] wall-clock off=%.2fs on=%.2fs",
                     label, off.elapsedSec, on.elapsedSec))
    }

    // MARK: - Per-channel delta

    struct ChannelStats {
        let meanR: Double, meanG: Double, meanB: Double, meanA: Double
        let maxR: Int, maxG: Int, maxB: Int, maxA: Int
    }

    private func perChannelStats(source: [UInt8], decoded: [UInt8]) -> ChannelStats {
        precondition(source.count == decoded.count)
        precondition(source.count % 4 == 0)
        let n = source.count / 4
        var sumR = 0, sumG = 0, sumB = 0, sumA = 0
        var mxR = 0, mxG = 0, mxB = 0, mxA = 0
        for i in 0..<n {
            let off = i * 4
            let dR = abs(Int(source[off    ]) - Int(decoded[off    ]))
            let dG = abs(Int(source[off + 1]) - Int(decoded[off + 1]))
            let dB = abs(Int(source[off + 2]) - Int(decoded[off + 2]))
            let dA = abs(Int(source[off + 3]) - Int(decoded[off + 3]))
            sumR += dR; sumG += dG; sumB += dB; sumA += dA
            if dR > mxR { mxR = dR }
            if dG > mxG { mxG = dG }
            if dB > mxB { mxB = dB }
            if dA > mxA { mxA = dA }
        }
        return ChannelStats(
            meanR: Double(sumR) / Double(n),
            meanG: Double(sumG) / Double(n),
            meanB: Double(sumB) / Double(n),
            meanA: Double(sumA) / Double(n),
            maxR: mxR, maxG: mxG, maxB: mxB, maxA: mxA)
    }

    // MARK: - SSIM (BT.709 luma, 8×8 non-overlapping, K1=0.01, K2=0.03)

    /// Same SSIM implementation as Phase 2C / 4B — operates on a
    /// BT.709 luma view of the RGBA frames. Matches FFmpeg's `ssim`
    /// filter's configuration for cross-tool comparability.
    private func ssim8x8BT709(a: [UInt8], b: [UInt8],
                              width: Int, height: Int) -> Double {
        let lumaA = rgbaToLumaBT709(a, width: width, height: height)
        let lumaB = rgbaToLumaBT709(b, width: width, height: height)
        let L = 255.0
        let K1 = 0.01, K2 = 0.03
        let C1 = (K1 * L) * (K1 * L)
        let C2 = (K2 * L) * (K2 * L)
        let win = 8
        let N = Double(win * win)
        let rowBlocks = height / win
        let colBlocks = width / win
        var sum = 0.0
        var count = 0
        for by in 0..<rowBlocks {
            for bx in 0..<colBlocks {
                var sumA = 0, sumB = 0, sumAA = 0, sumBB = 0, sumAB = 0
                for ly in 0..<win {
                    for lx in 0..<win {
                        let idx = (by * win + ly) * width + (bx * win + lx)
                        let av = Int(lumaA[idx]), bv = Int(lumaB[idx])
                        sumA  += av;  sumB  += bv
                        sumAA += av*av; sumBB += bv*bv; sumAB += av*bv
                    }
                }
                let muA  = Double(sumA) / N
                let muB  = Double(sumB) / N
                let varA = Double(sumAA) / N - muA * muA
                let varB = Double(sumBB) / N - muB * muB
                let covAB = Double(sumAB) / N - muA * muB
                let num = (2 * muA * muB + C1) * (2 * covAB + C2)
                let den = (muA * muA + muB * muB + C1) * (varA + varB + C2)
                sum += num / den
                count += 1
            }
        }
        return sum / Double(count)
    }

    private func rgbaToLumaBT709(_ rgba: [UInt8], width: Int, height: Int) -> [UInt8] {
        var luma = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let off = (y * width + x) * 4
                let r = Int(rgba[off    ])
                let g = Int(rgba[off + 1])
                let b = Int(rgba[off + 2])
                // BT.709: Y' = 0.2126R + 0.7152G + 0.0722B
                // Coefficients ×65536 + 32768 rounding bias.
                let yval = (13933 * r + 46871 * g + 4732 * b + 32768) >> 16
                luma[y * width + x] = UInt8(min(255, max(0, yval)))
            }
        }
        return luma
    }

    // MARK: - PNG loaders / CGImage extraction

    /// Load a PNG into a tightly-packed RGBA byte buffer at the given
    /// dimensions. Bytes are premultiplied alpha (matching what
    /// CGContext writes by default).
    private func loadPNGAsRGBA(url: URL, w: Int, h: Int) throws -> [UInt8] {
        guard let imgSrc = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imgSrc, 0, nil)
        else { throw NSError(domain: "5C4", code: 1) }
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        try rgba.withUnsafeMutableBufferPointer { buf in
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            let bmpInfo = CGImageAlphaInfo.premultipliedLast.rawValue
                        | CGBitmapInfo.byteOrder32Big.rawValue
            guard let ctx = CGContext(
                data: buf.baseAddress, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: space, bitmapInfo: bmpInfo
            ) else { throw NSError(domain: "5C4", code: 2) }
            ctx.setBlendMode(.copy)
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return rgba
    }

    /// Wrap a premultiplied-RGBA byte buffer in a 32BGRA CVPixelBuffer
    /// and return as PixelFrame with the requested alpha-info semantics.
    private func makeBGRAPixelFrame(
        rgba: [UInt8], w: Int, h: Int, alphaInfo: CGImageAlphaInfo
    ) throws -> PixelFrame {
        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(nil, w, h,
                                         kCVPixelFormatType_32BGRA, nil, &pb)
        guard status == kCVReturnSuccess, let buf = pb else {
            throw NSError(domain: "5C4", code: 3)
        }
        CVPixelBufferLockBaseAddress(buf, [])
        let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(buf)
        rgba.withUnsafeBufferPointer { rgbaBuf in
            let src = rgbaBuf.baseAddress!
            for y in 0..<h {
                let srcRow = src.advanced(by: y * w * 4)
                let dstRow = base.advanced(by: y * bpr)
                for x in 0..<w {
                    let s = srcRow.advanced(by: x * 4)
                    let d = dstRow.advanced(by: x * 4)
                    // RGBA → BGRA swizzle.
                    d[0] = s[2]   // B ← B (src offset 2)
                    d[1] = s[1]   // G
                    d[2] = s[0]   // R ← R (src offset 0)
                    d[3] = s[3]   // A
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buf, [])
        return PixelFrame(pixelBuffer: buf, presentationTime: .zero,
                          alphaInfo: alphaInfo)
    }

    /// Extract RGBA bytes from a CGImage at the requested dims by
    /// re-rendering into a packed RGBA CGContext.
    private func extractRGBA(cgImage: CGImage, w: Int, h: Int) throws -> [UInt8] {
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        try rgba.withUnsafeMutableBufferPointer { buf in
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            let bmpInfo = CGImageAlphaInfo.premultipliedLast.rawValue
                        | CGBitmapInfo.byteOrder32Big.rawValue
            guard let ctx = CGContext(
                data: buf.baseAddress, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: space, bitmapInfo: bmpInfo
            ) else { throw NSError(domain: "5C4", code: 4) }
            ctx.setBlendMode(.copy)
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return rgba
    }
}

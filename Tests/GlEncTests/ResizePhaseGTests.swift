/*
 * ResizePhaseGTests — Resize Release Phase G (aspect handling).
 *
 * Two test classes:
 *
 *   LetterboxFitTests — pure math on letterboxRect(). Asserts on
 *     16:9-into-square (letterbox), 9:16-into-wide (pillarbox),
 *     matched-aspect (no bars), 4-pixel alignment of inner dims,
 *     centering symmetry.
 *
 *   ResizePhaseGEndToEndTests — drives an EncodePipeline with
 *     .letterbox + .distortToFill against a 1920×1080 source and a
 *     1080×1080 square target. Decodes the output, samples bar +
 *     image regions, asserts on pixel properties (bars opaque
 *     black, center is image content). .original byte-identity for
 *     DXV3 is covered by the broader suite — exit 0 of the full
 *     run proves it.
 *
 * Expected dims are computed from first principles (not pasted from
 * emitted output) per the standing rule.
 */

import XCTest
import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
@testable import GlEnc
@testable import GlEncCore
import GlanceCore

// MARK: - LetterboxFit math

final class LetterboxFitTests: XCTestCase {

    /// 16:9 source into a square target → letterbox (top + bottom
    /// bars). For src=(1920,1080), dst=(1080,1080):
    ///   raw innerH = 1080 * 1080 / 1920 = 607.5 → integer 607
    ///   round-to-4 of 607: nearest 4-mult to 607 is 608 (607+2=609, /4=152, *4=608)
    ///   innerW = 1080, innerH = 608
    ///   insetY = (1080 - 608) / 2 = 236, insetX = 0
    func testWideSourceIntoSquareGivesLetterbox() {
        let r = letterboxRect(sourceWidth: 1920, sourceHeight: 1080,
                              targetWidth: 1080, targetHeight: 1080)
        XCTAssertEqual(r.width, 1080)
        XCTAssertEqual(r.height, 608)
        XCTAssertEqual(r.insetX, 0)
        XCTAssertEqual(r.insetY, 236)
    }

    /// 9:16 source into a wide target → pillarbox (left + right
    /// bars). For src=(1080,1920), dst=(1920,1080):
    ///   raw innerW = 1080 * 1080 / 1920 = 607.5 → integer 607
    ///   round-to-4 of 607 → 608
    ///   innerH = 1080, innerW = 608, insetX = (1920-608)/2 = 656
    func testTallSourceIntoWideGivesPillarbox() {
        let r = letterboxRect(sourceWidth: 1080, sourceHeight: 1920,
                              targetWidth: 1920, targetHeight: 1080)
        XCTAssertEqual(r.width, 608)
        XCTAssertEqual(r.height, 1080)
        XCTAssertEqual(r.insetX, 656)
        XCTAssertEqual(r.insetY, 0)
    }

    /// Matched aspect — src 16:9 into dst 16:9. Inner rect fills the
    /// target, no bars. fillsCanvas() returns true.
    func testMatchedAspect16x9() {
        let r = letterboxRect(sourceWidth: 1920, sourceHeight: 1080,
                              targetWidth: 1280, targetHeight: 720)
        XCTAssertEqual(r.width, 1280)
        XCTAssertEqual(r.height, 720)
        XCTAssertEqual(r.insetX, 0)
        XCTAssertEqual(r.insetY, 0)
        XCTAssertTrue(r.fillsCanvas(canvasWidth: 1280, canvasHeight: 720))
    }

    /// Equal dims — degenerate matched aspect, fillsCanvas() true.
    func testEqualDimsMatched() {
        let r = letterboxRect(sourceWidth: 1920, sourceHeight: 1080,
                              targetWidth: 1920, targetHeight: 1080)
        XCTAssertTrue(r.fillsCanvas(canvasWidth: 1920, canvasHeight: 1080))
    }

    /// Inner rect dims are always 4-pixel-aligned.
    func testInnerDimsAreFourPixelAligned() {
        let cases: [(srcW: Int, srcH: Int, dstW: Int, dstH: Int)] = [
            (1920, 1080, 1024, 1024),  // landscape into square
            (1080, 1920, 1024, 1024),  // portrait into square
            (1920, 1080, 2048, 1080),  // landscape into wider landscape
            (1280, 720,  1920, 1080),  // matched aspect at different size
            (1920, 1080, 720, 1280),   // wide into tall
        ]
        for c in cases {
            let r = letterboxRect(sourceWidth: c.srcW, sourceHeight: c.srcH,
                                  targetWidth: c.dstW, targetHeight: c.dstH)
            XCTAssertEqual(r.width % 4, 0, "innerW \(r.width) not 4-mult for \(c)")
            XCTAssertEqual(r.height % 4, 0, "innerH \(r.height) not 4-mult for \(c)")
        }
    }

    /// Inner rect never exceeds the target rect.
    func testInnerRectFitsTarget() {
        let cases: [(srcW: Int, srcH: Int, dstW: Int, dstH: Int)] = [
            (1920, 1080, 1024, 1024),
            (1080, 1920, 1024, 1024),
            (3840, 2160, 1280, 720),
        ]
        for c in cases {
            let r = letterboxRect(sourceWidth: c.srcW, sourceHeight: c.srcH,
                                  targetWidth: c.dstW, targetHeight: c.dstH)
            XCTAssertLessThanOrEqual(r.insetX + r.width, c.dstW)
            XCTAssertLessThanOrEqual(r.insetY + r.height, c.dstH)
            XCTAssertGreaterThanOrEqual(r.insetX, 0)
            XCTAssertGreaterThanOrEqual(r.insetY, 0)
        }
    }

    /// Bars are split symmetrically (within 1 pixel for odd gaps).
    /// 1920×1080 → 1080×1080: vertical gap = 1080-608 = 472, split
    /// as 236+236. The even-gap symmetric case.
    func testBarSymmetryEvenGap() {
        let r = letterboxRect(sourceWidth: 1920, sourceHeight: 1080,
                              targetWidth: 1080, targetHeight: 1080)
        let topBar = r.insetY
        let botBar = 1080 - (r.insetY + r.height)
        XCTAssertEqual(topBar, botBar)
    }

    /// roundToFourMultiple's clamping + tie behavior is shared with
    /// Phase F's UI helper. Spot-check the boundary cases here too
    /// to lock the math file's behavior.
    func testRoundToFourMultipleBoundaries() {
        XCTAssertEqual(roundToFourMultiple(0), 4)
        XCTAssertEqual(roundToFourMultiple(-100), 4)
        XCTAssertEqual(roundToFourMultiple(1), 4)
        XCTAssertEqual(roundToFourMultiple(607), 608)
        XCTAssertEqual(roundToFourMultiple(608), 608)
        XCTAssertEqual(roundToFourMultiple(609), 608)
        XCTAssertEqual(roundToFourMultiple(610), 612)
    }
}

// MARK: - End-to-end letterbox encode

@MainActor
final class ResizePhaseGEndToEndTests: XCTestCase {

    private static var sharedSourceURL: URL?

    /// Build a 1920×1080 procedural H.264 source where every pixel is
    /// solid red. Solid color is the easiest signal for distinguishing
    /// "image content" from "letterbox bar": bars are (0,0,0,255) by
    /// the Phase G contract; image pixels decode to red-ish (not exact
    /// due to DXT1 quantization, but R >> G,B).
    private func makeSolidRedSource() throws -> URL {
        if let url = Self.sharedSourceURL, FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        let dst = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("resize-phaseG-red-\(UUID().uuidString).mov")
        let w = 1920, h = 1080, fps: Int32 = 30, frames = 4
        let writer = try AVAssetWriter(outputURL: dst, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: w,
                kCVPixelBufferHeightKey as String: h,
            ])
        writer.add(input)
        guard writer.startWriting() else {
            throw NSError(domain: "PhaseG", code: 1)
        }
        writer.startSession(atSourceTime: .zero)
        for i in 0..<frames {
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, nil, &pb)
            guard let buf = pb else { throw NSError(domain: "PhaseG", code: 2) }
            CVPixelBufferLockBaseAddress(buf, [])
            let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
            let bpr = CVPixelBufferGetBytesPerRow(buf)
            for y in 0..<h {
                let row = base.advanced(by: y * bpr)
                for x in 0..<w {
                    let p = row.advanced(by: x * 4)
                    p[0] = 0       // B
                    p[1] = 0       // G
                    p[2] = 0xFF    // R
                    p[3] = 0xFF    // A
                }
            }
            CVPixelBufferUnlockBaseAddress(buf, [])
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.001) }
            let pts = CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps))
            adaptor.append(buf, withPresentationTime: pts)
        }
        input.markAsFinished()
        let sema = DispatchSemaphore(value: 0)
        writer.finishWriting { sema.signal() }
        sema.wait()
        Self.sharedSourceURL = dst
        return dst
    }

    /// Drive an EncodePipeline (DXT1 + DXVMOVWriter) and return the
    /// output URL. Mirrors the Phase E test driver, additionally
    /// taking aspectMode.
    private func runPipeline(
        sourceURL: URL,
        outputSize: OutputSize,
        aspectMode: AspectMode
    ) async throws -> URL {
        let outURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("phaseG-out-\(UUID().uuidString).mov")
        let pipeline = EncodePipeline(
            sourceURL: sourceURL,
            encoder: DXT1Encoder(),
            makeWriter: { w, h, fps in
                try DXVMOVWriter(
                    destURL: outURL,
                    format: .dxt1,
                    presentationWidth: w,
                    presentationHeight: h,
                    fps: fps,
                    codecFourCC: DXVFormat.dxt1.streamFourCC)
            },
            sourceAlphaInfo: .noneSkipLast,
            outputSize: outputSize,
            resizeQuality: .bilinear,  // explicit; .auto would pick lanczos
            aspectMode: aspectMode)
        try await pipeline.run()
        return outURL
    }

    /// Decode the first frame of `outURL` (DXT1) to an RGBA byte
    /// grid at the encoder's CODED dims (16-pixel-aligned, ≥ target).
    /// Uses the same path Phase 2 / RoundTripAndPipelineTests use:
    /// MOVFrameExtractor → DXVPacketDecoder → CPURender.
    private func decodeFirstFrame(_ outURL: URL, codedW: Int, codedH: Int) throws -> [UInt8] {
        let extractor = try MOVFrameExtractor(url: outURL)
        let packet = extractor.frameData(at: 0)
        let (_, payload) = try DXVPacketDecoder.parseHeader(packet)
        let blocks = (codedW / 4) * (codedH / 4)
        let bc1 = try DXVPacketDecoder.decompressDXT1(payload, expectedSize: blocks * 8)
        let cgImage = try CPURender.cgImageFromDXT(
            dxtBytes: bc1, variant: .dxt1,
            width: codedW, height: codedH)
        guard let provider = cgImage.dataProvider,
              let providerData = provider.data,
              CFDataGetLength(providerData) >= codedW * codedH * 4
        else {
            throw NSError(domain: "PhaseG", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "CGImage data provider missing"])
        }
        return [UInt8](
            UnsafeBufferPointer(
                start: CFDataGetBytePtr(providerData),
                count: codedW * codedH * 4))
    }

    /// Sample a region of an RGBA buffer (CPURender layout: R G B A)
    /// and return mean per-channel byte value.
    private func meanRGBA(_ rgba: [UInt8], width: Int, x0: Int, y0: Int, w: Int, h: Int)
        -> (r: Double, g: Double, b: Double, a: Double) {
        var sR = 0, sG = 0, sB = 0, sA = 0, n = 0
        for y in y0..<(y0 + h) {
            for x in x0..<(x0 + w) {
                let i = (y * width + x) * 4
                sR += Int(rgba[i + 0])
                sG += Int(rgba[i + 1])
                sB += Int(rgba[i + 2])
                sA += Int(rgba[i + 3])
                n += 1
            }
        }
        return (Double(sR) / Double(n),
                Double(sG) / Double(n),
                Double(sB) / Double(n),
                Double(sA) / Double(n))
    }

    /// 1920×1080 red source into a 1080×1080 square with .letterbox:
    ///   - output dims = 1080×1080
    ///   - top bar (rows 0..236) and bottom bar (rows 844..1080) are
    ///     ~black, alpha 255
    ///   - center band (rows 236..844, cols 0..1080) is red-dominated
    func testLetterbox16x9To1080Square() async throws {
        let src = try makeSolidRedSource()
        let out = try await runPipeline(
            sourceURL: src,
            outputSize: .custom(width: 1080, height: 1080),
            aspectMode: .letterbox)
        defer { try? FileManager.default.removeItem(at: out) }

        // Encoder coded dims = round up presentation dims to 16. 1080
        // → 1088 on both axes for the square preset.
        let codedW = 1088, codedH = 1088
        let rgba = try decodeFirstFrame(out, codedW: codedW, codedH: codedH)

        // Top bar — rows 0..200 should be ~black (allow slight DXT1
        // quantization slop, but channels << 32 for solid black).
        let top = meanRGBA(rgba, width: codedW, x0: 100, y0: 50, w: 200, h: 100)
        XCTAssertLessThan(top.r, 16, "top bar should be ~black, got R=\(top.r)")
        XCTAssertLessThan(top.g, 16, "top bar should be ~black, got G=\(top.g)")
        XCTAssertLessThan(top.b, 16, "top bar should be ~black, got B=\(top.b)")

        // Bottom bar — rows 900..1000 inside presentation 1080. (Coded
        // 1088 has 8 padding rows after the presentation area — those
        // padding rows can be any value; we stay inside row 1000.)
        let bot = meanRGBA(rgba, width: codedW, x0: 100, y0: 900, w: 200, h: 80)
        XCTAssertLessThan(bot.r, 16, "bottom bar should be ~black, got R=\(bot.r)")
        XCTAssertLessThan(bot.g, 16, "bottom bar should be ~black, got G=\(bot.g)")
        XCTAssertLessThan(bot.b, 16, "bottom bar should be ~black, got B=\(bot.b)")

        // Center — rows 400..600, cols 400..600 — solid red.
        // DXT1 quantizes red but the dominant channel survives.
        let mid = meanRGBA(rgba, width: codedW, x0: 400, y0: 400, w: 200, h: 200)
        XCTAssertGreaterThan(mid.r, 200, "center should be red-dominated, got R=\(mid.r)")
        XCTAssertLessThan(mid.g, 32,     "center red has low green, got G=\(mid.g)")
        XCTAssertLessThan(mid.b, 32,     "center red has low blue,  got B=\(mid.b)")
    }

    /// .distortToFill on same scenario — bars should NOT exist. The
    /// entire 1080×1080 frame is the (stretched) red source, so
    /// every sampled region is red-dominated.
    func testDistortToFillFillsFrameNoBars() async throws {
        let src = try makeSolidRedSource()
        let out = try await runPipeline(
            sourceURL: src,
            outputSize: .custom(width: 1080, height: 1080),
            aspectMode: .distortToFill)
        defer { try? FileManager.default.removeItem(at: out) }

        let codedW = 1088, codedH = 1088
        let rgba = try decodeFirstFrame(out, codedW: codedW, codedH: codedH)

        // Sample the same top-bar region — should be red, not black.
        let top = meanRGBA(rgba, width: codedW, x0: 100, y0: 50, w: 200, h: 100)
        XCTAssertGreaterThan(top.r, 200,
                              ".distortToFill should have no top bar — full red expected, got R=\(top.r)")
        XCTAssertLessThan(top.g, 32)
        XCTAssertLessThan(top.b, 32)

        // Bottom too — still inside presentation rows (< 1080).
        let bot = meanRGBA(rgba, width: codedW, x0: 100, y0: 950, w: 200, h: 80)
        XCTAssertGreaterThan(bot.r, 200,
                              ".distortToFill should have no bottom bar — full red expected")
    }

    /// .letterbox with matched aspect (16:9 source → 1280×720 16:9
    /// target) should behave EXACTLY like .distortToFill: no bars,
    /// straight resize. The fillsCanvas() fast path is the contract.
    func testLetterboxMatchedAspectHasNoBars() async throws {
        let src = try makeSolidRedSource()
        let out = try await runPipeline(
            sourceURL: src,
            outputSize: .preset(.hd_1280_720),
            aspectMode: .letterbox)
        defer { try? FileManager.default.removeItem(at: out) }

        // 1280 / 720 are both 16-mult → coded == presentation.
        let codedW = 1280, codedH = 720
        let rgba = try decodeFirstFrame(out, codedW: codedW, codedH: codedH)

        // Top corner — should be red (no letterbox bar).
        let corner = meanRGBA(rgba, width: codedW, x0: 50, y0: 20, w: 100, h: 100)
        XCTAssertGreaterThan(corner.r, 200,
                              "matched aspect should have no bars — full red expected, got R=\(corner.r)")
        XCTAssertLessThan(corner.g, 32)
        XCTAssertLessThan(corner.b, 32)
    }
}

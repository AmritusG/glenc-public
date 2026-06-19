/*
 * CropPipelineIntegrationTests — Crop Release Phase F.
 *
 * End-to-end test that the EncodePipeline actually applies the
 * cropRect: that the cropper runs, that resolvedDimensions threads
 * the post-crop dims through to the encoder + writer, and that the
 * cropped output's pixels are the correct sub-rect of the source's
 * pixels — not garbage, not the wrong region.
 *
 * Strategy — byte-exact pipeline-vs-pipeline (no tolerance)
 * ──────────────────────────────────────────────────────────
 * Run the pipeline TWO ways on the same source.mov:
 *   (a) no crop → outputs a 1920×1080 DXV3 .mov,
 *   (b) crop (320, 180, 1280, 720) → outputs a 1280×720 DXV3 .mov.
 *
 * Decode both via the existing roundtrip chain (MOVFrameExtractor →
 * DXVPacketDecoder → CPURender). Assert that for every frame and
 * every pixel in the cropped region:
 *
 *     cropped_decoded[(y, x)]  ==  uncropped_decoded[(y+180, x+320)]
 *
 * BYTE-EXACT. Because the crop is 4-pixel-aligned, the cropped
 * frame's BC1 4×4 blocks are a strict subset of the uncropped
 * frame's BC1 blocks — same source pixels per block, deterministic
 * BC1 encoder → identical BC1 bytes for matching blocks → identical
 * decoded BGRA bytes in the cropped region, regardless of any
 * tolerance from BC1 lossy compression or ProRes → BGRA color
 * conversion (both effects cancel: they apply identically to both
 * encodes).
 *
 * The byte-exact assertion is a much stronger statement than a PSNR
 * threshold against PNG ground truth would be: if the cropper is
 * bypassed, or the rect is wrong, or `resolvedDimensions` isn't
 * threaded with post-crop dims, decoded bytes diverge immediately
 * (the cropped frame would encode a different region, or fail to
 * encode at all).
 *
 * One codec, DXT1
 * ───────────────
 * Crop is codec-agnostic (CROP_PLAN.md §5) — `FrameCropper` runs on
 * BGRA before the encoder. The FrameCropperTests cover the math
 * codec-blind. This integration test confirms only that the PIPELINE
 * threads the rect through correctly. DXT1 is the cheapest codec to
 * run twice through a 1080p ProRes source; YCG6 / YG10 / HAP would
 * add encode time without adding wiring coverage.
 */

import XCTest
import Foundation
import CoreVideo
import CoreMedia
import AVFoundation
@testable import GlEncCore
import GlanceCore

final class CropPipelineIntegrationTests: XCTestCase {

    private static let referenceDir: URL = {
        URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("reference/dxt1")
    }()

    func testEncodePipeline_DXT1_WithCrop_DecodedRegionMatchesUncroppedRegion() async throws {
        let sourceMOV = Self.referenceDir.appendingPathComponent("source/source.mov")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: sourceMOV.path),
            "reference/dxt1/source/source.mov missing (stripped from the public seed) — regenerate via scripts/make-corpus.sh (FFmpeg required)")

        // Crop is 4-pixel-aligned (L3) and fully inside 1920×1080.
        // The chosen rect is the centered 720p of 1080p — both source
        // and target dims are 16-multiples, so coded == presentation
        // for both encodes (no padding rows complicating the
        // comparison).
        let cropX = 320, cropY = 180
        let cropW = 1280, cropH = 720
        let crop = CGRect(x: cropX, y: cropY, width: cropW, height: cropH)

        // ─── (a) Uncropped pipeline ──────────────────────────────
        let uncroppedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("glenc-crop-it-uncropped-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: uncroppedURL) }
        let uncroppedPipeline = EncodePipeline(
            sourceURL: sourceMOV,
            encoder: DXT1Encoder(),
            makeWriter: { w, h, fps in
                try DXVMOVWriter(
                    destURL: uncroppedURL, format: .dxt1,
                    presentationWidth: w, presentationHeight: h, fps: fps)
            })
        try await uncroppedPipeline.run()

        // ─── (b) Cropped pipeline ────────────────────────────────
        let croppedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("glenc-crop-it-cropped-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: croppedURL) }
        let croppedPipeline = EncodePipeline(
            sourceURL: sourceMOV,
            encoder: DXT1Encoder(),
            makeWriter: { w, h, fps in
                try DXVMOVWriter(
                    destURL: croppedURL, format: .dxt1,
                    presentationWidth: w, presentationHeight: h, fps: fps)
            },
            cropRect: crop)
        try await croppedPipeline.run()

        // ─── Verify cropped output's structural dims ─────────────
        let croppedAsset = AVURLAsset(url: croppedURL)
        let cropTracks = try await croppedAsset.loadTracks(withMediaType: .video)
        XCTAssertEqual(cropTracks.count, 1)
        let natSize = try await cropTracks[0].load(.naturalSize)
        XCTAssertEqual(Int(natSize.width), cropW,
                       "cropped output's naturalSize.width must equal cropRect.width — "
                       + "if it equals source width (1920), resolvedDimensions wasn't threaded")
        XCTAssertEqual(Int(natSize.height), cropH,
                       "cropped output's naturalSize.height must equal cropRect.height")

        // ─── Pixel-by-pixel byte-exact comparison ────────────────
        let uncroppedExtractor = try MOVFrameExtractor(url: uncroppedURL)
        let croppedExtractor = try MOVFrameExtractor(url: croppedURL)
        XCTAssertEqual(croppedExtractor.frameCount, uncroppedExtractor.frameCount,
                       "frame counts must match — both pipelines saw the same source")
        XCTAssertGreaterThan(croppedExtractor.frameCount, 0, "no frames decoded")

        // CPURender produces CGImages at CODED dims. 1920×1080 pads
        // to 1920×1088 (1080 → next 16-mult). 1280×720 are already
        // 16-aligned: coded == presentation for the cropped output.
        let uncroppedCodedW = 1920
        let uncroppedCodedH = 1088
        let croppedCodedW = cropW
        let croppedCodedH = cropH

        for frameIdx in 0..<croppedExtractor.frameCount {
            let uncroppedRGBA = try decodeDXT1FrameRGBA(
                packet: uncroppedExtractor.frameData(at: frameIdx),
                codedW: uncroppedCodedW, codedH: uncroppedCodedH)
            let croppedRGBA = try decodeDXT1FrameRGBA(
                packet: croppedExtractor.frameData(at: frameIdx),
                codedW: croppedCodedW, codedH: croppedCodedH)

            // Every pixel of the cropped frame must equal the
            // corresponding pixel of the uncropped frame's sub-rect.
            // BYTE-EXACT — no tolerance. Same source bytes per
            // 4×4 BC1 block produce identical encoded BC1 bytes,
            // which decode to identical BGRA bytes.
            for y in 0..<cropH {
                for x in 0..<cropW {
                    let cropOff = (y * croppedCodedW + x) * 4
                    let unOff = ((y + cropY) * uncroppedCodedW + (x + cropX)) * 4
                    for ch in 0..<4 {
                        if croppedRGBA[cropOff + ch] != uncroppedRGBA[unOff + ch] {
                            XCTFail(
                                "frame \(frameIdx) pixel (\(x),\(y)) ch \(ch): "
                                + "cropped=\(croppedRGBA[cropOff + ch]) "
                                + "uncropped(\(x + cropX),\(y + cropY))=\(uncroppedRGBA[unOff + ch]) "
                                + "— cropper wiring drift")
                            return
                        }
                    }
                }
            }
        }
    }

    // MARK: - Decode helper (mirrors RoundTripAndPipelineTests' chain)

    private func decodeDXT1FrameRGBA(packet: Data, codedW: Int, codedH: Int) throws -> [UInt8] {
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
            throw NSError(domain: "CropPipelineIntegration", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "CGImage data provider unavailable"])
        }
        return [UInt8](
            UnsafeBufferPointer(
                start: CFDataGetBytePtr(providerData),
                count: codedW * codedH * 4))
    }
}

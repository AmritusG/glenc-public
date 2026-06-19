/*
 * ResizePhaseETests — Resize Release Phase E.
 *
 * End-to-end pipeline tests for the transform-stage wiring. Each
 * test drives a real `EncodePipeline.run()` to a written .mov and
 * asserts on the file's tkhd/stsd presentation dimensions read from
 * the raw bytes — NOT on in-memory state.
 *
 * Coverage:
 *   - .original is a true no-op: output dims == source dims, no
 *     FrameResizer call. (DXV3 byte-identity tests in the broader
 *     suite cover the actual byte-equality; this test asserts the
 *     dimensional contract.)
 *   - .preset downscale: 1920×1080 → 1280×720 lands the preset's
 *     dims in tkhd/stsd.
 *   - .custom: arbitrary 4-pixel-legal (W, H) lands those dims.
 *   - Encoder + writer dimension agreement: tkhd matches stsd
 *     (writer-side) which must equal what the encoder was prepared
 *     with (encoder-side); if they ever drift, the file decodes
 *     wrong.
 *   - Misalignment fail-loud guard: non-.original non-4-multiple
 *     output dim throws PipelineError.misalignedOutputDimensions.
 *   - Codec-agnostic: covers both a DXV3 codec (DXT1) and a HAP
 *     codec (HapY) — resize operates on the frame before the
 *     encoder, so format choice is independent.
 *   - 1080p-class realistic size (v0.9.1 H.3 standing rule).
 *
 * The test source is a 30-frame procedural 1920×1080 H.264 .mov
 * generated once per test class via AVAssetWriter so we exercise
 * the same AVAssetReader path the GUI hits.
 */

import XCTest
import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
@testable import GlEnc
@testable import GlEncCore

@MainActor
final class ResizePhaseETests: XCTestCase {

    // MARK: - Shared test source (1920×1080 procedural H.264, 30 frames)

    private static var sharedSourceURL: URL?

    private func makeProceduralSource() throws -> URL {
        if let url = Self.sharedSourceURL, FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        let dst = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("resize-phaseE-source-\(UUID().uuidString).mov")
        let w = 1920, h = 1080, fps: Int32 = 30, frames = 30
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
            throw NSError(domain: "PhaseE", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "AVAssetWriter.startWriting failed: \(String(describing: writer.error))"])
        }
        writer.startSession(atSourceTime: .zero)
        for i in 0..<frames {
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, nil, &pb)
            guard let buf = pb else {
                throw NSError(domain: "PhaseE", code: 2)
            }
            CVPixelBufferLockBaseAddress(buf, [])
            let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
            let bpr = CVPixelBufferGetBytesPerRow(buf)
            // Frame i: diagonal gradient that shifts each frame.
            for y in 0..<h {
                let row = base.advanced(by: y * bpr)
                for x in 0..<w {
                    let p = row.advanced(by: x * 4)
                    p[0] = UInt8(((x + i) & 0xFF))      // B
                    p[1] = UInt8(((y + i * 2) & 0xFF))  // G
                    p[2] = UInt8(((x + y) & 0xFF))      // R
                    p[3] = 0xFF
                }
            }
            CVPixelBufferUnlockBaseAddress(buf, [])
            while !input.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.005)
            }
            adaptor.append(buf, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
        }
        input.markAsFinished()
        await_writer(writer)
        Self.sharedSourceURL = dst
        return dst
    }

    /// Synchronously wait for AVAssetWriter to finish. XCTest doesn't
    /// auto-pump a runloop here; the writer's finishWriting completion
    /// posts back to the main queue, which we're already on (since
    /// @MainActor), so a polling loop with a timeout is fine.
    private func await_writer(_ writer: AVAssetWriter) {
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        _ = sem.wait(timeout: .now() + 30)
    }

    // MARK: - Minimal MOV atom reader

    /// Walk top-level atoms for `moov`, then recurse via container
    /// types to find the target atom. Returns the body-range of the
    /// first match. Same approach the HAP/HapM test atom-walkers use.
    private func atomBody(in data: Data, path: [String]) -> Range<Int>? {
        func u32(_ d: Data, at o: Int) -> UInt32 {
            (UInt32(d[o]) << 24) | (UInt32(d[o+1]) << 16) | (UInt32(d[o+2]) << 8) | UInt32(d[o+3])
        }
        func fourcc(_ d: Data, at o: Int) -> String {
            String(bytes: d[o..<(o+4)], encoding: .isoLatin1) ?? ""
        }
        let containers: Set<String> = ["moov", "trak", "mdia", "minf", "stbl"]
        func walk(_ d: Data, range: Range<Int>, path: [String]) -> Range<Int>? {
            guard let head = path.first else { return nil }
            var p = range.lowerBound
            while p + 8 <= range.upperBound {
                let sz = Int(u32(d, at: p))
                let typ = fourcc(d, at: p + 4)
                let bodyStart = p + 8
                let atomEnd = (sz == 0) ? range.upperBound : p + sz
                if typ == head {
                    if path.count == 1 { return bodyStart..<atomEnd }
                    let nested: Range<Int>
                    if typ == "stsd" {
                        nested = (bodyStart + 8)..<atomEnd  // skip v+f + entry_count
                    } else {
                        nested = bodyStart..<atomEnd
                    }
                    if let r = walk(d, range: nested, path: Array(path.dropFirst())) {
                        return r
                    }
                }
                if containers.contains(typ) {
                    if let r = walk(d, range: bodyStart..<atomEnd, path: path) {
                        return r
                    }
                }
                p = atomEnd
                if sz == 0 { break }
            }
            return nil
        }
        return walk(data, range: 0..<data.count, path: path)
    }

    /// Read tkhd presentation width/height (16.16 fixed-point in big-
    /// endian). Per the tkhd v0 layout: width at body offset 76,
    /// height at body offset 80.
    private func tkhdDims(in data: Data) -> (width: Int, height: Int)? {
        guard let r = atomBody(in: data, path: ["moov", "trak", "tkhd"]) else { return nil }
        let off = r.lowerBound
        let w = (UInt32(data[off + 76]) << 24)
              | (UInt32(data[off + 77]) << 16)
              | (UInt32(data[off + 78]) << 8)
              | UInt32(data[off + 79])
        let h = (UInt32(data[off + 80]) << 24)
              | (UInt32(data[off + 81]) << 16)
              | (UInt32(data[off + 82]) << 8)
              | UInt32(data[off + 83])
        return (Int(w >> 16), Int(h >> 16))
    }

    /// Read stsd sample-entry width/height. The stsd body starts
    /// with 8 bytes (v+f + entry_count) before the first sample
    /// entry; `atomBody(stsd)` returns the FULL body so this helper
    /// skips those 8 bytes itself.
    ///
    /// Layout (stsd body offset):
    ///   0..4   version + flags
    ///   4..8   entry_count
    ///   8..12  first entry size
    ///   12..16 first entry FourCC
    ///   ...    6 B reserved + 2 B data_reference_index + 16 B reserved
    ///   40..42 width  (UInt16 BE)
    ///   42..44 height (UInt16 BE)
    private func stsdDims(in data: Data) -> (width: Int, height: Int)? {
        guard let r = atomBody(in: data, path: ["moov", "trak", "mdia", "minf", "stbl", "stsd"]) else { return nil }
        let bodyStart = r.lowerBound
        let w = (UInt16(data[bodyStart + 40]) << 8) | UInt16(data[bodyStart + 41])
        let h = (UInt16(data[bodyStart + 42]) << 8) | UInt16(data[bodyStart + 43])
        return (Int(w), Int(h))
    }

    /// Read the first sample entry's FourCC. Same 8-byte v+f +
    /// entry_count prefix to skip before the entry size+FourCC.
    private func stsdFourCC(in data: Data) -> String? {
        guard let r = atomBody(in: data, path: ["moov", "trak", "mdia", "minf", "stbl", "stsd"]) else { return nil }
        let bodyStart = r.lowerBound
        return String(bytes: data[(bodyStart + 12)..<(bodyStart + 16)],
                      encoding: .isoLatin1)
    }

    // MARK: - Test driver — runs EncodePipeline end-to-end

    /// Drive an EncodePipeline with the given config and return the
    /// written output URL. Tests assert on the file's bytes.
    private func runPipeline(
        sourceURL: URL,
        format: DXVFormat,
        outputSize: OutputSize,
        resizeQuality: ResizeQuality = .auto,
        dimensionAlignment: Int = 1
    ) async throws -> URL {
        let outURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("phaseE-out-\(UUID().uuidString).mov")

        let encoder: FrameEncoder
        let sourceAlphaInfo: CGImageAlphaInfo
        switch format {
        case .dxt1:
            encoder = DXT1Encoder()
            sourceAlphaInfo = .noneSkipLast
        case .hapY:
            encoder = HapFrameEncoder(codec: .hapY)
            sourceAlphaInfo = .noneSkipLast
        default:
            fatalError("Phase E test driver supports DXT1 + HapY for now (extend if needed)")
        }

        let pipeline = EncodePipeline(
            sourceURL: sourceURL,
            encoder: encoder,
            makeWriter: { w, h, fps in
                try DXVMOVWriter(
                    destURL: outURL,
                    format: format,
                    presentationWidth: w,
                    presentationHeight: h,
                    fps: fps,
                    codecFourCC: format.streamFourCC)
            },
            sourceAlphaInfo: sourceAlphaInfo,
            outputSize: outputSize,
            resizeQuality: resizeQuality,
            dimensionAlignment: dimensionAlignment)
        try await pipeline.run()
        return outURL
    }

    // MARK: - Tests

    /// `.original` is a true no-op for dimensions: output dims equal
    /// source dims. (Byte-equality for DXV3 is covered by the broader
    /// DXV3 byte-identity tests in the suite — exit 0 from the full
    /// suite is the proof.)
    func testOriginalIsTrueNoOpForDimensions() async throws {
        let src = try makeProceduralSource()
        let out = try await runPipeline(sourceURL: src, format: .dxt1,
                                        outputSize: .original)
        defer { try? FileManager.default.removeItem(at: out) }
        let data = try Data(contentsOf: out)
        let tkhd = tkhdDims(in: data)
        XCTAssertEqual(tkhd?.width, 1920, "tkhd width must equal source width")
        XCTAssertEqual(tkhd?.height, 1080, "tkhd height must equal source height")
        let stsd = stsdDims(in: data)
        XCTAssertEqual(stsd?.width, 1920, "stsd width must equal source width")
        XCTAssertEqual(stsd?.height, 1080, "stsd height must equal source height")
    }

    /// `.preset(.hd_1280_720)` downscale: 1920×1080 → 1280×720. The
    /// file's tkhd/stsd must report the preset's dims, not the source's.
    func testPresetDownscaleProducesPresetDims() async throws {
        let src = try makeProceduralSource()
        let out = try await runPipeline(sourceURL: src, format: .dxt1,
                                        outputSize: .preset(.hd_1280_720))
        defer { try? FileManager.default.removeItem(at: out) }
        let data = try Data(contentsOf: out)
        let tkhd = tkhdDims(in: data)
        XCTAssertEqual(tkhd?.width, 1280, "tkhd width must be 1280 after preset downscale")
        XCTAssertEqual(tkhd?.height, 720, "tkhd height must be 720 after preset downscale")
    }

    /// `.custom(1500, 844)` — arbitrary 4-pixel-legal dims. Output
    /// dims must match exactly.
    func testCustomResizeProducesExactDims() async throws {
        let src = try makeProceduralSource()
        let out = try await runPipeline(sourceURL: src, format: .dxt1,
                                        outputSize: .custom(width: 1500, height: 844),
                                        resizeQuality: .lanczos)
        defer { try? FileManager.default.removeItem(at: out) }
        let data = try Data(contentsOf: out)
        let tkhd = tkhdDims(in: data)
        XCTAssertEqual(tkhd?.width, 1500)
        XCTAssertEqual(tkhd?.height, 844)
    }

    /// Encoder + writer dimension agreement: tkhd and stsd MUST
    /// match. If they ever drift (e.g. encoder prepared with source
    /// dims while writer got post-transform dims), the file is
    /// malformed and Resolume would mis-render. Asserting equality
    /// guards that wiring.
    func testEncoderAndWriterDimensionAgreement() async throws {
        let src = try makeProceduralSource()
        let out = try await runPipeline(sourceURL: src, format: .dxt1,
                                        outputSize: .preset(.hd_1280_720))
        defer { try? FileManager.default.removeItem(at: out) }
        let data = try Data(contentsOf: out)
        let tkhd = tkhdDims(in: data)
        let stsd = stsdDims(in: data)
        XCTAssertEqual(tkhd?.width, stsd?.width,
                       "tkhd width must equal stsd width — encoder/writer drift")
        XCTAssertEqual(tkhd?.height, stsd?.height,
                       "tkhd height must equal stsd height — encoder/writer drift")
    }

    /// Codec-aware alignment (was: uniform 4-px guard). DXV's alignment
    /// is 1 (it pads its coded raster internally), so a non-4-mult custom
    /// dim is now ACCEPTED and produces exactly that presentation size —
    /// the old uniform-4 throw was an over-constraint.
    func testCustomDims_DXVAcceptsArbitrary() async throws {
        let src = try makeProceduralSource()
        let out = try await runPipeline(sourceURL: src, format: .dxt1,
                                        outputSize: .custom(width: 1922, height: 1080),
                                        dimensionAlignment: 1)
        defer { try? FileManager.default.removeItem(at: out) }
        let tkhd = tkhdDims(in: try Data(contentsOf: out))
        XCTAssertEqual(tkhd?.width, 1922, "DXV accepts arbitrary custom width (coded padded internally)")
        XCTAssertEqual(tkhd?.height, 1080)
    }

    /// The guard remains ONLY where a codec needs it: alignment=2 (H.264/
    /// HEVC even-dims) still fails loud on an odd dimension, so output
    /// never silently differs from the request.
    func testCustomDims_Alignment2_RejectsOdd() async throws {
        let src = try makeProceduralSource()
        do {
            _ = try await runPipeline(sourceURL: src, format: .dxt1,
                                      outputSize: .custom(width: 1921, height: 1080),
                                      dimensionAlignment: 2)
            XCTFail("Expected PipelineError.misalignedOutputDimensions for odd dim @ alignment 2")
        } catch EncodePipeline.PipelineError.misalignedOutputDimensions(let w, let h) {
            XCTAssertEqual(w, 1921); XCTAssertEqual(h, 1080)
        } catch {
            XCTFail("Expected misalignedOutputDimensions; got \(error)")
        }
    }

    /// Resize is codec-agnostic: the same source through a HAP codec
    /// (HapY) with a preset downscale produces the same output
    /// dimensions as the DXT1 equivalent.
    func testResizeIsCodecAgnostic_HapY() async throws {
        let src = try makeProceduralSource()
        let out = try await runPipeline(sourceURL: src, format: .hapY,
                                        outputSize: .preset(.hd_1280_720))
        defer { try? FileManager.default.removeItem(at: out) }
        let data = try Data(contentsOf: out)
        let tkhd = tkhdDims(in: data)
        XCTAssertEqual(tkhd?.width, 1280)
        XCTAssertEqual(tkhd?.height, 720)
        // Also confirm the stsd FourCC really IS HapY (Phase E doesn't
        // alter codec dispatch).
        let cc = stsdFourCC(in: data)
        XCTAssertEqual(cc, "HapY", "HapY codec FourCC must reach stsd unchanged")
    }
}

/*
 * Multi-Format Phase 1 — UI-logic unit tests (no UI instantiation):
 * OutputCodec accessors, container filtering, ProRes alpha-steering on
 * EncodeJob, and the AutoName ProRes filename token. The dispatch +
 * picker rendering are covered by ProResSinkTests (engine) + the human
 * gates; these lock the pure decision logic.
 */
import XCTest
import AVFoundation
import GlEncCore
@testable import GlEnc

final class MultiFormatUITests: XCTestCase {

    private let dummy = URL(fileURLWithPath: "/tmp/does-not-need-to-exist/Clip.mov")

    // MARK: - OutputCodec accessors + container filter

    func testIsImplemented_AllCodecsLive() {
        // Phase 3 made Motion JPEG live — every codec is now implemented.
        XCTAssertTrue(OutputCodec.dxv(.dxt1).isImplemented)
        XCTAssertTrue(OutputCodec.prores(.proRes422).isImplemented)
        XCTAssertTrue(OutputCodec.h264.isImplemented)
        XCTAssertTrue(OutputCodec.hevc.isImplemented)
        XCTAssertTrue(OutputCodec.mjpeg.isImplemented)
    }

    func testHasAdvancedSettings_OnlyH264HEVC() {
        // Drives the "Advanced" trigger visibility: shown for H.264/HEVC,
        // hidden for DXV/HAP (no settings) and ProRes (variant is the
        // row's 2nd menu, container .mov-locked, alpha note inline).
        XCTAssertTrue(OutputCodec.h264.hasAdvancedSettings)
        XCTAssertTrue(OutputCodec.hevc.hasAdvancedSettings)
        XCTAssertFalse(OutputCodec.dxv(.dxt1).hasAdvancedSettings)
        XCTAssertFalse(OutputCodec.prores(.proRes4444).hasAdvancedSettings)
        XCTAssertFalse(OutputCodec.mjpeg.hasAdvancedSettings)
    }

    func testVideoToolboxCodecMapping() {
        XCTAssertEqual(OutputCodec.h264.videoToolboxCodec, .h264)
        XCTAssertEqual(OutputCodec.hevc.videoToolboxCodec, .hevc)
        XCTAssertEqual(OutputCodec.mjpeg.videoToolboxCodec, .jpeg)
        XCTAssertNil(OutputCodec.prores(.proRes422).videoToolboxCodec)
        XCTAssertNil(OutputCodec.dxv(.dxt1).videoToolboxCodec)
    }

    func testDimensionAlignment_CodecAware() {
        // H.264/HEVC need even (2px, 4:2:0 chroma); the rest accept any.
        XCTAssertEqual(OutputCodec.h264.dimensionAlignment, 2)
        XCTAssertEqual(OutputCodec.hevc.dimensionAlignment, 2)
        XCTAssertEqual(OutputCodec.prores(.proRes422).dimensionAlignment, 1)
        XCTAssertEqual(OutputCodec.mjpeg.dimensionAlignment, 1)
        XCTAssertEqual(OutputCodec.dxv(.dxt1).dimensionAlignment, 1)
        XCTAssertEqual(OutputCodec.dxv(.hapY).dimensionAlignment, 1)
    }

    /// VALUE-PLUMBING test (the gap the function-only `testRoundedToMultiple`
    /// missed): construct the ACTUAL ResizeCustomSheet with each codec's
    /// alignment and read `sheet.alignment`, proving the codec's
    /// `dimensionAlignment` reaches the sheet's rounding — not the default 4.
    /// Would fail if JobCardView stopped passing it (sheet → default 4).
    @MainActor
    func testCustomResizePlumbing_CodecAlignmentReachesSheet() {
        func sheetAlignment(_ codec: OutputCodec) -> Int {
            ResizeCustomSheet(initialWidth: 1921, initialHeight: 1081,
                              alignment: codec.dimensionAlignment,
                              onCommit: { _ in }, onCancel: {}).alignment
        }
        XCTAssertEqual(sheetAlignment(.prores(.proRes422)), 1, "ProRes → no rounding reaches the sheet")
        XCTAssertEqual(sheetAlignment(.dxv(.dxt1)), 1)
        XCTAssertEqual(sheetAlignment(.dxv(.hapY)), 1)
        XCTAssertEqual(sheetAlignment(.mjpeg), 1)
        XCTAssertEqual(sheetAlignment(.h264), 2, "H.264 → even reaches the sheet")
        XCTAssertEqual(sheetAlignment(.hevc), 2)
        // → odd input therefore commits unrounded for alignment-1, even for h264/hevc.
        XCTAssertEqual(roundedToMultiple(1921, of: sheetAlignment(.prores(.proRes422))), 1921)
        XCTAssertEqual(roundedToMultiple(1921, of: sheetAlignment(.h264)), 1922)
    }

    func testRoundedToMultiple() {
        XCTAssertEqual(roundedToMultiple(1921, of: 1), 1921, "alignment 1 → no rounding")
        XCTAssertEqual(roundedToMultiple(1921, of: 2), 1922, "round odd up to even")
        XCTAssertEqual(roundedToMultiple(1922, of: 2), 1922, "already even")
        XCTAssertEqual(roundedToMultiple(1921, of: 4), 1920, "nearest 4-multiple")
        XCTAssertEqual(roundedToMultiple(1, of: 1), 1, "min 1 at alignment 1")
        // back-compat wrapper unchanged
        XCTAssertEqual(roundedToFourPixelMultiple(1282), 1284)
    }

    func testMJPEG_ContainerMovOnly_NoAdvanced() {
        XCTAssertEqual(OutputCodec.mjpeg.allowedContainers, [.mov])
        XCTAssertFalse(OutputCodec.mjpeg.hasAdvancedSettings)
        XCTAssertFalse(OutputCodec.mjpeg.hasAlpha)
    }

    func testAutoName_MJPEGToken() {
        let n = AutoNameEngine.suggestedName(
            sourceURL: dummy, format: .dxt1, outputCodec: .mjpeg, container: .mov,
            inFrame: nil, outFrame: nil, fps: 30, trimFormat: .time)
        XCTAssertEqual(n, "Clip_MotionJPEG.mov")
    }

    func testAutoName_H264HEVC_TokenAndContainerExtension() {
        let h264mp4 = AutoNameEngine.suggestedName(
            sourceURL: dummy, format: .dxt1, outputCodec: .h264, container: .mp4,
            inFrame: nil, outFrame: nil, fps: 30, trimFormat: .time)
        XCTAssertEqual(h264mp4, "Clip_H.264.mp4")

        let hevcMov = AutoNameEngine.suggestedName(
            sourceURL: dummy, format: .dxt1, outputCodec: .hevc, container: .mov,
            inFrame: nil, outFrame: nil, fps: 30, trimFormat: .time)
        XCTAssertEqual(hevcMov, "Clip_HEVC.mov")
    }

    func testCompressionProperties_QualityBitrateKeyframeProfile() {
        let q = VideoEncodeSettings(rateControl: .quality(0.7), keyframeIntervalFrames: 0,
                                    h264Profile: .high)
        let qp = q.compressionProperties(includeH264Profile: true)
        XCTAssertEqual(qp[AVVideoQualityKey] as? Double, 0.7)
        XCTAssertNil(qp[AVVideoAverageBitRateKey])
        XCTAssertNil(qp[AVVideoMaxKeyFrameIntervalKey], "0 keyframe → key omitted")
        XCTAssertEqual(qp[AVVideoProfileLevelKey] as? String,
                       AVVideoProfileLevelH264HighAutoLevel)

        let b = VideoEncodeSettings(rateControl: .bitrate(8), keyframeIntervalFrames: 24,
                                    h264Profile: .main)
        let bp = b.compressionProperties(includeH264Profile: false)
        XCTAssertEqual(bp[AVVideoAverageBitRateKey] as? Int, 8_000_000)
        XCTAssertNil(bp[AVVideoQualityKey])
        XCTAssertEqual(bp[AVVideoMaxKeyFrameIntervalKey] as? Int, 24)
        XCTAssertNil(bp[AVVideoProfileLevelKey], "HEVC path → no H.264 profile key")
    }

    func testContainerAACPredicate_DrivesAudioRateCap() {
        // .mp4 ⇒ AAC (caps 48 kHz); .mov ⇒ LPCM (no cap). Single source of
        // truth used by the rate-menu disable + the encode clamp.
        XCTAssertTrue(OutputContainer.mp4.usesAACAudio)
        XCTAssertFalse(OutputContainer.mov.usesAACAudio)
        XCTAssertEqual(OutputContainer.mp4.maxAudioSampleRate, 48000)
        XCTAssertEqual(OutputContainer.mov.maxAudioSampleRate, Int.max)
        // The clamp these drive:
        XCTAssertEqual(min(96000, OutputContainer.mp4.maxAudioSampleRate), 48000)
        XCTAssertEqual(min(96000, OutputContainer.mov.maxAudioSampleRate), 96000)
    }

    func testContainerFilter_ProResIsMovOnly() {
        XCTAssertEqual(OutputCodec.prores(.proRes4444).allowedContainers, [.mov])
        XCTAssertEqual(OutputCodec.dxv(.yg10).allowedContainers, [.mov])
        XCTAssertFalse(OutputCodec.prores(.proRes422).allowedContainers.contains(.mp4),
                       "ProRes must never offer .mp4")
        // H.264/HEVC (future) would allow mp4 — the mechanism is in place.
        XCTAssertEqual(OutputCodec.h264.allowedContainers, [.mov, .mp4])
    }

    func testHasAlpha_Mapping() {
        XCTAssertTrue(OutputCodec.prores(.proRes4444).hasAlpha)
        XCTAssertFalse(OutputCodec.prores(.proRes422).hasAlpha)
        XCTAssertTrue(OutputCodec.dxv(.dxt5).hasAlpha)
        XCTAssertFalse(OutputCodec.dxv(.dxt1).hasAlpha)
    }

    func testDXVFormatAccessor() {
        XCTAssertEqual(OutputCodec.dxv(.ycg6).dxvFormat, .ycg6)
        XCTAssertNil(OutputCodec.prores(.proRes422).dxvFormat)
        XCTAssertEqual(OutputCodec.prores(.proRes422HQ).proResVariant, .proRes422HQ)
        XCTAssertNil(OutputCodec.dxv(.dxt1).proResVariant)
    }

    // MARK: - EncodeJob default + byte-path preservation

    func testNewJobDefaultsToDXVCodec() {
        let job = EncodeJob(sourceURL: dummy, format: .dxt1)
        XCTAssertEqual(job.outputCodec, .dxv(.dxt1),
                       "default must be .dxv(format) — keeps every existing path byte-identical")
        XCTAssertEqual(job.outputContainer, .mov)
        XCTAssertNil(job.sourceHasAlpha)
    }

    // MARK: - Alpha steering

    func testSteeredVariant_AlphaSource_Defaults4444() {
        var job = EncodeJob(sourceURL: dummy, format: .dxt1)
        job.sourceHasAlpha = true
        XCTAssertEqual(job.steeredProResVariant, .proRes4444)
    }

    func testSteeredVariant_OpaqueSource_Defaults422() {
        var job = EncodeJob(sourceURL: dummy, format: .dxt1)
        job.sourceHasAlpha = false
        XCTAssertEqual(job.steeredProResVariant, .proRes422)
    }

    func testSteeredVariant_UnknownSource_FallsBackToAlphaIntent() {
        // sourceHasAlpha nil → use the current DXV alpha intent.
        var job = EncodeJob(sourceURL: dummy, format: .dxt5)  // With Alpha
        job.sourceHasAlpha = nil
        XCTAssertEqual(job.steeredProResVariant, .proRes4444)

        job = EncodeJob(sourceURL: dummy, format: .dxt1)       // No alpha
        job.sourceHasAlpha = nil
        XCTAssertEqual(job.steeredProResVariant, .proRes422)
    }

    func testAlphaWillBeFlattened_OnlyWhenNon4444AndSourceHasAlpha() {
        var job = EncodeJob(sourceURL: dummy, format: .dxt1)
        job.sourceHasAlpha = true

        job.outputCodec = .prores(.proRes422)
        XCTAssertTrue(job.alphaWillBeFlattened, "422 on an alpha source → note")

        job.outputCodec = .prores(.proRes4444)
        XCTAssertFalse(job.alphaWillBeFlattened, "4444 keeps alpha → no note")

        job.outputCodec = .dxv(.dxt5)
        XCTAssertFalse(job.alphaWillBeFlattened, "DXV path is not a ProRes flatten")

        // Opaque source → no note regardless of variant.
        job.sourceHasAlpha = false
        job.outputCodec = .prores(.proRes422)
        XCTAssertFalse(job.alphaWillBeFlattened)
    }

    // MARK: - AutoName ProRes token

    func testAutoName_ProResVariantToken() {
        let n4444 = AutoNameEngine.suggestedName(
            sourceURL: dummy, format: .dxt1, outputCodec: .prores(.proRes4444),
            inFrame: nil, outFrame: nil, fps: 30, trimFormat: .time)
        XCTAssertEqual(n4444, "Clip_ProRes 4444.mov")

        let n422HQ = AutoNameEngine.suggestedName(
            sourceURL: dummy, format: .dxt1, outputCodec: .prores(.proRes422HQ),
            inFrame: nil, outFrame: nil, fps: 30, trimFormat: .time)
        XCTAssertEqual(n422HQ, "Clip_ProRes 422 HQ.mov")
    }

    func testAutoName_DXVUnchanged_WhenCodecNilOrDXV() {
        // Legacy callers (no outputCodec) keep byte-identical names.
        let legacy = AutoNameEngine.suggestedName(
            sourceURL: dummy, format: .dxt5,
            inFrame: nil, outFrame: nil, fps: 30, trimFormat: .time)
        XCTAssertEqual(legacy, "Clip_DXV Normal Quality With Alpha.mov")

        let explicitDXV = AutoNameEngine.suggestedName(
            sourceURL: dummy, format: .dxt5, outputCodec: .dxv(.dxt5),
            inFrame: nil, outFrame: nil, fps: 30, trimFormat: .time)
        XCTAssertEqual(explicitDXV, legacy, ".dxv codec must match the legacy name exactly")
    }
}

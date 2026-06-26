// SPDX-License-Identifier: MIT
import Foundation
import AVFoundation
import CoreVideo
import CoreMedia
import CoreGraphics

/// A UI-free description of one encode job. Carries everything
/// `CoreEncoder.makePipeline(...)` needs to build a configured
/// `EncodePipeline` — the same dispatch the GUI's `EncodeQueue` and the
/// headless `glenc-cli` both drive. No AppKit/SwiftUI types; the GUI
/// populates this from its per-job snapshot, the CLI from parsed args.
public struct EncodeRequest: Sendable {
    /// Source media URL (any AVAsset-readable container, or a DXV3 `.mov`
    /// which routes through GlanceCore's decoder inside `EncodePipeline`).
    public var sourceURL: URL
    /// Destination URL. Overwritten if it exists (the sinks remove first).
    public var outputURL: URL
    /// Parent codec + variant (DXV/HAP, ProRes, H.264/HEVC, MJPEG).
    public var codec: OutputCodec
    /// Container choice — `.mov` for DXV/HAP/ProRes/MJPEG; `.mov`/`.mp4`
    /// for H.264/HEVC. Drives the AVAssetWriter file type and audio codec.
    public var container: OutputContainer
    /// Rate-control / profile knobs for the VideoToolbox inter-frame
    /// codecs (H.264/HEVC). Ignored by DXV/HAP/ProRes/MJPEG.
    public var videoSettings: VideoEncodeSettings
    /// Per-job output size. `.original` is the byte-identical no-op.
    public var outputSize: OutputSize
    /// Resize filter when `outputSize != .original`.
    public var resizeQuality: ResizeQuality
    /// Aspect handling when source aspect differs from target.
    public var aspectMode: AspectMode
    /// Optional crop rect in source-pixel space (top-left origin). nil =
    /// no crop (byte-identical no-op).
    public var cropRect: CGRect?
    /// Optional `[lower, upper)` source-frame trim window. nil = full source.
    public var frameRange: Range<Int>?
    /// String stamped into the output's `udta/©swr` ("Encoding software").
    /// The GUI passes `AppVersion.writerVersion`; the CLI passes its own.
    public var writerVersion: String
    /// HAP chunked-section chunk count (v1.2.0 Slice 1). 1 (default) =
    /// the legacy single-section path, byte-identical to pre-v1.2.0
    /// output. >= 2 emits the chunked form (0xCB Hap1 / 0xCE Hap5);
    /// honoured for `.dxv(.hap1)` / `.dxv(.hap5)` only — every other
    /// codec ignores it. Additive: existing callers omit it and get 1.
    public var hapChunks: Int

    public init(
        sourceURL: URL,
        outputURL: URL,
        codec: OutputCodec,
        container: OutputContainer = .mov,
        videoSettings: VideoEncodeSettings = .default,
        outputSize: OutputSize = .original,
        resizeQuality: ResizeQuality = .auto,
        aspectMode: AspectMode = .letterbox,
        cropRect: CGRect? = nil,
        frameRange: Range<Int>? = nil,
        writerVersion: String = "GlEnc",
        hapChunks: Int = 1
    ) {
        self.sourceURL = sourceURL
        self.outputURL = outputURL
        self.codec = codec
        self.container = container
        self.videoSettings = videoSettings
        self.outputSize = outputSize
        self.resizeQuality = resizeQuality
        self.aspectMode = aspectMode
        self.cropRect = cropRect
        self.frameRange = frameRange
        self.writerVersion = writerVersion
        self.hapChunks = hapChunks
    }
}

/// The single source of truth for `OutputCodec` → encoder/sink dispatch.
///
/// Before this type existed the dispatch was inlined in the GUI's
/// `EncodeQueue.encodeOne`. Extracting it here (no behavior change — the
/// 595-test suite is the byte-identity gate) lets `glenc-cli` drive the
/// exact same encode path with zero duplicated encode logic, the
/// GlanceCore-inside-glance pattern: one library core, a GUI and a CLI
/// over it.
public enum CoreEncoder {

    /// Default Motion JPEG quality (was `EncodeQueue.mjpegDefaultQuality`).
    /// MJPEG ships at a sane default with no Advanced popover.
    public static let mjpegDefaultQuality = 0.85

    /// DXV/HAP encoder + source-alpha tagging for a given `DXVFormat`.
    /// The single switch that maps each of the 9 variants to its
    /// `FrameEncoder` and the `CGImageAlphaInfo` the pipeline tags source
    /// frames with. Opaque variants force α=255 (`.noneSkipLast`); alpha
    /// variants carry straight alpha (`.last`).
    /// - Parameter chunks: HAP chunked-section count (v1.2.0). All five
    ///   HAP variants honour it — `.hap1`/`.hap5` (Slice 1), `.hapM`
    ///   (Slice 2), and standalone `.hapY`/`.hapA` (Slice 3); the
    ///   non-HAP DXV formats ignore it. Default 1 keeps every existing
    ///   caller byte-identical.
    public static func makeDXVEncoder(
        for format: DXVFormat,
        chunks: Int = 1
    ) -> (encoder: FrameEncoder, sourceAlphaInfo: CGImageAlphaInfo) {
        switch format {
        case .dxt1: return (DXT1Encoder(),               .noneSkipLast)
        case .dxt5: return (DXT5Encoder(),               .last)
        case .ycg6: return (YCG6Encoder(),               .noneSkipLast)
        case .yg10: return (YG10Encoder(),               .last)
        case .hap1: return (HapFrameEncoder(codec: .hap1, chunks: chunks), .noneSkipLast)
        case .hap5: return (HapFrameEncoder(codec: .hap5, chunks: chunks), .last)
        case .hapY: return (HapFrameEncoder(codec: .hapY, chunks: chunks), .noneSkipLast)
        case .hapA: return (HapFrameEncoder(codec: .hapA, chunks: chunks), .last)
        case .hapM: return (HapFrameEncoder(codec: .hapM, chunks: chunks), .last)
        }
    }

    /// Build a fully-configured `EncodePipeline` for a request.
    ///
    /// - Parameter audio: optional interleaved s32le PCM + format to mux
    ///   as a second track. nil → no audio (byte-identical to the
    ///   pre-audio path; the DXV3 byte-identity gate proves it).
    /// - Parameter onSinkBuilt: called with the `FrameSink` the moment it
    ///   is constructed (inside the pipeline's per-run `makeSink`). The
    ///   GUI uses it to read the sink's post-run `audioWarning`; the CLI
    ///   passes nil.
    ///
    /// Pure dispatch — no I/O happens until `pipeline.run()`. Mirrors the
    /// original `EncodeQueue` switch exactly so output bytes are unchanged.
    public static func makePipeline(
        _ req: EncodeRequest,
        audio: (info: AudioStreamInfo, pcm: Data)? = nil,
        progress: EncodePipeline.ProgressCallback? = nil,
        onSinkBuilt: ((FrameSink) -> Void)? = nil
    ) throws -> EncodePipeline {
        let outURL = req.outputURL

        switch req.codec {
        case .dxv(let format):
            let (encoder, sourceAlphaInfo) = makeDXVEncoder(for: format, chunks: req.hapChunks)
            // Build the sink explicitly so the optional audio trak can be
            // attached. With audio == nil this is byte-for-byte the legacy
            // convenience path: prepare → DXVMOVWriter → DXVEncoderSink.
            return EncodePipeline(
                sourceURL: req.sourceURL,
                makeSink: { w, h, fps in
                    try encoder.prepare(width: w, height: h, fps: fps, hasAlpha: false)
                    let writer = try DXVMOVWriter(
                        destURL: outURL,
                        format: format,
                        presentationWidth: w,
                        presentationHeight: h,
                        fps: fps,
                        writerVersion: req.writerVersion,
                        codecFourCC: format.streamFourCC)
                    let sink = DXVEncoderSink(encoder: encoder, writer: writer, audio: audio)
                    onSinkBuilt?(sink)
                    return sink
                },
                progress: progress,
                sourceAlphaInfo: sourceAlphaInfo,
                frameRange: req.frameRange,
                outputSize: req.outputSize,
                resizeQuality: req.resizeQuality,
                aspectMode: req.aspectMode,
                cropRect: req.cropRect,
                dimensionAlignment: req.codec.dimensionAlignment)

        case .prores(let variant):
            let container = req.container
            let srcAlpha: CGImageAlphaInfo = variant.hasAlpha ? .last : .noneSkipLast
            return EncodePipeline(
                sourceURL: req.sourceURL,
                makeSink: { w, h, _ in
                    let sink = try AVAssetWriterVideoSink(
                        destURL: outURL,
                        codec: variant.avCodec,
                        fileType: container.fileType,
                        width: w, height: h,
                        audio: audio)
                    onSinkBuilt?(sink)
                    return sink
                },
                progress: progress,
                sourceAlphaInfo: srcAlpha,
                frameRange: req.frameRange,
                outputSize: req.outputSize,
                resizeQuality: req.resizeQuality,
                aspectMode: req.aspectMode,
                cropRect: req.cropRect,
                dimensionAlignment: req.codec.dimensionAlignment)

        case .h264, .hevc:
            guard let vtCodec = req.codec.videoToolboxCodec else {
                throw NSError(
                    domain: "GlEncCore", code: -2,
                    userInfo: [NSLocalizedDescriptionKey:
                        "No VideoToolbox codec for \(req.codec)"])
            }
            let container = req.container
            let includeH264Profile = (req.codec == .h264)
            let props = req.videoSettings.compressionProperties(
                includeH264Profile: includeH264Profile)
            return EncodePipeline(
                sourceURL: req.sourceURL,
                makeSink: { w, h, _ in
                    let sink = try AVAssetWriterVideoSink(
                        destURL: outURL,
                        codec: vtCodec,
                        fileType: container.fileType,
                        width: w, height: h,
                        compressionProperties: props,
                        audio: audio)
                    onSinkBuilt?(sink)
                    return sink
                },
                progress: progress,
                sourceAlphaInfo: .noneSkipLast,
                frameRange: req.frameRange,
                outputSize: req.outputSize,
                resizeQuality: req.resizeQuality,
                aspectMode: req.aspectMode,
                cropRect: req.cropRect,
                dimensionAlignment: req.codec.dimensionAlignment)

        case .mjpeg:
            let container = req.container
            let props: [String: Any] = [AVVideoQualityKey: mjpegDefaultQuality]
            return EncodePipeline(
                sourceURL: req.sourceURL,
                makeSink: { w, h, _ in
                    let sink = try AVAssetWriterVideoSink(
                        destURL: outURL,
                        codec: .jpeg,
                        fileType: container.fileType,
                        width: w, height: h,
                        compressionProperties: props,
                        audio: audio)
                    onSinkBuilt?(sink)
                    return sink
                },
                progress: progress,
                sourceAlphaInfo: .noneSkipLast,
                frameRange: req.frameRange,
                outputSize: req.outputSize,
                resizeQuality: req.resizeQuality,
                aspectMode: req.aspectMode,
                cropRect: req.cropRect,
                dimensionAlignment: req.codec.dimensionAlignment)
        }
    }
}

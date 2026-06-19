// SPDX-License-Identifier: MIT
import Foundation
import AVFoundation
import CoreVideo
import CoreMedia
import CoreGraphics

/// Abstract destination for per-frame encoded packets. Phase 2B onward uses
/// `DXVMOVWriter`; tests can supply a fake.
public protocol PacketWriter: AnyObject {
    func append(packet: Data, presentationTime: CMTime) throws
    func finish() throws
}

extension DXVMOVWriter: PacketWriter {}

/// Source → encoder → destination pipeline. Phase 7A finding 4: source
/// decoding is now abstracted behind `SourceFrameReader` so DXV3 source
/// files (which AVAssetReader can't decode — macOS has no registered
/// DXV3 decoder) route through GlanceCore's bundled decoders. Non-DXV3
/// sources continue to use `AVAssetReader` exactly as before.
public final class EncodePipeline {

    public enum PipelineError: Error, CustomStringConvertible {
        case noVideoTrack
        case readerStartFailed(Error?)
        case readerFailed(Error?)
        case sourceReaderError(SourceReaderError)
        /// Resize Release Phase E — fail loud when a non-.original
        /// output dim reaches the pipeline non-4-pixel-aligned. The
        /// preset list is 4-pixel-legal by construction and the
        /// Custom… sheet (Phase F) rounds; this case is the
        /// belt-and-suspenders guard. Encoders' coded-dim padding
        /// would otherwise paper over presentation/coded drift —
        /// the HQ-16px failure mode in miniature.
        case misalignedOutputDimensions(width: Int, height: Int)
        /// Crop Release Phase F — fail loud when cropRect coords are
        /// non-integer or not 4-pixel-multiples (L3). The overlay
        /// snaps live so this should be unreachable from the live UI;
        /// the case exists for defense at the pipeline boundary, the
        /// same role `misalignedOutputDimensions` plays for resize.
        case misalignedCropDimensions(x: Int, y: Int, width: Int, height: Int)
        /// Crop Release Phase F — cropRect extends outside source
        /// dims. Belt-and-suspenders against an overlay bug or a
        /// programmatic caller that bypassed `CropDragMath`'s clamp.
        case cropRectOutOfBounds(rect: CGRect, sourceWidth: Int, sourceHeight: Int)

        public var description: String {
            switch self {
            case .noVideoTrack: return "EncodePipeline: source has no video track"
            case .readerStartFailed(let e): return "EncodePipeline: reader.startReading() failed: \(String(describing: e))"
            case .readerFailed(let e): return "EncodePipeline: reader failed mid-stream: \(String(describing: e))"
            case .sourceReaderError(let e): return "EncodePipeline: \(e)"
            case .misalignedOutputDimensions(let w, let h):
                return "EncodePipeline: non-.original output dimensions (\(w)×\(h)) must be 4-pixel-multiples (L3); got non-aligned"
            case .misalignedCropDimensions(let x, let y, let w, let h):
                return "EncodePipeline: cropRect (x=\(x), y=\(y), \(w)×\(h)) must have integer-valued 4-pixel-aligned coords (L3); got non-aligned"
            case .cropRectOutOfBounds(let r, let sw, let sh):
                return "EncodePipeline: cropRect \(r) extends outside source dims \(sw)×\(sh)"
            }
        }
    }

    public typealias ProgressCallback = @Sendable (Double) -> Void

    public typealias WriterFactory = (_ width: Int, _ height: Int, _ fps: Double) throws -> PacketWriter

    /// Multi-format Phase 1 — the output factory. Given resolved output
    /// dims + fps, builds the `FrameSink` the per-frame loop drives. The
    /// DXV/HAP path (legacy `encoder:`/`makeWriter:` init) wraps its
    /// encoder+writer pair as a `DXVEncoderSink` here; the VideoToolbox
    /// path (ProRes etc.) returns an `AVAssetWriterVideoSink`.
    public typealias SinkFactory = (_ width: Int, _ height: Int, _ fps: Double) throws -> FrameSink

    public let sourceURL: URL
    private let makeSink: SinkFactory
    public let progress: ProgressCallback?
    /// How frames pulled from `sourceURL` should be tagged when fed to
    /// the encoder. AVAssetReader's 32BGRA output from a ProRes 4444
    /// `yuva444p*` source is straight alpha (`.last`), which is the
    /// default. Callers encoding DXT1 or known-opaque sources can pass
    /// `.noneSkipLast` to force α=255 on the encoder side.
    public let sourceAlphaInfo: CGImageAlphaInfo
    /// Phase 8C-a — optional source-frame range. nil = encode the full
    /// source. When set, only frames in `[lowerBound, upperBound)` are
    /// written. Frames before `lowerBound` are read-and-discarded (no
    /// encode + no append); the loop exits when source frame index
    /// hits `upperBound`. The output's stts/stco/stsz reflect ONLY the
    /// in-range count, so the produced mov plays at native speed
    /// containing only the trim region.
    public let frameRange: Range<Int>?

    /// Resize Release Phase E — per-job output size. `.original`
    /// (the default) is a TRUE no-op: no FrameResizer call, encoder
    /// and writer get source dims. Non-.original resolves to target
    /// dims via `OutputSize.resolvedDimensions(...)` and the transform
    /// stage runs per frame.
    public let outputSize: OutputSize

    /// Resize Release Phase E — filter for the transform stage when
    /// `outputSize != .original`. Ignored on the `.original` no-op
    /// path (no FrameResizer call). `.auto` resolves at frame-time
    /// inside FrameResizer.
    public let resizeQuality: ResizeQuality

    /// Resize Release Phase G — aspect handling when source aspect
    /// differs from target aspect. `.letterbox` (default) fits the
    /// source into a centered inner rect on a black canvas;
    /// `.distortToFill` stretches to target dims. Ignored on the
    /// `.original` path and when source aspect already matches
    /// target aspect.
    public let aspectMode: AspectMode

    /// Crop Release Phase F — per-job crop rect in source-pixel
    /// space, top-left origin (CROP_PLAN.md Q2). `nil` (the default)
    /// is the byte-identical no-op: no `FrameCropper` call, the
    /// transform seam passes the source frame straight through. When
    /// non-nil it MUST be integer-valued, 4-pixel-aligned, and fully
    /// inside source dims — the pipeline validates this at the loop
    /// boundary before any frame reaches `FrameCropper`. The crop
    /// runs BEFORE resize (CROP_PLAN.md L2): `resolvedDimensions` is
    /// called with the cropped dims, so `.original` resize means
    /// "encode at the cropped size."
    public let cropRect: CGRect?

    /// Caller-side dimension alignment the crop/resize DIMENSIONS must
    /// satisfy (from `OutputCodec.dimensionAlignment`): 2 for H.264/HEVC
    /// (even, 4:2:0), 1 for ProRes/MJPEG/DXV3/HAP (arbitrary — they pad
    /// internally or accept exact dims). Default 1 = no constraint. Crop
    /// OFFSET is never alignment-checked (FrameCropper extracts exact
    /// pixels). Replaces the old uniform 4-px guard.
    public let dimensionAlignment: Int

    /// Legacy DXV/HAP entry point — unchanged signature, byte-identical
    /// behavior. Internally it builds a `makeSink` closure that
    /// `prepare(...)`-s the encoder, builds the writer, and wraps the
    /// pair as a `DXVEncoderSink` — IN THAT EXACT ORDER, so the produced
    /// bytes are identical to the pre-seam pipeline. The DXV3
    /// byte-identity gate is the proof.
    public convenience init(
        sourceURL: URL,
        encoder: FrameEncoder,
        makeWriter: @escaping WriterFactory,
        progress: ProgressCallback? = nil,
        sourceAlphaInfo: CGImageAlphaInfo = .last,
        frameRange: Range<Int>? = nil,
        outputSize: OutputSize = .original,
        resizeQuality: ResizeQuality = .auto,
        aspectMode: AspectMode = .letterbox,
        cropRect: CGRect? = nil,
        dimensionAlignment: Int = 1
    ) {
        self.init(
            sourceURL: sourceURL,
            makeSink: { w, h, fps in
                try encoder.prepare(width: w, height: h, fps: fps, hasAlpha: false)
                let writer = try makeWriter(w, h, fps)
                return DXVEncoderSink(encoder: encoder, writer: writer)
            },
            progress: progress,
            sourceAlphaInfo: sourceAlphaInfo,
            frameRange: frameRange,
            outputSize: outputSize,
            resizeQuality: resizeQuality,
            aspectMode: aspectMode,
            cropRect: cropRect,
            dimensionAlignment: dimensionAlignment
        )
    }

    /// Multi-format Phase 1 — sink-based entry point. The VideoToolbox
    /// path (ProRes, later HEVC/H.264/MJPEG) uses this directly, supplying
    /// a closure that builds an `AVAssetWriterVideoSink`.
    public init(
        sourceURL: URL,
        makeSink: @escaping SinkFactory,
        progress: ProgressCallback? = nil,
        sourceAlphaInfo: CGImageAlphaInfo = .last,
        frameRange: Range<Int>? = nil,
        outputSize: OutputSize = .original,
        resizeQuality: ResizeQuality = .auto,
        aspectMode: AspectMode = .letterbox,
        cropRect: CGRect? = nil,
        dimensionAlignment: Int = 1
    ) {
        self.sourceURL = sourceURL
        self.makeSink = makeSink
        self.progress = progress
        self.sourceAlphaInfo = sourceAlphaInfo
        self.frameRange = frameRange
        self.outputSize = outputSize
        self.resizeQuality = resizeQuality
        self.aspectMode = aspectMode
        self.cropRect = cropRect
        self.dimensionAlignment = max(1, dimensionAlignment)
    }

    public func run() async throws {
        // The factory routes by source type: DXV3-tagged sources go
        // through GlanceCore; everything else through AVAssetReader.
        let reader: SourceFrameReader
        do {
            reader = try await makeSourceReader(
                for: sourceURL, sourceAlphaInfo: sourceAlphaInfo)
        } catch let e as SourceReaderError {
            // Surface as a typed pipeline error so callers (EncodeQueue,
            // tests) can render a coherent message.
            if case .noVideoTrack = e { throw PipelineError.noVideoTrack }
            if case .avAssetReaderStartFailed(let underlying) = e {
                throw PipelineError.readerStartFailed(underlying)
            }
            throw PipelineError.sourceReaderError(e)
        }

        let width = reader.sourceWidth
        let height = reader.sourceHeight
        let fps = reader.sourceFPS
        let totalFrames = reader.totalFrameCount

        // Crop Release Phase F — validate cropRect at the pipeline
        // boundary so a malformed rect fails loud here rather than
        // silently producing wrong-sized frames or aliasing past
        // source bounds in `FrameCropper`. The overlay snaps live
        // (CROP_PLAN.md L3); this is the belt-and-suspenders guard,
        // same role `misalignedOutputDimensions` plays for resize.
        if let r = cropRect {
            let x = Int(r.minX)
            let y = Int(r.minY)
            let w = Int(r.width)
            let h = Int(r.height)
            // Crop must be integer pixels with positive dims, and the crop
            // DIMENSIONS must satisfy the output codec's alignment (2 for
            // H.264/HEVC, 1 = any for the rest). The OFFSET (x,y) is never
            // alignment-checked — FrameCropper extracts exact pixels.
            guard CGFloat(x) == r.minX,
                  CGFloat(y) == r.minY,
                  CGFloat(w) == r.width,
                  CGFloat(h) == r.height,
                  w % dimensionAlignment == 0, h % dimensionAlignment == 0,
                  w > 0, h > 0 else {
                throw PipelineError.misalignedCropDimensions(
                    x: x, y: y, width: w, height: h)
            }
            guard x >= 0, y >= 0,
                  x + w <= width, y + h <= height else {
                throw PipelineError.cropRectOutOfBounds(
                    rect: r, sourceWidth: width, sourceHeight: height)
            }
        }

        // Crop Release Phase F — effective dims for the resize
        // resolver. With a crop set, `.original` means "encode at the
        // cropped dims" (CROP_PLAN.md L2 — crop runs before resize,
        // so the resize resolver sees post-crop dims). With
        // cropRect == nil this is identical to the pre-Phase-F
        // behavior (effective = source).
        let effectiveSrcW = cropRect.map { Int($0.width) } ?? width
        let effectiveSrcH = cropRect.map { Int($0.height) } ?? height

        // Resize Release Phase E — resolve OUTPUT dims (post-transform)
        // and feed BOTH the encoder and the writer the same. `.original`
        // returns the (post-crop) effective dims unchanged (the
        // true-no-op contract); any non-.original outputSize MUST be
        // 4-pixel-aligned (L3) — the pipeline fails loud if it isn't,
        // rather than letting the encoder's coded-dim padding paper
        // over presentation/coded drift.
        let (outputW, outputH) = outputSize.resolvedDimensions(
            sourceWidth: effectiveSrcW, sourceHeight: effectiveSrcH)
        if case .original = outputSize {
            // No alignment check — source dims accepted as-is.
        } else {
            // User-chosen output dims must satisfy the codec's alignment
            // (2 for H.264/HEVC even-dims; 1 = any for ProRes/MJPEG/DXV3/
            // HAP). Replaces the old uniform 4-px rule.
            guard outputW % dimensionAlignment == 0 && outputH % dimensionAlignment == 0 else {
                throw PipelineError.misalignedOutputDimensions(
                    width: outputW, height: outputH)
            }
        }

        let sink = try makeSink(outputW, outputH, fps)

        // Phase 8C-a — resolve the trim window. nil → full source.
        // Out-of-bounds upper bound clamps to totalFrames.
        let trimLo: Int
        let trimHi: Int  // exclusive
        if let r = frameRange {
            trimLo = max(0, r.lowerBound)
            trimHi = totalFrames > 0 ? min(totalFrames, r.upperBound)
                                     : r.upperBound
        } else {
            trimLo = 0
            trimHi = totalFrames  // 0 if unknown; loop relies on reader EOF in that case
        }
        let progressDenom = max(1, trimHi - trimLo)

        var srcIdx = 0          // index into the source stream (0..<totalFrames)
        var writtenIdx = 0      // count of frames actually encoded + written

        while true {
            // Phase 7A loose-cancel check. When the enclosing Task is
            // cancelled (Phase 7A: user clicks Cancel / Cancel All in
            // the GUI), finish the current frame's read, skip the
            // encode/append, and throw out. The frame already in
            // flight is not preempted — partial output on disk is
            // worse UX than "finish-current-frame-then-stop." This
            // is the per-frame granularity boundary; mid-frame
            // cancellation isn't supported.
            try Task.checkCancellation()

            // Phase 8C-a — stop once we've passed the trim upper bound.
            // For frameRange == nil this is totalFrames (or 0 sentinel,
            // which means rely on reader EOF below).
            if trimHi > 0 && srcIdx >= trimHi { break }

            let frame: PixelFrame?
            do {
                frame = try reader.readNextFrame()
            } catch let e as SourceReaderError {
                if case .avAssetReaderFailed(let underlying) = e {
                    throw PipelineError.readerFailed(underlying)
                }
                throw PipelineError.sourceReaderError(e)
            }
            guard let frame = frame else { break }

            // Phase 8C-a — skip frames before the trim window. The
            // reader has to decode them anyway (DXV3 packets are
            // independent but the reader is sequential; AVAssetReader
            // also doesn't expose cheap index seek for arbitrary
            // codecs). Skipping the encode + append is the win.
            if srcIdx < trimLo {
                srcIdx += 1
                continue
            }

            // Crop Release Phase F + Resize Release Phase E — two-
            // stage transform. Crop runs FIRST when set (CROP_PLAN.md
            // L2: crop → resize). When cropRect == nil, `cropped` is
            // the same `frame` value — no allocation, no copy, no
            // FrameCropper call. Then resize runs only when
            // outputSize != .original. With cropRect == nil AND
            // outputSize == .original, `toEncode = frame` and the
            // source frame passes straight through to the encoder —
            // the DXV3 byte-identity no-op fast path, unchanged from
            // pre-Phase-F.
            let cropped: PixelFrame
            if let r = cropRect {
                cropped = try FrameCropper.crop(frame, to: r)
            } else {
                cropped = frame
            }

            let toEncode: PixelFrame
            switch outputSize {
            case .original:
                toEncode = cropped
            case .preset, .custom:
                toEncode = try FrameResizer.resize(
                    cropped, toWidth: outputW, toHeight: outputH,
                    quality: resizeQuality,
                    aspectMode: aspectMode)
            }

            try sink.consume(toEncode)

            srcIdx += 1
            writtenIdx += 1
            // Progress reports "fraction of TRIMMED encode done", not
            // fraction of source consumed. A 10%-of-source trim that's
            // half-encoded reports 50%, not 5%.
            let p = min(1.0, Double(writtenIdx) / Double(progressDenom))
            progress?(p)
        }

        try sink.finish()
        progress?(1.0)
    }
}

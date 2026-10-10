// SPDX-License-Identifier: MIT
import Foundation
import AVFoundation
import CoreVideo
import CoreMedia
import CoreGraphics
import GlanceCore
import DXVKit

/// Per-frame source decoder abstraction for `EncodePipeline`. The
/// pipeline used to be tightly coupled to `AVAssetReader`, which works
/// for ProRes / H.264 / HAP / anything macOS has a VideoToolbox decoder
/// for — but breaks on DXV3-tagged `.mov` files. macOS has no DXV3
/// decoder registered with VT (Phase 7A finding 4 diagnostic: error
/// -12906 / AVError -11833 at decompression-session creation), so a
/// DXV3-to-DXV3 transcode (a primary VJ use case) fails at the very
/// first frame read.
///
/// The protocol abstracts the read path so the pipeline can route DXV3
/// sources through GlanceCore's bundled decoders. Non-DXV3 sources
/// continue to use `AVAssetReader` exactly as before.
public protocol SourceFrameReader {
    var sourceWidth: Int { get }
    var sourceHeight: Int { get }
    var sourceFPS: Double { get }
    /// Best-effort total frame count for progress reporting. 0 if unknown.
    var totalFrameCount: Int { get }
    /// Pull the next BGRA frame. Returns nil at end-of-stream. Throws on
    /// underlying read error.
    func readNextFrame() throws -> PixelFrame?
}

/// Errors specific to source-reader construction or per-frame decode.
/// Wrapped by `EncodePipeline.PipelineError` cases at the run-loop layer.
public enum SourceReaderError: Error, CustomStringConvertible {
    case noVideoTrack
    case avAssetReaderStartFailed(Error?)
    case avAssetReaderFailed(Error?)
    case pixelBufferCreateFailed(CVReturn)
    /// The DXV file could not be demuxed (malformed or unsupported: DXVKit /
    /// GlanceCore's demuxer refused it). v1.4.0.
    case dxvDemuxFailed(underlying: Error)
    case dxvDecodeFailed(idx: Int, underlying: Error)
    // Hardening Fix-Brief 1 — source-input validation at the reader trust
    // boundary. These fire in the reader inits (below) the moment a
    // demuxer-/AVAsset-derived geometry or scalar is known, BEFORE it can
    // reach an allocation, the writer, the encoder, or frame-count math.
    // Each carries the offending value so the surfaced message is concrete.
    case sourceDimensionsInvalid(width: Int, height: Int)
    case sourceDimensionsTooLarge(width: Int, height: Int)
    case sourceFrameTooLarge(width: Int, height: Int)
    case sourceFrameRateInvalid(Double)
    case sourceDurationInvalid(Double)

    public var description: String {
        switch self {
        case .noVideoTrack: return "source has no video track"
        case .avAssetReaderStartFailed(let e): return "AVAssetReader.startReading failed: \(String(describing: e))"
        case .avAssetReaderFailed(let e): return "AVAssetReader failed mid-stream: \(String(describing: e))"
        case .pixelBufferCreateFailed(let r): return "CVPixelBufferCreate failed (\(r))"
        case .dxvDemuxFailed(let u): return "DXV file could not be read: \(u)"
        case .dxvDecodeFailed(let i, let u): return "DXV frame \(i) decode failed: \(u)"
        case .sourceDimensionsInvalid(let w, let h):
            return "source reports unusable dimensions \(w)×\(h) — width and height must each be positive"
        case .sourceDimensionsTooLarge(let w, let h):
            return "source dimensions \(w)×\(h) exceed the maximum encodable size of \(SourceGeometryLimits.maxDimension) pixels per side"
        case .sourceFrameTooLarge(let w, let h):
            return "source frame \(w)×\(h) is too large to encode safely (over \(SourceGeometryLimits.maxFramePixels) pixels)"
        case .sourceFrameRateInvalid(let fps):
            return "source reports an invalid frame rate (\(fps) fps)"
        case .sourceDurationInvalid(let dur):
            return "source reports an invalid duration (\(dur) seconds)"
        }
    }
}

/// Hard limits for a source frame's geometry, derived from the encode
/// path itself (not guessed):
///
///   - `maxDimension` (65535): `VariantMOVWriter` stores presentation
///     width/height as `UInt16` and performs `UInt16(dim)`
///     (VariantMOVWriter.swift:81-82,:148), which traps on overflow in
///     EVERY build config. A source dimension above this literally cannot
///     be written to a DXV/HAP MOV.
///   - `minDimension` (1): reject only truly-degenerate, non-positive
///     dimensions at the reader boundary. No "min 4": sub-4 and
///     non-4-aligned sources are legitimate on every path (DXVKit decodes
///     any DXV size ≥ 1 since v1.4.0; the old sub-4 DXT crash site in
///     GlanceCore v0.7.0's CPURender is gone).
///   - `maxFramePixels` (16384²): a sane RGBA-buffer ceiling (~1 GiB at
///     4 bpp) — generous against the largest 4096×2160 resize preset and
///     plausible LED-wall canvases, but rejects pathological dimensions
///     (e.g. 65535×65535 ≈ 17 GB) that would OOM an encoder's
///     `[UInt8](count: codedW*codedH*4)` allocation. Because both
///     dimensions are capped at 65535 first, `width*height` (≤ 65535² ≈
///     4.29e9) cannot overflow `Int`.
public enum SourceGeometryLimits {
    public static let minDimension = 1
    public static let maxDimension = 65535
    public static let maxFramePixels = 16384 * 16384
}

/// Validate a source's demux-/AVAsset-derived geometry and timing at the
/// reader trust boundary. Throws a concrete `SourceReaderError` for any
/// value that could otherwise crash (force-unwrap, overflow, OOM,
/// divide-by-zero, `Int(NaN)`) or silently corrupt downstream — converting
/// every such case into a clean error surfaced to the user as a failed
/// encode. Called at the top of each reader init, before any allocation,
/// pixel-buffer creation, coded-dimension math, or frame-count derivation.
internal func validateSourceGeometry(
    width: Int, height: Int, fps: Double, duration: Double
) throws {
    guard width >= SourceGeometryLimits.minDimension,
          height >= SourceGeometryLimits.minDimension else {
        throw SourceReaderError.sourceDimensionsInvalid(width: width, height: height)
    }
    guard width <= SourceGeometryLimits.maxDimension,
          height <= SourceGeometryLimits.maxDimension else {
        throw SourceReaderError.sourceDimensionsTooLarge(width: width, height: height)
    }
    // Both dims are now in [1, 65535] → width*height ≤ 65535² ≈ 4.29e9 <
    // Int.max, so this multiply cannot overflow.
    guard width * height <= SourceGeometryLimits.maxFramePixels else {
        throw SourceReaderError.sourceFrameTooLarge(width: width, height: height)
    }
    guard fps.isFinite, fps > 0 else {
        throw SourceReaderError.sourceFrameRateInvalid(fps)
    }
    guard duration.isFinite, duration >= 0 else {
        throw SourceReaderError.sourceDurationInvalid(duration)
    }
}

/// Inspect the source file and return the appropriate reader. Routes
/// DXV3 sources to `DxvSourceReader`; everything else to `AVAssetReaderSourceReader`.
/// `alphaType` (v1.6.0, the per-source "Alpha Type" switch) applies to DXV
/// sources only: their files do not say (`SourceAlpha`).
public func makeSourceReader(
    for url: URL,
    sourceAlphaInfo: CGImageAlphaInfo,
    alphaType: SourceAlphaType = .default
) async throws -> SourceFrameReader {
    if let cc = DXVDetector.compressorFourCC(at: url), dxvSourceFourCCs.contains(cc) {
        return try DxvSourceReader(url: url, alphaType: alphaType)
    }
    // HAP video source (Hap1/Hap5/HapY/HapM) — decode to BGRA frames via
    // GlanceCore's CPU HAP decoder, ahead of the AVAssetReader fallback
    // (macOS has no HAP video decoder, so HAP would otherwise fail there).
    // HapA (alpha-only, FourCC "HapA") is deliberately NOT routed here —
    // it isn't a standalone video source; it falls through as before.
    if let hapCC = HAPDetector.compressorFourCCIfHAP(at: url),
       hapCC == "Hap1" || hapCC == "Hap5" || hapCC == "HapY" || hapCC == "HapM" {
        return try HAPSourceReader(url: url)
    }
    return try await AVAssetReaderSourceReader(url: url, sourceAlphaInfo: sourceAlphaInfo)
}

// MARK: - AVAssetReader-backed reader

/// AVAssetReader-based source reader. Handles ProRes / H.264 / HAP /
/// anything macOS has a registered VideoToolbox decoder for.
public final class AVAssetReaderSourceReader: SourceFrameReader {
    public let sourceWidth: Int
    public let sourceHeight: Int
    public let sourceFPS: Double
    public let totalFrameCount: Int
    private let reader: AVAssetReader
    private let trackOutput: AVAssetReaderTrackOutput
    private let sourceAlphaInfo: CGImageAlphaInfo
    /// The format states premultiplied alpha and the output keeps alpha:
    /// frames are copied and un-premultiplied on read (v1.6.0).
    public let unpremultipliesOnRead: Bool

    public init(url: URL, sourceAlphaInfo: CGImageAlphaInfo) async throws {
        let asset = AVURLAsset(url: url)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else {
            throw SourceReaderError.noVideoTrack
        }
        let naturalSize = try await videoTrack.load(.naturalSize)
        let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
        let minFrameDuration = try await videoTrack.load(.minFrameDuration)
        let assetDuration = try await asset.load(.duration)

        let w = Int(naturalSize.width.rounded())
        let h = Int(naturalSize.height.rounded())
        // v1.6.0 — the rate is GlanceCore.FrameTiming's (Glance 0.17.3, the
        // one frame-timing rule of every app): the samples' own mean (count
        // / summed sample duration, exact), then the dominant sample delta,
        // snapped to the exact standard rational within 0.1 %, then
        // minFrameDuration when it agrees with nominalFrameRate, then the
        // nominal rate. Replaces v1.5.0's FrameRateResolver, which took the
        // mean over the TRACK duration (movie timescale 1/1000 s): a
        // 40-frame 60 fps source read 59.94. The exact rational converts to
        // a Double the writer maps onto its (timescale, delta) pair exactly
        // (fps x 512 for integer rates, (N x 1000, 1001) for NTSC).
        let timing = try await FrameTiming.load(track: videoTrack)
        // v1.6.0 — alpha as the file states it: a format description whose
        // alpha-channel mode is premultiplied (HEVC with alpha can say so) is
        // un-premultiplied on read; everything else (ProRes 4444, HEVC
        // straight) is straight as decoded.
        let formats = try await videoTrack.load(.formatDescriptions)
        let statedMode = formats.first.flatMap {
            (CMFormatDescriptionGetExtensions($0) as? [String: Any])?[kCMFormatDescriptionExtension_AlphaChannelMode as String] as? String
        }
        let keepsAlpha = sourceAlphaInfo == .last || sourceAlphaInfo == .first
        let fps = Double(timing.rateNumerator) / Double(timing.rateDenominator)
        let durSec = CMTimeGetSeconds(assetDuration)
        // Hardening Fix-Brief 1 — validate geometry/scalars at the reader
        // trust boundary, before the AVAssetReader is created and before
        // the `Int((durSec * fps).rounded())` frame-count math below
        // (a NaN/∞ duration would trap there). Throws a clean
        // SourceReaderError surfaced as a failed encode.
        try validateSourceGeometry(width: w, height: h, fps: fps, duration: durSec)
        FileHandle.standardError.write(Data(
            ("[GlEnc/fps] nominalFrameRate=\(nominalFrameRate) " +
             "minFrameDuration=\(minFrameDuration.value)/\(minFrameDuration.timescale) " +
             "frames=\(timing.frameCount) " +
             "fps=\(timing.rateNumerator)/\(timing.rateDenominator) (from \(timing.source.rawValue))\n").utf8))

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw SourceReaderError.avAssetReaderStartFailed(reader.error)
        }

        self.sourceWidth = w
        self.sourceHeight = h
        self.sourceFPS = fps
        self.totalFrameCount = max(0, Int((durSec * fps).rounded()))
        self.reader = reader
        self.trackOutput = output
        self.sourceAlphaInfo = sourceAlphaInfo
        self.unpremultipliesOnRead = keepsAlpha
            && statedMode == (kCMFormatDescriptionAlphaChannelMode_PremultipliedAlpha as String)
    }

    public func readNextFrame() throws -> PixelFrame? {
        if reader.status == .failed {
            throw SourceReaderError.avAssetReaderFailed(reader.error)
        }
        guard reader.status == .reading else { return nil }
        guard let sample = trackOutput.copyNextSampleBuffer() else {
            if reader.status == .failed {
                throw SourceReaderError.avAssetReaderFailed(reader.error)
            }
            return nil
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        guard var pb = CMSampleBufferGetImageBuffer(sample) else {
            return nil
        }
        if unpremultipliesOnRead { pb = try Self.straightCopy(of: pb) }
        return PixelFrame(
            pixelBuffer: pb,
            presentationTime: pts,
            alphaInfo: sourceAlphaInfo)
    }
}

extension AVAssetReaderSourceReader {
    /// A straight copy of a premultiplied BGRA buffer (the decoder's buffer
    /// is shared, so it is not changed in place).
    static func straightCopy(of src: CVPixelBuffer) throws -> CVPixelBuffer {
        let w = CVPixelBufferGetWidth(src), h = CVPixelBufferGetHeight(src)
        var out: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA,
                                         [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]] as CFDictionary, &out)
        guard status == kCVReturnSuccess, let dst = out else { throw SourceReaderError.pixelBufferCreateFailed(status) }
        CVPixelBufferLockBaseAddress(src, .readOnly); CVPixelBufferLockBaseAddress(dst, [])
        defer { CVPixelBufferUnlockBaseAddress(src, .readOnly); CVPixelBufferUnlockBaseAddress(dst, []) }
        guard let s = CVPixelBufferGetBaseAddress(src)?.assumingMemoryBound(to: UInt8.self),
              let d = CVPixelBufferGetBaseAddress(dst)?.assumingMemoryBound(to: UInt8.self) else { return dst }
        let ss = CVPixelBufferGetBytesPerRow(src), ds = CVPixelBufferGetBytesPerRow(dst)
        for y in 0..<h {
            let sr = s + y * ss, dr = d + y * ds
            for x in 0..<w {
                let o = x * 4
                // BGRA: the rule is per channel, so the order does not matter.
                let (b, g, r, a) = AlphaNormalization.unpremultiply.apply(r: sr[o], g: sr[o + 1], b: sr[o + 2], a: sr[o + 3])
                dr[o] = b; dr[o + 1] = g; dr[o + 2] = r; dr[o + 3] = a
            }
        }
        return dst
    }
}

// MARK: - DXVKit-backed DXV reader

/// DXV source reader (DXV3 and legacy DXV1 / DXV2), decoded by DXVKit
/// (AmritusG/dxvkit, pinned exact 1.0.0): `DXVMovie` demuxes, a reused
/// `DXVFrame` decodes each packet to its block streams, and
/// `DXVFrame.rgba` converts them to RGBA at the display size — DXVKit owns
/// the 16 x 16 padding, odd sizes and both generations. YCG6 / YG10 come
/// out in Resolume Arena's colour convention (DXVKit's), not the older
/// GlanceCore v0.7.0 conversion.
///
/// Alpha semantics: DXVKit returns the decoded colour and alpha as stored,
/// DXT1 / YCG6 with α = 255. The file does not say whether that colour is
/// straight or premultiplied (DXVKit spec 8.5), so the caller says
/// (`alphaType`, v1.6.0, Arena's "Alpha Type", default Premultiplied):
/// `.premultiplied` un-premultiplies the colour here, on read, before any
/// encoder sees it; `.straight` passes it through. Either way the
/// `PixelFrame` is tagged `.last` (straight) — every output then gets
/// straight colour (up to v1.5.0 a premultiplied DXV source reached
/// straight outputs still premultiplied: double-darkened).
public final class DxvSourceReader: SourceFrameReader {
    public let sourceWidth: Int
    public let sourceHeight: Int
    public let sourceFPS: Double
    public let totalFrameCount: Int

    private let movie: DXVMovie
    private let frame = DXVFrame()
    /// True when the colour is un-premultiplied on read (an alpha variant
    /// read as `.premultiplied`).
    public let unpremultipliesOnRead: Bool
    /// Presentation times from GlanceCore's demuxer (seconds, per sample).
    private let presentationTimes: [Double]
    private var frameIdx: Int = 0

    public init(url: URL, alphaType: SourceAlphaType = .default) throws {
        let index: DXVMovieIndex
        do { index = try DXVDemuxer.demux(url: url) } catch {
            throw SourceReaderError.dxvDemuxFailed(underlying: error)
        }
        // Hardening Fix-Brief 1 — validate the demuxed geometry before any
        // allocation (zero / oversized dims are rejected cleanly).
        let durationSec = index.frameRate > 0
            ? Double(index.frames.count) / index.frameRate : 0
        try validateSourceGeometry(
            width: index.width, height: index.height,
            fps: index.frameRate, duration: durationSec)
        do { self.movie = try DXVMovie(url: url) } catch {
            throw SourceReaderError.dxvDemuxFailed(underlying: error)
        }
        self.sourceWidth = index.width
        self.sourceHeight = index.height
        self.sourceFPS = index.frameRate
        self.totalFrameCount = index.frames.count
        self.presentationTimes = index.frames.map(\.presentationTime)
        self.unpremultipliesOnRead = alphaType == .premultiplied && movie.hasAlpha
    }

    public func readNextFrame() throws -> PixelFrame? {
        guard frameIdx < totalFrameCount else { return nil }
        let myIdx = frameIdx
        frameIdx += 1
        var rgba: Data
        do {
            try movie.decodeBlocks(at: myIdx, into: frame)
            rgba = try frame.rgba()
        } catch {
            throw SourceReaderError.dxvDecodeFailed(idx: myIdx, underlying: error)
        }
        if unpremultipliesOnRead { Self.unpremultiply(&rgba) }
        guard let pb = try Self.makeBGRAPixelBuffer(
                rgba: rgba, width: sourceWidth, height: sourceHeight) else {
            throw SourceReaderError.pixelBufferCreateFailed(kCVReturnAllocationFailed)
        }
        let pts = CMTime(seconds: presentationTimes[myIdx], preferredTimescale: 600)
        return PixelFrame(pixelBuffer: pb, presentationTime: pts, alphaInfo: .last)
    }

    /// Premultiplied RGBA -> straight, in place (AlphaNormalization's
    /// integer rule: round(c x 255 / α), α = 0 -> 0).
    static func unpremultiply(_ rgba: inout Data) {
        rgba.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            var i = 0
            while i + 3 < p.count {
                let a = p[i + 3]
                if a != 255 {
                    let (r, g, b, _) = AlphaNormalization.unpremultiply.apply(r: p[i], g: p[i + 1], b: p[i + 2], a: a)
                    p[i] = r; p[i + 1] = g; p[i + 2] = b
                }
                i += 4
            }
        }
    }

    /// Create a kCVPixelFormatType_32BGRA pixel buffer and fill it from
    /// straight-alpha RGBA bytes, swapping R↔B per pixel. The encoders
    /// downstream read BGRA via `PixelFrame.bgraBytes()`, so we
    /// pre-flip here at fill time.
    ///
    /// `internal static` (was `private static`) so `HAPSourceReader`
    /// reuses the exact same RGBA→BGRA fill — behavior unchanged; the
    /// only edit is the access level.
    static func makeBGRAPixelBuffer(
        rgba: Data, width w: Int, height h: Int
    ) throws -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, w, h,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary, &pb)
        guard status == kCVReturnSuccess, let buf = pb else {
            throw SourceReaderError.pixelBufferCreateFailed(status)
        }

        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        guard let dst = CVPixelBufferGetBaseAddress(buf) else { return nil }
        let dstStride = CVPixelBufferGetBytesPerRow(buf)
        let srcStride = w * 4

        rgba.withUnsafeBytes { srcBuf in
            guard let srcBase = srcBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return
            }
            let dstBase = dst.assumingMemoryBound(to: UInt8.self)
            for row in 0..<h {
                let s = srcBase.advanced(by: row * srcStride)
                let d = dstBase.advanced(by: row * dstStride)
                for x in 0..<w {
                    let sb = x * 4
                    let db = x * 4
                    d[db + 0] = s[sb + 2]  // B ← R
                    d[db + 1] = s[sb + 1]  // G ← G
                    d[db + 2] = s[sb + 0]  // R ← B
                    d[db + 3] = s[sb + 3]  // A ← A
                }
            }
        }
        return buf
    }
}

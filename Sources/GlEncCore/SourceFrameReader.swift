// SPDX-License-Identifier: MIT
import Foundation
import AVFoundation
import CoreVideo
import CoreMedia
import CoreGraphics
import GlanceCore

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
    case dxvFrameReadShort(idx: Int, expected: Int, actual: Int)
    case dxvDecodeFailed(idx: Int, underlying: Error)
    case dxvUnsupportedVariant(String)
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
    /// Fix-Brief 1-narrow — a DXV3 DXT1/DXT5 source frame whose height is
    /// below one 4×4 block row (h < 4) decodes to zero DXT blocks, which
    /// would hand GlanceCore an empty buffer and crash on a force-unwrap.
    /// Caught at the block-count site in `DxvSourceReader.decodeFrameRGBA`.
    case dxvZeroBlockGeometry(width: Int, height: Int)

    public var description: String {
        switch self {
        case .noVideoTrack: return "source has no video track"
        case .avAssetReaderStartFailed(let e): return "AVAssetReader.startReading failed: \(String(describing: e))"
        case .avAssetReaderFailed(let e): return "AVAssetReader failed mid-stream: \(String(describing: e))"
        case .pixelBufferCreateFailed(let r): return "CVPixelBufferCreate failed (\(r))"
        case .dxvFrameReadShort(let i, let e, let a): return "DXV frame \(i): short read (expected \(e), got \(a))"
        case .dxvDecodeFailed(let i, let u): return "DXV frame \(i) decode failed: \(u)"
        case .dxvUnsupportedVariant(let v): return "DXV unsupported variant for this path: \(v)"
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
        case .dxvZeroBlockGeometry(let w, let h):
            return "DXV DXT source frame \(w)×\(h) decodes to zero blocks (DXT requires height ≥ 4); cannot decode"
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
///     dimensions at the reader boundary. The sub-4-height DXT-decode
///     crash (height < 4 → zero DXT block rows → empty decode buffer →
///     force-unwrap in GlanceCore `CPURender.cgImageFromDXT`) is NOT
///     guarded by a blanket floor here — a "min 4" would re-impose the
///     constraint the project deliberately removed for output/crop dims
///     (6eb6430 / 351f1ca, validated in Resolume). That crash is caught
///     at its ACTUAL site instead (the `DxvSourceReader` DXV3 DXT
///     block-count, `decodeFrameRGBA` below: `guard blocks > 0`), so
///     legitimate sub-4 / non-4-aligned sources on every other path
///     (AVAsset, HAP, DXV1/DXDI which pads both axes to 16) pass
///     untouched.
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

/// Compressor FourCCs that route to `DxvSourceReader`. Covers both
/// stsd-direct texture tags (Alley-style outputs) and the DXV3 version
/// tags (ffmpeg / GlEnc outputs).
private let dxvFourCCs: Set<String> = ["DXT1", "DXT5", "YCG6", "YG10", "DXDI", "DXD3"]

/// Inspect the source file and return the appropriate reader. Routes
/// DXV3 sources to `DxvSourceReader`; everything else to `AVAssetReaderSourceReader`.
public func makeSourceReader(
    for url: URL,
    sourceAlphaInfo: CGImageAlphaInfo
) async throws -> SourceFrameReader {
    if let cc = DXVDetector.compressorFourCC(at: url), dxvFourCCs.contains(cc) {
        return try DxvSourceReader(url: url)
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
        // #14 part 1 — rational frame-rate read. `nominalFrameRate` is a
        // Float computed by AVFoundation; for a clean integer-rate H.264
        // it comes back as e.g. 29.999998 instead of 30, which then trips
        // VariantMOVWriter's integer-fps precondition. `minFrameDuration`
        // is the exact rational frame period (CMTime); deriving the rate
        // from it (timescale / value) recovers the true rate exactly —
        // 30/1 → 30.0, while a genuine 29.97 stays 30000/1001 ≈ 29.97003
        // (still non-integer; that's part 2's rational-timescale writer).
        // Fall back to the nominal float only when minFrameDuration is
        // unavailable/degenerate. For inputs that already read correctly
        // (e.g. ProRes 30 → nominal 30.0), the rational yields the same
        // value, so the writer-bound fps is unchanged for them.
        let fps: Double
        if minFrameDuration.isValid, minFrameDuration.isNumeric,
           minFrameDuration.value > 0, minFrameDuration.timescale > 0 {
            fps = Double(minFrameDuration.timescale) / Double(minFrameDuration.value)
        } else {
            fps = Double(nominalFrameRate)
        }
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
             "derivedRationalFPS=\(fps) writerFPS=\(fps)\n").utf8))

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
        guard let pb = CMSampleBufferGetImageBuffer(sample) else {
            return nil
        }
        return PixelFrame(
            pixelBuffer: pb,
            presentationTime: pts,
            alphaInfo: sourceAlphaInfo)
    }
}

// MARK: - GlanceCore-backed DXV3 reader

/// GlanceCore-backed DXV3 source reader. Demuxes the source `.mov` via
/// `DXVDemuxer`, then per-frame: reads the packet, runs the variant-
/// appropriate GlanceCore decoder + `CPURender`, and packages the result
/// as a BGRA `CVPixelBuffer` ready for the encoder.
///
/// Phase 5C corpus generation (`CorpusGenerationTests`) already used
/// this exact decode path to produce reference PNGs, so this is a
/// re-use of a proven path — just wrapped behind the `SourceFrameReader`
/// protocol and feeding into the encoder instead of writing PNG.
///
/// Alpha semantics: GlanceCore's `CPURender` outputs straight-alpha RGBA
/// for all four DXV3 variants (the alpha byte holds the decoded alpha
/// value, not a premultiplied product). The resulting `PixelFrame` is
/// tagged `.last`, which matches the AVAssetReader path's default and
/// is what the DXT5 / YG10 encoders expect.
public final class DxvSourceReader: SourceFrameReader {
    public let sourceWidth: Int
    public let sourceHeight: Int
    public let sourceFPS: Double
    public let totalFrameCount: Int

    private let variant: DXVVariant
    /// DXV generation from the demuxed index. DXV3 sources (DXD3 trak
    /// FourCC) take the existing DXVPacketDecoder path; DXV1/DXV2
    /// legacy sources (DXDI trak FourCC) route through DXV1PacketDecoder
    /// — mirroring v0.7.0's DXVThumbnail/DXVPlayer generation dispatch.
    private let generation: DXVGeneration
    private let codedWidth: Int
    private let codedHeight: Int
    private let chromaWidth: Int
    private let chromaHeight: Int
    private let frames: [DXVFrameEntry]
    private let handle: FileHandle
    private var frameIdx: Int = 0
    /// One-shot guard so the .dxv1 arm logs its resolved values exactly
    /// once (first decoded DXDI frame) instead of per-frame.
    private var loggedDXV1Diag = false

    public init(url: URL) throws {
        let index = try DXVDemuxer.demux(url: url)
        // Hardening Fix-Brief 1 — validate the demuxed geometry before the
        // coded-dimension cascade below (zero/odd/oversized dims would
        // otherwise produce a zero-block decode buffer that force-unwraps
        // to a crash in CPURender, or an OOM allocation in the encoder).
        let durationSec = index.frameRate > 0
            ? Double(index.frames.count) / index.frameRate : 0
        try validateSourceGeometry(
            width: index.width, height: index.height,
            fps: index.frameRate, duration: durationSec)
        self.sourceWidth = index.width
        self.sourceHeight = index.height
        self.sourceFPS = index.frameRate
        self.totalFrameCount = index.frames.count
        self.variant = index.variant
        self.generation = index.generation
        let cW = (index.width + 15) / 16 * 16
        let cH = (index.height + 15) / 16 * 16
        self.codedWidth = cW
        self.codedHeight = cH
        self.chromaWidth = cW / 2
        self.chromaHeight = cH / 2
        self.frames = index.frames
        self.handle = try FileHandle(forReadingFrom: url)
    }

    deinit { try? handle.close() }

    public func readNextFrame() throws -> PixelFrame? {
        guard frameIdx < frames.count else { return nil }
        let myIdx = frameIdx
        let entry = frames[myIdx]
        frameIdx += 1

        try handle.seek(toOffset: entry.fileOffset)
        let pktBytes = try handle.read(upToCount: Int(entry.size)) ?? Data()
        guard pktBytes.count == Int(entry.size) else {
            throw SourceReaderError.dxvFrameReadShort(
                idx: myIdx, expected: Int(entry.size), actual: pktBytes.count)
        }

        let rgba: Data
        do {
            rgba = try decodeFrameRGBA(packet: pktBytes)
        } catch {
            throw SourceReaderError.dxvDecodeFailed(idx: myIdx, underlying: error)
        }

        guard let pb = try Self.makeBGRAPixelBuffer(
                rgba: rgba, width: sourceWidth, height: sourceHeight) else {
            throw SourceReaderError.pixelBufferCreateFailed(kCVReturnAllocationFailed)
        }
        let pts = CMTime(seconds: entry.presentationTime, preferredTimescale: 600)
        return PixelFrame(pixelBuffer: pb, presentationTime: pts, alphaInfo: .last)
    }

    /// Decode one DXV packet to straight-alpha RGBA bytes
    /// (sourceWidth × sourceHeight × 4). Variant-routed through the
    /// matching GlanceCore decoder + CPURender. Alpha is straight
    /// (DXT1/YCG6 → 255 throughout; DXT5/YG10 → the source's decoded
    /// alpha plane).
    private func decodeFrameRGBA(packet: Data) throws -> Data {
        let w = sourceWidth, h = sourceHeight

        let cgImage: CGImage
        switch generation {
        case .dxv1:
            // Legacy DXV1/DXV2 ("DXDI") source. Mirrors v0.7.0's
            // DXVThumbnail.decodeDXTPacket: the DXV1 encoder pads BOTH
            // width and height to 16-pixel block alignment (DXV3 pads
            // width only), so the LZF-decompressed buffer is sized to
            // the both-axes-padded grid. CPURender.cgImageFromDXT is
            // then handed the DISPLAY dims — it reads height/4 block
            // rows and discards the trailing padding rows. DXDI carries
            // only the DXT variants (dxt1/dxt5); HQ never occurs here.
            let paddedWidth = (w + 15) / 16 * 16
            let textureHeight = (h + 15) / 16 * 16
            let dxtSize: Int
            switch variant {
            case .dxt1: dxtSize = paddedWidth * textureHeight / 2
            case .dxt5: dxtSize = paddedWidth * textureHeight
            default:
                throw SourceReaderError.dxvUnsupportedVariant(
                    "DXV1/DXDI source with non-DXT variant \(variant)")
            }
            if !loggedDXV1Diag {
                loggedDXV1Diag = true
                FileHandle.standardError.write(Data(
                    ("[GlEnc/dxdi] dxv1 decode arm: generation=\(generation) " +
                     "variant=\(variant) display=\(w)x\(h) " +
                     "paddedWidth=\(paddedWidth) textureHeight=\(textureHeight) " +
                     "dxtSize=\(dxtSize)\n").utf8))
            }
            let (header, payload) = try DXV1PacketDecoder.parseHeader(packet)
            let dxtBytes = try DXV1PacketDecoder.decodePayload(
                payload, header: header, expectedSize: dxtSize)
            cgImage = try CPURender.cgImageFromDXT(
                dxtBytes: dxtBytes, variant: variant, width: w, height: h)

        case .dxv3:
            let (_, payload) = try DXVPacketDecoder.parseHeader(packet)
            switch variant {
            case .dxt1:
                let paddedW = (w + 15) / 16 * 16
                let blocks = (paddedW / 4) * (h / 4)
                // Fix-Brief 1-narrow — a height < 4 (h/4 == 0) yields zero
                // DXT blocks; decompressDXT1 would then return an empty
                // Data that CPURender.cgImageFromDXT force-unwraps. Reject
                // cleanly here instead of handing GlanceCore the empty
                // buffer. (w ≥ 1 from the init guard → paddedW/4 ≥ 4, so
                // blocks == 0 ⟺ h < 4.)
                guard blocks > 0 else {
                    throw SourceReaderError.dxvZeroBlockGeometry(width: w, height: h)
                }
                let bc1 = try DXVPacketDecoder.decompressDXT1(
                    payload, expectedSize: blocks * 8)
                cgImage = try CPURender.cgImageFromDXT(
                    dxtBytes: bc1, variant: .dxt1, width: w, height: h)
            case .dxt5:
                let paddedW = (w + 15) / 16 * 16
                let blocks = (paddedW / 4) * (h / 4)
                guard blocks > 0 else {
                    throw SourceReaderError.dxvZeroBlockGeometry(width: w, height: h)
                }
                let bc3 = try DXVPacketDecoder.decompressDXT5(
                    payload, expectedSize: blocks * 16)
                cgImage = try CPURender.cgImageFromDXT(
                    dxtBytes: bc3, variant: .dxt5, width: w, height: h)
            case .ycg6:
                let luma = try DXVHQDecoder.decompressYCG6LumaPlane(
                    payload: payload,
                    codedWidth: codedWidth, codedHeight: codedHeight)
                let chroma = try DXVHQDecoder.decompressYCG6ChromaPlane(
                    payload: payload, startCursor: luma.postCursor,
                    codedWidth: codedWidth, codedHeight: codedHeight)
                cgImage = try CPURender.cgImageFromHQ(
                    y: luma.luma, co: chroma.co, cg: chroma.cg, a: nil,
                    width: codedWidth, height: codedHeight,
                    chromaWidth: chromaWidth, chromaHeight: chromaHeight)
            case .yg10:
                let r = try DXVHQDecoder.decompressYG10(
                    payload: payload,
                    codedWidth: codedWidth, codedHeight: codedHeight)
                cgImage = try CPURender.cgImageFromHQ(
                    y: r.y, co: r.co, cg: r.cg, a: r.a,
                    width: codedWidth, height: codedHeight,
                    chromaWidth: chromaWidth, chromaHeight: chromaHeight)
            }
        }

        // CPURender constructs the CGImage from a `CGDataProvider(data:
        // Data(rgba) as CFData)`. Asking the provider for its data
        // returns exactly the original straight-alpha RGBA bytes — no
        // colorspace conversion, no premultiplication. If for any
        // reason the provider can't return its data, fall back to
        // CGContext-rendering into a fresh RGBA buffer.
        if let cf = cgImage.dataProvider?.data {
            let data = cf as Data
            // HQ path: cgImage dims are coded, but we want presentation.
            // For HQ on a 16-aligned source the two are equal; if a
            // future source has non-16-aligned dims we'd need to crop
            // here. Phase 5C's measurement corpus is all 16-aligned;
            // explicit guard so non-aligned sources surface a clear
            // error rather than silently mis-sizing the encoder feed.
            let expectedRGBA = cgImage.width * cgImage.height * 4
            guard data.count == expectedRGBA else {
                return try renderRGBA(from: cgImage, width: w, height: h)
            }
            // For DXT* the dataProvider already matches presentation
            // dims. For HQ where coded == presentation (16-aligned)
            // it also matches. Anything else hits the renderRGBA path.
            if cgImage.width == w && cgImage.height == h {
                return data
            }
        }
        return try renderRGBA(from: cgImage, width: w, height: h)
    }

    /// Fallback path: render the decoded CGImage into a fresh RGBA
    /// byte buffer at presentation dimensions. Used only when the
    /// straight-bytes extraction above declines (size mismatch, or a
    /// future HQ source with non-16-aligned dims).
    private func renderRGBA(from image: CGImage, width: Int, height: Int) throws -> Data {
        var bytes = Data(count: width * height * 4)
        let bmpInfo: UInt32 = CGImageAlphaInfo.premultipliedLast.rawValue
                            | CGBitmapInfo.byteOrder32Big.rawValue
        try bytes.withUnsafeMutableBytes { ptr in
            guard let base = ptr.baseAddress,
                  let ctx = CGContext(
                    data: base, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: bmpInfo)
            else {
                throw SourceReaderError.pixelBufferCreateFailed(kCVReturnAllocationFailed)
            }
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return bytes
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

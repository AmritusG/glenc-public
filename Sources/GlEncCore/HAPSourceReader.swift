// SPDX-License-Identifier: MIT
import Foundation
import CoreVideo
import CoreMedia
import CoreGraphics
import GlanceCore

/// GlanceCore-backed HAP source reader — makes a HAP `.mov` usable as an
/// ENCODE source. A near-verbatim parallel of `DxvSourceReader`: demux
/// once via `HAPDemuxer`, then per-frame decode to straight-alpha RGBA
/// via `HAPThumbnail.rgbaOfFrame` (the same synchronous, CPU, clock-free
/// per-frame decoder `HAPPlayer` uses), package as a BGRA `CVPixelBuffer`
/// through the shared `DxvSourceReader.makeBGRAPixelBuffer` (the R↔B
/// swap), and emit a `.last` `PixelFrame`. No new swap/premultiply/format
/// code — the RGBA→BGRA reconciliation is reused unchanged.
///
/// Covers Hap1/Hap5/HapY/HapM. HapA (alpha-only) is excluded at dispatch.
/// macOS has no HAP video decoder registered with VideoToolbox, so HAP
/// would otherwise fail in `AVAssetReaderSourceReader` (AVFoundation
/// -11833 "Cannot Decode").
///
/// Alpha: `rgbaOfFrame` decodes the alpha plane (Hap5 DXT5 alpha block,
/// HapM's inner HapA) straight into the RGBA `A` byte, which the BGRA
/// fill copies to `A`, so a DXT5/YG10 alpha-bearing encode receives the
/// source's alpha. Tagged `.last` (straight alpha), matching the DXV and
/// AVAssetReader paths.
public final class HAPSourceReader: SourceFrameReader {
    public let sourceWidth: Int
    public let sourceHeight: Int
    public let sourceFPS: Double
    public let totalFrameCount: Int

    private let url: URL
    private let index: HAPMovieIndex
    private var frameIdx: Int = 0
    /// One-shot guard so the reader logs its resolved format exactly once.
    private var loggedDiag = false

    public init(url: URL) throws {
        self.url = url
        let idx = try HAPDemuxer.demux(url: url)
        // Hardening Fix-Brief 1 — validate the demuxed geometry at the
        // reader trust boundary, before the unchecked width×height×4
        // allocation inside HAPThumbnail.rgbaOfFrame (a lying HAP header
        // claiming e.g. 100000×100000 would otherwise overflow/OOM there).
        let durationSec = idx.frameRate > 0
            ? Double(idx.frames.count) / idx.frameRate : 0
        try validateSourceGeometry(
            width: idx.width, height: idx.height,
            fps: idx.frameRate, duration: durationSec)
        self.index = idx
        self.sourceWidth = idx.width
        self.sourceHeight = idx.height
        self.sourceFPS = idx.frameRate
        self.totalFrameCount = idx.frames.count
        FileHandle.standardError.write(Data(
            ("[GlEnc/hap-source] init url=\(url.lastPathComponent) " +
             "variant=\(idx.variant) dims=\(idx.width)x\(idx.height) " +
             "frameRate=\(idx.frameRate) frames=\(idx.frames.count)\n").utf8))
    }

    public func readNextFrame() throws -> PixelFrame? {
        guard frameIdx < index.frames.count else { return nil }
        let myIdx = frameIdx
        frameIdx += 1

        let rgba: [UInt8]
        let w: Int
        let h: Int
        do {
            (rgba, w, h) = try HAPThumbnail.rgbaOfFrame(at: myIdx, in: index, url: url)
        } catch {
            throw SourceReaderError.dxvDecodeFailed(idx: myIdx, underlying: error)
        }

        if !loggedDiag {
            loggedDiag = true
            FileHandle.standardError.write(Data(
                ("[GlEnc/hap-source] first frame: variant=\(index.variant) " +
                 "dims=\(w)x\(h) rgba.count=\(rgba.count) (expect \(w * h * 4))\n").utf8))
        }

        guard let pb = try DxvSourceReader.makeBGRAPixelBuffer(
                rgba: Data(rgba), width: w, height: h) else {
            throw SourceReaderError.pixelBufferCreateFailed(kCVReturnAllocationFailed)
        }
        let pts = CMTime(seconds: index.frames[myIdx].presentationTime,
                         preferredTimescale: 600)
        return PixelFrame(pixelBuffer: pb, presentationTime: pts, alphaInfo: .last)
    }
}

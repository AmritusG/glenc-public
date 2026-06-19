// SPDX-License-Identifier: MIT
// vendored from AmritusG/glance @ e134a3a (v0.7.0), GlEnc's validated pin
import Foundation
import CoreGraphics

/// High-level helper that takes a HAP MOV file URL and produces a
/// CGImage of frame 0. Wraps demux → packet read → section decode →
/// CPURender. Mirrors `DXVThumbnail.cgImageOfFirstFrame(at:)`'s
/// surface so Crate's existing dispatch pattern can route by codec
/// family with no API drift between the two.
///
/// Returns the standard `ThumbnailError.notAHAPFile` for non-HAP
/// input so the caller can let the system fall back gracefully.
public enum HAPThumbnail {

    public enum ThumbnailError: Error, CustomStringConvertible {
        case notAHAPFile(fourCC: String?)
        case noFrames
        case readShort(needed: Int, got: Int)
        case unsupportedVariant(HAPVariant)
        case decodeFailed(underlying: Error)

        public var description: String {
            switch self {
            case .notAHAPFile(let cc):
                return "Not a HAP file (FourCC=\(cc ?? "<unknown>"))"
            case .noFrames:
                return "HAP file has no frames"
            case .readShort(let n, let g):
                return "Read short: needed \(n), got \(g)"
            case .unsupportedVariant(let v):
                return "Unsupported HAP variant for this Glance version: \(v.displayName) — HapQ / HapM ship in Phase 6.b"
            case .decodeFailed(let e):
                return "HAP decode failed: \(e)"
            }
        }
    }

    /// Decode frame 0 of the HAP file at `url` and return it as a
    /// CGImage. Supports all five HAP variants
    /// (Hap1 / Hap5 / HapY / HapM / HapA). Internally delegates to
    /// `rgbaOfFrame(at:in:url:)` and wraps the result in a CGImage.
    public static func cgImageOfFirstFrame(at url: URL) throws -> CGImage {
        // Fast FourCC pre-check so we don't run the demuxer on a
        // 10GB H.264 file. Mirrors `DXVThumbnail`'s pattern.
        let fourCC = DXVDetector.compressorFourCC(at: url)
        guard let fourCC, HAPDetector.isHAPFourCC(fourCC) else {
            throw ThumbnailError.notAHAPFile(fourCC: fourCC)
        }

        let index: HAPMovieIndex
        do {
            index = try HAPDemuxer.demux(url: url)
        } catch {
            throw ThumbnailError.decodeFailed(underlying: error)
        }
        let result = try rgbaOfFrame(at: 0, in: index, url: url)
        do {
            return try cgImageFromRGBA(
                rgba: result.rgba,
                width: result.width, height: result.height
            )
        } catch {
            throw ThumbnailError.decodeFailed(underlying: error)
        }
    }

    /// Phase 6.b post-tag (v0.6.1): frame-N decode for the playback
    /// hot path. Returns raw RGBA bytes plus the index's dims so
    /// callers (Crate's HAPPreviewLayer) can demux once at player
    /// init and call this per frame without re-reading the moov
    /// atom. CGImage allocation lives only on the thumbnail path
    /// (`cgImageOfFirstFrame`); playback uploads these bytes
    /// straight to a GL texture.
    ///
    /// Variant dispatch matches `cgImageOfFirstFrame`:
    /// - Hap1 → `CPURender.unpackDXT1ToRGBA` (already RGBA-shaped)
    /// - Hap5 → `CPURender.unpackDXT5ToRGBA`
    /// - HapY → `HAPHQDecoder.decodeHapYToRGBA`
    /// - HapM → `HAPHQDecoder.decodeHapMToRGBA` (outer 0x0D path)
    /// - HapA → `HAPHQDecoder.decodeHapAToRGBA`
    public static func rgbaOfFrame(
        at frameIndex: Int,
        in index: HAPMovieIndex,
        url: URL
    ) throws -> (rgba: [UInt8], width: Int, height: Int) {
        guard frameIndex >= 0, frameIndex < index.frames.count else {
            throw ThumbnailError.noFrames
        }
        let frame = index.frames[frameIndex]

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw ThumbnailError.decodeFailed(underlying: error)
        }
        defer { try? handle.close() }

        let packet: Data
        do {
            try handle.seek(toOffset: frame.fileOffset)
            guard let data = try handle.read(upToCount: Int(frame.size)),
                  data.count == Int(frame.size) else {
                throw ThumbnailError.readShort(needed: Int(frame.size), got: 0)
            }
            packet = data
        } catch let e as ThumbnailError {
            throw e
        } catch {
            throw ThumbnailError.decodeFailed(underlying: error)
        }

        let w = index.width
        let h = index.height
        do {
            if index.variant == .hapM {
                let rgba = try HAPHQDecoder.decodeHapMToRGBA(
                    outerPacket: packet, width: w, height: h
                )
                return (rgba, w, h)
            }
            let (payload, kind) = try HAPPacketDecoder.decode(packet: packet)
            switch kind {
            case .dxt1Rgb:
                let rgba = CPURender.unpackDXT1ToRGBA(
                    dxt1: payload, width: w, height: h,
                    paddingAlignment: 4
                )
                return (rgba, w, h)
            case .dxt5Rgba:
                let rgba = CPURender.unpackDXT5ToRGBA(
                    dxt5: payload, width: w, height: h,
                    paddingAlignment: 4
                )
                return (rgba, w, h)
            case .scaledYCoCg:
                let rgba = try HAPHQDecoder.decodeHapYToRGBA(
                    dxt5Bytes: payload, width: w, height: h
                )
                return (rgba, w, h)
            case .rgtc1Alpha:
                let rgba = try HAPHQDecoder.decodeHapAToRGBA(
                    rgtc1Bytes: payload, width: w, height: h
                )
                return (rgba, w, h)
            }
        } catch {
            throw ThumbnailError.decodeFailed(underlying: error)
        }
    }

    /// CGImage construction from an RGBA byte buffer. Reused by
    /// `cgImageOfFirstFrame` to wrap `rgbaOfFrame`'s output.
    private static func cgImageFromRGBA(
        rgba: [UInt8], width: Int, height: Int
    ) throws -> CGImage {
        let bytesPerRow = width * 4
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else {
            throw ThumbnailError.decodeFailed(underlying: NSError(domain: "HAPThumbnail", code: -1))
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
        guard let cg = CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            throw ThumbnailError.decodeFailed(underlying: NSError(domain: "HAPThumbnail", code: -2))
        }
        return cg
    }
}


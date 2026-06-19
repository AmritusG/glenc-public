// SPDX-License-Identifier: MIT
// vendored from AmritusG/glance @ e134a3a (v0.7.0), GlEnc's validated pin
import Foundation
import CoreGraphics

/// High-level helper that takes a DXV file URL and produces a CGImage
/// of frame 0. Wraps demux → packet read → variant-specific decode →
/// CPURender. Used by the Quick Look extension [Phase 6b] for both
/// thumbnail and preview.
///
/// Returns nil for non-DXV files (gracefully — caller decides whether
/// that means "let system fall back" or "show error").
public enum DXVThumbnail {

    public enum ThumbnailError: Error, CustomStringConvertible {
        case notADXVFile(fourCC: String?)
        case noFrames
        case readShort(needed: Int, got: Int)
        case decodeFailed(underlying: Error)
        public var description: String {
            switch self {
            case .notADXVFile(let cc): return "Not a DXV file (FourCC=\(cc ?? "<unknown>"))"
            case .noFrames: return "DXV file has no frames"
            case .readShort(let n, let g): return "Read short: needed \(n), got \(g)"
            case .decodeFailed(let e): return "Decode failed: \(e)"
            }
        }
    }

    /// Decode frame 0 of the DXV file at `url` and return it as a
    /// CGImage. Throws ThumbnailError.notADXVFile for unrecognised
    /// codecs (callers can use this to detect "let system handle it").
    public static func cgImageOfFirstFrame(at url: URL) throws -> CGImage {
        // Quick FourCC pre-check so we fail fast without running the
        // demuxer on a 10GB H.264 file. The trak-level FourCC for DXV3
        // files in the wild is the version-tag form (DXD3, occasionally
        // DXDI), not "DXV3" — the texture-format variant lives in each
        // per-packet header and is resolved by `DXVDemuxer.demux` (see
        // its variant switch ~line 345). Accept all three so real files
        // aren't bounced by a pre-check stricter than the demuxer.
        let fourCC = DXVDetector.compressorFourCC(at: url)
        guard let fourCC = fourCC,
              fourCC == "DXV3" || fourCC == "DXD3" || fourCC == "DXDI"
        else {
            throw ThumbnailError.notADXVFile(fourCC: fourCC)
        }

        let index: DXVMovieIndex
        do {
            index = try DXVDemuxer.demux(url: url)
        } catch {
            throw ThumbnailError.decodeFailed(underlying: error)
        }
        guard let firstFrame = index.frames.first else {
            throw ThumbnailError.noFrames
        }

        // Read just frame 0's packet.
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw ThumbnailError.decodeFailed(underlying: error)
        }
        defer { try? handle.close() }

        let packet: Data
        do {
            try handle.seek(toOffset: firstFrame.fileOffset)
            guard let data = try handle.read(upToCount: Int(firstFrame.size)),
                  data.count == Int(firstFrame.size) else {
                throw ThumbnailError.readShort(
                    needed: Int(firstFrame.size),
                    got: 0)
            }
            packet = data
        } catch let e as ThumbnailError {
            throw e
        } catch {
            throw ThumbnailError.decodeFailed(underlying: error)
        }

        do {
            switch index.variant {
            case .dxt1, .dxt5:
                return try decodeDXTPacket(packet: packet, index: index)
            case .ycg6:
                return try decodeYCG6Packet(packet: packet, index: index)
            case .yg10:
                return try decodeYG10Packet(packet: packet, index: index)
            }
        } catch {
            throw ThumbnailError.decodeFailed(underlying: error)
        }
    }

    // MARK: - Variant decoders

    private static func decodeDXTPacket(packet: Data, index: DXVMovieIndex) throws -> CGImage {
        // Resolume's DXV3 encoder pads BC1/BC3 block data to 16-pixel-aligned
        // widths. The DXV1 encoder pads BOTH width AND height to 16-pixel
        // block alignment (observed against Metric_01.mov: 1920x1080 DXT1
        // LZF-decompresses to exactly 1920x1088/2 = 1,044,480 bytes, not the
        // 1920x1080/2 = 1,036,800 the display dimensions would suggest).
        // Request the padded byte count so the LZF decompressor sees the
        // full encoded buffer; CPURender stops at `height/4` block rows and
        // discards the trailing padding rows.
        let paddedWidth = (index.width + 15) / 16 * 16
        let textureHeight: Int
        switch index.generation {
        case .dxv1: textureHeight = (index.height + 15) / 16 * 16
        case .dxv3: textureHeight = index.height
        }
        let dxtSize: Int
        switch index.variant {
        case .dxt1: dxtSize = paddedWidth * textureHeight / 2
        case .dxt5: dxtSize = paddedWidth * textureHeight
        default: fatalError("decodeDXTPacket on non-DXT variant")
        }

        let dxtBytes: Data
        switch index.generation {
        case .dxv3:
            let (header, payload) = try DXVPacketDecoder.parseHeader(packet)
            if header.rawFlag == 1 {
                dxtBytes = payload.prefix(dxtSize)
            } else {
                switch index.variant {
                case .dxt1:
                    dxtBytes = try DXVPacketDecoder.decompressDXT1(payload, expectedSize: dxtSize)
                case .dxt5:
                    dxtBytes = try DXVPacketDecoder.decompressDXT5(payload, expectedSize: dxtSize)
                default: fatalError("decodeDXTPacket on non-DXT variant")
                }
            }
        case .dxv1:
            let (header, payload) = try DXV1PacketDecoder.parseHeader(packet)
            dxtBytes = try DXV1PacketDecoder.decodePayload(
                payload, header: header, expectedSize: dxtSize)
        }

        return try CPURender.cgImageFromDXT(
            dxtBytes: dxtBytes,
            variant: index.variant,
            width: index.width, height: index.height)
    }

    private static func decodeYCG6Packet(packet: Data, index: DXVMovieIndex) throws -> CGImage {
        let (_, payload) = try DXVPacketDecoder.parseHeader(packet)
        // See decodeDXTPacket: DXVHQDecoder takes codedWidth, which we pass
        // padded to 16-pixel alignment. CPURender.cgImageFromHQ crops the
        // padded output to display width via `displayWidth:`.
        let paddedWidth = (index.width + 15) / 16 * 16
        let luma = try DXVHQDecoder.decompressYCG6LumaPlane(
            payload: payload,
            codedWidth: paddedWidth, codedHeight: index.height)
        let chroma = try DXVHQDecoder.decompressYCG6ChromaPlane(
            payload: payload, startCursor: luma.postCursor,
            codedWidth: paddedWidth, codedHeight: index.height)
        return try CPURender.cgImageFromHQ(
            y: luma.luma, co: chroma.co, cg: chroma.cg, a: nil,
            width: paddedWidth, height: index.height,
            chromaWidth: chroma.chromaWidth, chromaHeight: chroma.chromaHeight,
            displayWidth: index.width)
    }

    private static func decodeYG10Packet(packet: Data, index: DXVMovieIndex) throws -> CGImage {
        let (_, payload) = try DXVPacketDecoder.parseHeader(packet)
        let paddedWidth = (index.width + 15) / 16 * 16
        let result = try DXVHQDecoder.decompressYG10(
            payload: payload,
            codedWidth: paddedWidth, codedHeight: index.height)
        return try CPURender.cgImageFromHQ(
            y: result.y, co: result.co, cg: result.cg, a: result.a,
            width: paddedWidth, height: index.height,
            chromaWidth: result.chromaWidth, chromaHeight: result.chromaHeight,
            displayWidth: index.width)
    }
}

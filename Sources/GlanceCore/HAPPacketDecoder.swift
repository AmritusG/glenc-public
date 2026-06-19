// SPDX-License-Identifier: MIT
// vendored from AmritusG/glance @ e134a3a (v0.7.0), GlEnc's validated pin
import Foundation
import Snappy

/// Decode a HAP frame packet into raw DXT bytes ready for
/// `CPURender.cgImageFromDXT`. Reads the 4-byte (or 8-byte
/// extended-form) section header, optionally Snappy-decompresses the
/// payload, and returns the resulting DXT block bytes.
///
/// Spec reference: https://github.com/Vidvox/hap/blob/master/documentation/HapVideoDRAFT.md
///   Section type byte: high nibble = compression, low nibble = format.
///   0xAB = uncompressed RGB DXT1 (Hap1)
///   0xBB = Snappy-compressed RGB DXT1 (Hap1)
///   0xAE = uncompressed RGBA DXT5 (Hap5)
///   0xBE = Snappy-compressed RGBA DXT5 (Hap5)
///   0xAF / 0xBF = Scaled YCoCg DXT5 (HapQ) — Phase 6.b
///   0x0D       = Multi-section container (HapM / HapAlphaOnly) — 6.b
///
/// Length field: 3 bytes little-endian. If those three bytes are
/// all zero, the header extends to 8 bytes total and bytes 5-8
/// hold a 32-bit LE length. Long form is used when a section
/// exceeds 16 MB (e.g. uncompressed 4K HQ).
public enum HAPPacketDecoder {

    public enum DecodeError: Error, CustomStringConvertible {
        /// Packet is shorter than the section header itself, or the
        /// header announces a length that runs past the packet end.
        case malformedHeader(reason: String)
        /// Section type byte isn't one we know how to handle.
        /// 6.a/6.b-pause-1 accept 0xAB / 0xBB / 0xAE / 0xBE / 0xAF / 0xBF.
        /// RGTC1 alpha (0xA1 / 0xB1) ships in pause 2; multi-section
        /// (0x0D) in pause 3; Decode-Instructions container (0xC*)
        /// is deferred past Phase 6.b.
        case unsupportedSectionType(UInt8)
        case snappyDecompressFailed(underlying: Error)

        public var description: String {
            switch self {
            case .malformedHeader(let r):
                return "HAP packet header malformed: \(r)"
            case .unsupportedSectionType(let t):
                return String(format: "Unsupported HAP section type: 0x%02X", t)
            case .snappyDecompressFailed(let e):
                return "Snappy decompress failed: \(e)"
            }
        }
    }

    /// Parsed section header. `payloadOffset` is relative to the
    /// start of the packet; `payloadLength` is the size of the
    /// payload following the header (already validated against
    /// packet bounds).
    public struct SectionHeader: Equatable {
        public let sectionType: UInt8
        public let payloadOffset: Int
        public let payloadLength: Int
    }

    /// What kind of texture data a HAP section's payload represents
    /// after any second-stage decompression has been applied.
    /// Callers route by this enum to the right decoder
    /// (`CPURender.cgImageFromDXT` for the DXT variants,
    /// `HAPHQDecoder` for the YCoCg / RGTC1 variants).
    public enum TextureKind: Equatable {
        case dxt1Rgb        // Hap1: RGB DXT1 → CPURender.cgImageFromDXT(.dxt1)
        case dxt5Rgba       // Hap5: RGBA DXT5 → CPURender.cgImageFromDXT(.dxt5)
        case scaledYCoCg    // HapY: DXT5 reinterpreted as Y / Co / Cg / scale → HAPHQDecoder.decodeHapY
        case rgtc1Alpha     // HapA: RGTC1 / BC4 single-channel alpha → HAPHQDecoder.decodeHapA (Phase 6.b pause 2)
    }

    /// Parse the section header at the start of `packet` and return
    /// the (post-Snappy) payload + a `TextureKind` describing how to
    /// decode it.
    public static func decode(packet: Data) throws -> (payload: Data, kind: TextureKind) {
        let header = try parseSectionHeader(packet: packet)
        let payload = packet.subdata(
            in: packet.startIndex + header.payloadOffset
                ..< packet.startIndex + header.payloadOffset + header.payloadLength
        )
        switch header.sectionType {
        // Hap1 (RGB DXT1)
        case 0xAB:
            return (payload, .dxt1Rgb)
        case 0xBB:
            return (try snappyDecompress(payload), .dxt1Rgb)
        // Hap5 (RGBA DXT5)
        case 0xAE:
            return (payload, .dxt5Rgba)
        case 0xBE:
            return (try snappyDecompress(payload), .dxt5Rgba)
        // HapY (Scaled YCoCg DXT5) — Phase 6.b pause 1
        case 0xAF:
            return (payload, .scaledYCoCg)
        case 0xBF:
            return (try snappyDecompress(payload), .scaledYCoCg)
        // HapA (RGTC1 / BC4 alpha) — Phase 6.b pause 2
        case 0xA1:
            return (payload, .rgtc1Alpha)
        case 0xB1:
            return (try snappyDecompress(payload), .rgtc1Alpha)
        // Chunked-Snappy second-stage compression (0xC_ high nibble).
        // Payload starts with a 0x01 "Decode Instructions Container"
        // describing N chunks, each independently compressed with
        // either Snappy (0x0B) or no-compression (0x0A). After the
        // 0x01 metadata block, the N chunk byte streams follow
        // back-to-back. Low nibble determines the texture format
        // post-decompression — same mapping as 0xA_ / 0xB_.
        // Encoders use this format for parallel decode of large
        // frames; real HapM files in the wild commonly stream as
        // 0xCF / 0xC1 even when single-chunk.
        case 0xCB:
            return (try decodeChunkedSection(payload: payload), .dxt1Rgb)
        case 0xCE:
            return (try decodeChunkedSection(payload: payload), .dxt5Rgba)
        case 0xCF:
            return (try decodeChunkedSection(payload: payload), .scaledYCoCg)
        case 0xC1:
            return (try decodeChunkedSection(payload: payload), .rgtc1Alpha)
        default:
            throw DecodeError.unsupportedSectionType(header.sectionType)
        }
    }

    /// Header-only parse — exposed so callers can inspect a packet
    /// without committing to a decode (e.g. for diagnostics).
    public static func parseSectionHeader(packet: Data) throws -> SectionHeader {
        guard packet.count >= 4 else {
            throw DecodeError.malformedHeader(reason: "packet < 4 bytes")
        }
        let base = packet.startIndex
        // First three bytes are the section length, little-endian.
        // Fourth byte is the section type.
        let b0 = UInt32(packet[base])
        let b1 = UInt32(packet[base + 1])
        let b2 = UInt32(packet[base + 2])
        let typeShort = packet[base + 3]
        let lengthShort = b0 | (b1 << 8) | (b2 << 16)

        let sectionType: UInt8
        let payloadOffset: Int
        let payloadLength: Int

        if lengthShort == 0 {
            // Extended header: type byte stays at offset 3; length
            // is a 32-bit LE value at offsets 4..<8. Total header
            // is 8 bytes.
            guard packet.count >= 8 else {
                throw DecodeError.malformedHeader(reason: "extended header < 8 bytes")
            }
            sectionType = typeShort
            let l0 = UInt32(packet[base + 4])
            let l1 = UInt32(packet[base + 5])
            let l2 = UInt32(packet[base + 6])
            let l3 = UInt32(packet[base + 7])
            let lengthLong = l0 | (l1 << 8) | (l2 << 16) | (l3 << 24)
            payloadOffset = 8
            payloadLength = Int(lengthLong)
        } else {
            sectionType = typeShort
            payloadOffset = 4
            payloadLength = Int(lengthShort)
        }

        guard payloadOffset + payloadLength <= packet.count else {
            throw DecodeError.malformedHeader(
                reason: "section payload runs past packet end (offset=\(payloadOffset), length=\(payloadLength), packet=\(packet.count))"
            )
        }
        return SectionHeader(
            sectionType: sectionType,
            payloadOffset: payloadOffset,
            payloadLength: payloadLength
        )
    }

    private static func snappyDecompress(_ payload: Data) throws -> Data {
        do {
            return try payload.uncompressedUsingSnappy()
        } catch {
            throw DecodeError.snappyDecompressFailed(underlying: error)
        }
    }

    /// Decode a chunked-Snappy section (0xC_ high nibble) into raw
    /// texture bytes. Payload layout:
    /// ```
    ///   [0x01 Decode Instructions Container section]
    ///     ↳ 0x02 Chunk Compressor Table — N bytes (0x0A=none, 0x0B=Snappy)
    ///     ↳ 0x03 Chunk Size Table — N × uint32 LE
    ///     ↳ 0x04 Chunk Offset Table — N × uint32 LE (optional; we ignore
    ///        it because offsets are reconstructable from sizes)
    ///   [Chunk 0 bytes] [Chunk 1 bytes] … [Chunk N-1 bytes]
    /// ```
    /// Returns the concatenated decompressed texture data.
    private static func decodeChunkedSection(payload: Data) throws -> Data {
        // First nested section is the 0x01 metadata container.
        let metaHeader = try parseSectionHeader(packet: payload)
        guard metaHeader.sectionType == 0x01 else {
            throw DecodeError.malformedHeader(
                reason: String(format: "chunked section: expected 0x01 metadata, got 0x%02X", metaHeader.sectionType)
            )
        }
        let metaStart = payload.startIndex + metaHeader.payloadOffset
        let metaEnd = metaStart + metaHeader.payloadLength
        let metaBuffer = payload.subdata(in: metaStart..<metaEnd)

        var compressors: [UInt8] = []
        var sizes: [UInt32] = []

        // Walk the metadata sub-sections (0x02 / 0x03 / 0x04 in any order).
        var cursor = 0
        while cursor < metaBuffer.count {
            let sub = metaBuffer.subdata(
                in: metaBuffer.startIndex + cursor ..< metaBuffer.endIndex
            )
            let subHeader = try parseSectionHeader(packet: sub)
            let subTotal = subHeader.payloadOffset + subHeader.payloadLength
            let subPayloadStart = sub.startIndex + subHeader.payloadOffset
            let subPayloadEnd = sub.startIndex + subTotal
            let subPayload = sub.subdata(in: subPayloadStart..<subPayloadEnd)
            switch subHeader.sectionType {
            case 0x02:
                compressors = Array(subPayload)
            case 0x03:
                sizes = readUInt32LEArray(subPayload)
            case 0x04:
                // Offset table — ignored; we walk chunks sequentially
                // by accumulating sizes.
                break
            default:
                // Unknown sub-section type; safe to skip per spec.
                break
            }
            cursor += subTotal
        }

        guard !compressors.isEmpty, compressors.count == sizes.count else {
            throw DecodeError.malformedHeader(
                reason: "chunked metadata: \(compressors.count) compressors, \(sizes.count) sizes"
            )
        }

        // Chunk data starts immediately after the 0x01 metadata
        // section ends (within the outer 0xC_ payload).
        var chunkCursor = metaEnd
        var output = Data()
        for i in 0..<compressors.count {
            let chunkLen = Int(sizes[i])
            let chunkEnd = chunkCursor + chunkLen
            guard chunkEnd <= payload.endIndex else {
                throw DecodeError.malformedHeader(
                    reason: "chunk \(i) extends past chunked section payload"
                )
            }
            let chunkData = payload.subdata(in: chunkCursor..<chunkEnd)
            switch compressors[i] {
            case 0x0A:
                output.append(chunkData)
            case 0x0B:
                output.append(try snappyDecompress(chunkData))
            default:
                throw DecodeError.malformedHeader(
                    reason: String(format: "chunk %d unknown compressor 0x%02X", i, compressors[i])
                )
            }
            chunkCursor = chunkEnd
        }
        return output
    }

    private static func readUInt32LEArray(_ data: Data) -> [UInt32] {
        let count = data.count / 4
        var result = [UInt32]()
        result.reserveCapacity(count)
        let base = data.startIndex
        for i in 0..<count {
            let b0 = UInt32(data[base + i * 4    ])
            let b1 = UInt32(data[base + i * 4 + 1])
            let b2 = UInt32(data[base + i * 4 + 2])
            let b3 = UInt32(data[base + i * 4 + 3])
            result.append(b0 | (b1 << 8) | (b2 << 16) | (b3 << 24))
        }
        return result
    }
}

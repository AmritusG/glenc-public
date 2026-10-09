// SPDX-License-Identifier: MIT
import Foundation

/// DXV3 packet-level API, kept for callers that decode packets themselves
/// (Crate's thumbnail and measurement code). Since the DXVKit wave every
/// byte is decoded by DXVKit (see `DXVKitBridge`); this file only parses
/// the 12-byte header and adapts the old header-less entry points.
///
/// Prefer decoding whole packets (`DXVPlayer`, `DXVThumbnail`): DXVKit then
/// decides the generation from the packet and handles stored HQ packets,
/// which these payload-level entry points cannot see.
public enum DXVPacketDecoder {

    public enum DecodeError: Error, CustomStringConvertible {
        /// Fewer than the 12 header bytes.
        case truncatedHeader(available: Int)
        /// The header declares more payload than the packet holds.
        case truncatedPayload(declared: Int, available: Int)
        /// DXVKit rejected the payload.
        case decodeFailed(String)

        public var description: String {
            switch self {
            case .truncatedHeader(let n): return "DXV packet: header truncated (\(n) of 12 bytes)"
            case .truncatedPayload(let d, let a): return "DXV packet: payload truncated (declared \(d), available \(a))"
            case .decodeFailed(let s): return "DXV packet: \(s)"
            }
        }
    }

    /// The 12-byte DXV3 packet header:
    ///   bytes 0-3   texture tag, a little-endian u32 of the big-endian FourCC
    ///               value ("DXT1" is stored "1TXD")
    ///   byte 4      version byte (DXV3 writes 4: version major + 1)
    ///   byte 5      version minor
    ///   byte 6      stored flag (1 = uncompressed payload, 0 = compressed)
    ///   byte 7      reserved
    ///   bytes 8-11  payload length, little-endian u32
    public struct PacketHeader {
        /// "DXT1", "DXT5", "YCG6" or "YG10" for DXV3 packets.
        public let tag: String
        /// Version major (header byte 4 minus 1; 3 for current DXV3).
        public let versionMajor: UInt8
        public let versionMinor: UInt8
        /// 1 = stored (uncompressed) payload, 0 = compressed.
        public let rawFlag: UInt8
        public let payloadSize: UInt32

        public init(tag: String, versionMajor: UInt8, versionMinor: UInt8, rawFlag: UInt8, payloadSize: UInt32) {
            self.tag = tag
            self.versionMajor = versionMajor
            self.versionMinor = versionMinor
            self.rawFlag = rawFlag
            self.payloadSize = payloadSize
        }
    }

    /// Splits a DXV3 packet into its header and payload (exactly the declared
    /// length; trailing bytes are ignored).
    public static func parseHeader(_ packet: Data) throws -> (header: PacketHeader, payload: Data) {
        let b = [UInt8](packet.prefix(12))
        guard b.count == 12 else { throw DecodeError.truncatedHeader(available: b.count) }
        let tag = String(bytes: [b[3], b[2], b[1], b[0]], encoding: .ascii) ?? ""
        let size = Int(b[8]) | Int(b[9]) << 8 | Int(b[10]) << 16 | Int(b[11]) << 24
        guard packet.count - 12 >= size else {
            throw DecodeError.truncatedPayload(declared: size, available: packet.count - 12)
        }
        let start = packet.startIndex + 12
        let header = PacketHeader(tag: tag, versionMajor: b[4] &- 1, versionMinor: b[5],
                                  rawFlag: b[6], payloadSize: UInt32(size))
        return (header, Data(packet[start..<(start + size)]))
    }

    /// BC1 blocks of a compressed DXT1 payload: the first `expectedSize` bytes
    /// of the 16-padded block stream (as before: `paddedWidth * height / 2`).
    public static func decompressDXT1(_ payload: Data, expectedSize: Int) throws -> Data {
        do { return try DXVKitBridge.dxtBlocks(payload: payload, tag: "DXT1", expectedSize: expectedSize) }
        catch { throw DecodeError.decodeFailed("\(error)") }
    }

    /// BC3 blocks of a compressed DXT5 payload: the first `expectedSize` bytes
    /// of the 16-padded block stream (as before: `paddedWidth * height`).
    public static func decompressDXT5(_ payload: Data, expectedSize: Int) throws -> Data {
        do { return try DXVKitBridge.dxtBlocks(payload: payload, tag: "DXT5", expectedSize: expectedSize) }
        catch { throw DecodeError.decodeFailed("\(error)") }
    }
}

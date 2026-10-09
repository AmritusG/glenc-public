// SPDX-License-Identifier: MIT
import Foundation

/// GPU-ready decode of one DXV packet (DXVKit underneath), as the players use
/// it. Reuses its buffers between calls, so keep one per decoding thread (not
/// thread-safe).
///
///   let decoder = DXVFrameDecoder(index: try DXVDemuxer.demux(url: url))
///   switch try decoder.decode(packet: bytesOfSample) {
///   case .dxt(let blocks): renderer.uploadFrame(dxtBytes: blocks, ...)
///   case .hq(let hq): renderer.uploadHQFrame(...)   // or wrap in DXVHQFrame
///   }
public final class DXVFrameDecoder {

    public enum Frame {
        /// BC1 (DXT1) / BC3 (DXT5) blocks: 16-pixel-aligned block columns,
        /// ceil(height / 4) block rows (what `DXVRenderer.uploadFrame` takes).
        case dxt(Data)
        /// YCG6 / YG10 block streams over the 16 x 16 padded coded texture.
        case hq(HQBlocks)
    }

    public struct HQBlocks: Sendable {
        /// BC4 Y (YCG6) or BC5 Y + A (YG10), codedWidth x codedHeight.
        public let luma: Data
        /// BC5 Co + Cg, codedWidth / 2 x codedHeight / 2.
        public let chroma: Data
        public let hasAlpha: Bool
        public let codedWidth: Int
        public let codedHeight: Int
    }

    public enum DecodeError: Error, CustomStringConvertible {
        /// The packet's texture format differs from the file's first packet
        /// (DXT vs HQ, or with vs without alpha); the player can't switch
        /// renderer path mid-file.
        case variantChanged(expected: DXVVariant, found: String)
        public var description: String {
            switch self {
            case .variantChanged(let e, let f): return "DXV packet variant \(f) differs from the file's \(e.displayName)"
            }
        }
    }

    public let index: DXVMovieIndex
    private let frame = DXVKitFrame()

    public init(index: DXVMovieIndex) {
        self.index = index
    }

    /// Decodes one sample's bytes. Throws DXVKit's error for a malformed packet.
    public func decode(packet: Data) throws -> Frame {
        try DXVKitBridge.decode(packet: packet, index: index, into: frame)
        let layout = frame.layout!
        switch (index.variant, layout.variant) {
        case (.dxt1, .dxt1), (.dxt1, .legacyDXT1), (.dxt5, .dxt5), (.dxt5, .legacyDXT5):
            return .dxt(DXVKitBridge.dxtUploadBytes(frame, displayHeight: index.height))
        case (.ycg6, .ycg6), (.yg10, .yg10):
            return .hq(HQBlocks(luma: DXVKitBridge.planeData(frame, 0), chroma: DXVKitBridge.planeData(frame, 1),
                                hasAlpha: layout.variant == .yg10,
                                codedWidth: layout.codedWidth, codedHeight: layout.codedHeight))
        default:
            throw DecodeError.variantChanged(expected: index.variant, found: layout.variant.name)
        }
    }
}

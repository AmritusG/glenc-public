// SPDX-License-Identifier: MIT
import Foundation
import CDXVKit
import DXVKit

/// Glance's single point of contact with DXVKit (AmritusG/dxvkit, pinned
/// v1.0.0, MIT, clean room). Every DXV decode in GlanceCore and
/// GlancePlayback goes through here.
///
/// DXVKit's geometry (`dxvkit.h`): every block stream covers the CODED
/// texture, the display size rounded up to 16 on BOTH axes, row by row, top
/// row first.
///   plane 0: BC1 (DXT1) / BC3 (DXT5) / BC4 Y (YCG6) / BC5 Y+A (YG10)
///   plane 1: HQ only, BC5 Co+Cg at codedWidth/2 x codedHeight/2
/// The packet, not the container, decides legacy vs DXV3 (Arena 7.28 rules);
/// the generation passed in is only a hint.
/// DXVKit's reusable frame buffer, spelled without the module (GlanceCore has
/// its own `DXVVariant` / `DXVGeneration`, so DXVKit names are qualified here).
typealias DXVKitFrame = DXVKit.DXVFrame

enum DXVKitBridge {

    // MARK: - Packet decode

    static func generationHint(_ g: DXVGeneration) -> DXVKit.DXVGeneration {
        g == .dxv1 ? .legacy : .dxv3
    }

    /// Decodes one QuickTime sample of `index`'s movie into `frame`.
    static func decode(packet: Data, index: DXVMovieIndex, into frame: DXVKit.DXVFrame) throws {
        try packet.withUnsafeBytes { buf in
            try frame.decode(packet: buf, generation: generationHint(index.generation),
                             width: index.width, height: index.height)
        }
    }

    /// The BC1 / BC3 bytes `DXVRenderer.uploadFrame` / `MetalDXVRenderer.uploadFrame`
    /// take for a display size: 16-padded block columns (as before) and
    /// exactly ceil(displayHeight / 4) block rows, i.e. the prefix of plane 0.
    /// (The pre-DXVKit decoder handed over `paddedWidth * height / 2` bytes,
    /// which equals this when the height is a multiple of 4; for other heights,
    /// and for legacy DXV1 whose buffer covered the 16-padded height, its byte
    /// count did not match the texture and GL rejected the upload.)
    static func dxtUploadBytes(_ frame: DXVKit.DXVFrame, displayHeight: Int) -> Data {
        let p = frame.layout!.planes[0]
        let blockBytes = p.format == .bc1 ? 8 : 16
        let rows = min(p.blocksY, (displayHeight + 3) / 4)
        let count = rows * p.blocksX * blockBytes
        return frame.withPlane(0) { Data(bytes: $0.baseAddress!, count: count) }
    }

    static func planeData(_ frame: DXVKit.DXVFrame, _ plane: Int) -> Data {
        frame.withPlane(plane) { Data(bytes: $0.baseAddress!, count: $0.count) }
    }

    // MARK: - Header-less payload adapters (the pre-DXVKit public API)

    /// Rebuilds a DXV3 packet around a payload. Header layout (12 bytes, see
    /// DXVDemuxer's packet peek and DXVKit's design notes): tag as a
    /// little-endian u32 of the big-endian FourCC value (so "DXT1" is stored
    /// "1TXD"), version byte (4 = current DXV3), minor, stored flag, reserved,
    /// payload length (LE u32).
    static func dxv3Packet(tag: String, stored: Bool, payload: Data) -> Data {
        var p = Data(capacity: payload.count + 12)
        p.append(contentsOf: Array(tag.utf8).reversed())
        p.append(contentsOf: [4, 0, stored ? 1 : 0, 0])
        let n = UInt32(payload.count)
        p.append(contentsOf: [UInt8(n & 0xFF), UInt8((n >> 8) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8(n >> 24)])
        p.append(payload)
        return p
    }

    /// BC1 / BC3 blocks of a header-less DXV3 payload when only the wanted byte
    /// count is known (the old `decompressDXT1(_:expectedSize:)` contract).
    ///
    /// The DXT block stream is one-dimensional (blocks in order), so any coded
    /// geometry with the same block count decodes the same bytes. DXVKit needs a
    /// geometry, and decodes until its texture is full, so pick the smallest
    /// 16x16-aligned geometry holding at least `expectedSize` bytes: its block
    /// count 16k never exceeds the real texture's (whose block count is also a
    /// multiple of 16 and at least the wanted count), so the stream never runs
    /// out early. Proven byte-identical to the old decoder on every DXT packet
    /// in ~/Movies (tools/dxvkit-parity).
    static func dxtBlocks(payload: Data, tag: String, expectedSize: Int) throws -> Data {
        let blockBytes = tag == "DXT1" ? 8 : 16
        let blocks = (expectedSize + blockBytes - 1) / blockBytes
        let limit = Int(DXVK_MAX_DIMENSION) / 16
        var k = max(1, (blocks + 15) / 16)
        var geometry: (Int, Int)? = nil
        while geometry == nil {
            geometry = factor(k, limit: limit)
            if geometry == nil { k += 1 }
        }
        let (a, b) = geometry!
        let frame = DXVKit.DXVFrame()
        let packet = dxv3Packet(tag: tag, stored: false, payload: payload)
        try packet.withUnsafeBytes { try frame.decode(packet: $0, generation: .dxv3, width: a * 16, height: b * 16) }
        return frame.withPlane(0) { Data(bytes: $0.baseAddress!, count: min(expectedSize, $0.count)) }
    }

    /// k = a * b with a, b <= limit (a as large as possible), or nil.
    private static func factor(_ k: Int, limit: Int) -> (Int, Int)? {
        var a = min(k, limit)
        while a >= 1 {
            if k % a == 0, k / a <= limit { return (a, k / a) }
            a -= 1
        }
        return nil
    }

    /// Decodes a header-less YCG6 / YG10 payload at a coded size (the old
    /// `DXVHQDecoder` contract: codedWidth = width padded to 16, codedHeight =
    /// display height; DXVKit pads the height to 16 itself).
    static func hqFrame(payload: Data, tag: String, codedWidth: Int, codedHeight: Int) throws -> DXVKit.DXVFrame {
        let frame = DXVKit.DXVFrame()
        let packet = dxv3Packet(tag: tag, stored: false, payload: payload)
        try packet.withUnsafeBytes { try frame.decode(packet: $0, generation: .dxv3, width: codedWidth, height: codedHeight) }
        return frame
    }

    // MARK: - BCn -> 8-bit planes (for callers of the old plane API)

    /// One BC4 plane (or channel 0 / 1 of a BC5 plane) unpacked over the coded
    /// plane, cropped to `width x height` (each at most the plane size).
    static func unpack(_ frame: DXVKit.DXVFrame, plane: Int, width: Int, height: Int) -> (ch0: [UInt8], ch1: [UInt8]?) {
        let p = frame.layout!.planes[plane]
        var c0 = [UInt8](repeating: 0, count: p.width * p.height)
        var c1: [UInt8]? = p.format == .bc5 ? [UInt8](repeating: 0, count: p.width * p.height) : nil
        frame.withPlane(plane) { buf in
            let blocks = buf.baseAddress!.assumingMemoryBound(to: UInt8.self)
            c0.withUnsafeMutableBufferPointer { o0 in
                if p.format == .bc5 {
                    c1!.withUnsafeMutableBufferPointer { o1 in
                        BC4BC5Unpack.unpackBC5Plane(blocks: blocks, blocksCount: p.blocksX * p.blocksY,
                                                    outputChannel0: o0.baseAddress!, outputChannel1: o1.baseAddress!,
                                                    width: p.width, height: p.height)
                    }
                } else {
                    BC4BC5Unpack.unpackBC4Plane(blocks: blocks, blocksCount: p.blocksX * p.blocksY,
                                                output: o0.baseAddress!, width: p.width, height: p.height)
                }
            }
        }
        return (crop(c0, from: p.width, width: width, height: height), c1.map { crop($0, from: p.width, width: width, height: height) })
    }

    static func crop(_ plane: [UInt8], from stride: Int, width: Int, height: Int) -> [UInt8] {
        if stride == width && plane.count == width * height { return plane }
        var out = [UInt8](repeating: 0, count: width * height)
        for r in 0..<height { out[(r * width)..<((r + 1) * width)] = plane[(r * stride)..<(r * stride + width)] }
        return out
    }

    // MARK: - CPU RGBA (DXVKit dxvk_blocks_to_rgba)

    /// RGBA8 (display size, tightly packed) from DXT block bytes laid out with
    /// 16-padded block columns (the DXVRenderer upload layout). Rows the caller
    /// did not supply decode as zero blocks and are cropped away.
    static func rgbaFromDXT(_ dxtBytes: Data, alpha: Bool, width: Int, height: Int) throws -> [UInt8] {
        var layout = dxvk_frame_layout()
        try check(dxvk_layout(alpha ? DXVK_VARIANT_DXT5 : DXVK_VARIANT_DXT1, UInt32(width), UInt32(height), &layout))
        var plane0 = [UInt8](repeating: 0, count: layout.bytes.0)
        dxtBytes.withUnsafeBytes { src in
            plane0.withUnsafeMutableBytes { dst in
                dst.copyMemory(from: UnsafeRawBufferPointer(rebasing: src.prefix(min(src.count, dst.count))))
            }
        }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        try plane0.withUnsafeBytes { p0 in
            var planes: (UnsafeRawPointer?, UnsafeRawPointer?) = (p0.baseAddress, nil)
            try withUnsafePointer(to: &planes) { pp in
                try pp.withMemoryRebound(to: UnsafeRawPointer?.self, capacity: 2) { p2 in
                    try check(dxvk_blocks_to_rgba(&layout, p2, nil, &rgba, width * 4))
                }
            }
        }
        return rgba
    }

    static func check(_ s: dxvk_status) throws {
        if s != DXVK_OK { throw DXVKitBridgeError.dxvkit(code: Int32(s.rawValue), message: String(cString: dxvk_status_string(s))) }
    }

    // MARK: - Demux (DXVKit's QuickTime reader -> DXVMovieIndex)

    /// Builds the frame index from DXVKit's demuxer. The variant and the
    /// generation are those of the first packet (the packet decides, as in
    /// Arena: a legacy packet in a `DXD3` track is legacy).
    static func movieIndex(url: URL) throws -> DXVMovieIndex {
        var mov: OpaquePointer?
        let status = url.withUnsafeFileSystemRepresentation { dxvk_mov_open_file($0, &mov) }
        guard status == DXVK_OK, let mov else {
            switch status {
            case DXVK_ERR_IO: throw DXVDemuxError.fileOpen(url.path)
            case DXVK_ERR_NOT_MOV, DXVK_ERR_NO_DXV_TRACK:
                throw DXVDemuxError.notDXV(fourCC: DXVDetector.compressorFourCC(at: url) ?? "????")
            default:
                throw DXVDemuxError.unsupported(String(cString: dxvk_status_string(status)))
            }
        }
        defer { dxvk_mov_close(mov) }
        let info = dxvk_mov_get_info(mov)!.pointee
        guard info.frame_count > 0 else { throw DXVDemuxError.missingAtom("samples (no frames)") }
        let timescale = Double(max(info.timescale, 1))
        let step = Double(info.frame_duration) / timescale
        var frames: [DXVFrameEntry] = []
        frames.reserveCapacity(Int(info.frame_count))
        for i in 0..<info.frame_count {
            var offset: UInt64 = 0, size: UInt32 = 0
            try check(dxvk_mov_packet_location(mov, i, &offset, &size))
            frames.append(DXVFrameEntry(fileOffset: offset, size: size, presentationTime: Double(i) * step))
        }
        var head = [UInt8](repeating: 0, count: Int(info.max_packet_size))
        var n = 0
        try check(dxvk_mov_read_packet(mov, 0, &head, head.count, &n))
        var v = DXVK_VARIANT_DXT1
        try check(dxvk_packet_variant(info.generation, head, n, &v, nil))
        let variant: DXVVariant
        var generation: DXVGeneration = .dxv3
        switch v {
        case DXVK_VARIANT_DXT1: variant = .dxt1
        case DXVK_VARIANT_DXT5: variant = .dxt5
        case DXVK_VARIANT_YCG6: variant = .ycg6
        case DXVK_VARIANT_YG10: variant = .yg10
        case DXVK_VARIANT_LEGACY_DXT1: variant = .dxt1; generation = .dxv1
        default: variant = .dxt5; generation = .dxv1
        }
        return DXVMovieIndex(width: Int(info.width), height: Int(info.height), variant: variant,
                             generation: generation, frames: frames,
                             duration: Double(info.duration) / timescale)
    }
}

enum DXVKitBridgeError: Error, CustomStringConvertible {
    case dxvkit(code: Int32, message: String)
    var description: String {
        switch self { case .dxvkit(let c, let m): return "DXVKit error \(c): \(m)" }
    }
}

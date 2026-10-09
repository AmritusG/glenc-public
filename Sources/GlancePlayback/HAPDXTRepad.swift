// SPDX-License-Identifier: MIT
import Foundation

/// Pure re-pad core shared by `HAPDXTPlayer` (and exercised directly by
/// the `tools/hap-gpu-smoke` correctness harness). Transforms a HAP DXT
/// block payload — laid out at HAP's **4-pixel** block-row alignment —
/// into the **16-pixel-aligned** row stride that
/// `DXVRenderer.uploadCompressed` expects, so HAP DXT blocks can be fed
/// into the existing (unmodified) DXVRenderer DXT path.
///
/// This is the only width-sensitive new logic in the GPU HAP byte path
/// — the v0.4.15 / v0.5.0 stride-bug class — so it is factored out as a
/// pure, allocation-free function over its inputs and tested in
/// isolation. The renderer crops the zero-filled pad columns back off at
/// draw time via its per-frame UV scale, so they are never visible.
///
/// Block-row math (DXT1 = 8 bytes/block, DXT5 = 16 bytes/block):
/// ```
///   srcBlocksW = (width  + 3)  / 4        // HAP 4-px block alignment
///   dstBlocksW = ((width + 15)/16*16) / 4 // DXVRenderer paddedWidth/4
///   blocksH    = (height + 3)  / 4
/// ```
/// When `srcBlocksW == dstBlocksW` (width already a multiple of 16) the
/// HAP and renderer layouts are byte-identical → `passthrough`.
public enum HAPDXTRepad {

    public struct Layout: Equatable {
        /// True when width is 16-aligned: no re-pad needed, the HAP
        /// payload already matches the renderer's layout byte-for-byte.
        public let passthrough: Bool
        public let srcRowBytes: Int
        public let dstRowBytes: Int
        public let blocksH: Int
        /// Bytes the re-padded (renderer-layout) buffer must hold.
        public let dstByteCount: Int
        /// Bytes the source HAP payload is expected to hold.
        public let srcByteCount: Int
    }

    /// Compute the re-pad layout for a frame of `width × height` whose
    /// DXT blocks are `blockBytes` each (8 = DXT1, 16 = DXT5).
    public static func layout(width: Int, height: Int, blockBytes: Int) -> Layout {
        let srcBlocksW = (width + 3) / 4
        let dstBlocksW = ((width + 15) / 16 * 16) / 4
        let blocksH = (height + 3) / 4
        let srcRowBytes = srcBlocksW * blockBytes
        let dstRowBytes = dstBlocksW * blockBytes
        return Layout(
            passthrough: srcBlocksW == dstBlocksW,
            srcRowBytes: srcRowBytes,
            dstRowBytes: dstRowBytes,
            blocksH: blocksH,
            dstByteCount: dstRowBytes * blocksH,
            srcByteCount: srcRowBytes * blocksH)
    }

    /// Copy each block row from `payload` into `dst` at the wider
    /// (16-aligned) destination stride. The pad bytes past `srcRowBytes`
    /// in each row are left untouched — the caller MUST supply a
    /// zero-initialised `dst` of at least `layout.dstByteCount` bytes so
    /// those pad blocks read as zero.
    public static func fill(into dst: UnsafeMutableRawBufferPointer,
                            payload: Data, layout: Layout) {
        precondition(dst.count >= layout.dstByteCount,
                     "HAPDXTRepad.fill: dst \(dst.count) < required \(layout.dstByteCount)")
        guard let dbase = dst.baseAddress else { return }
        payload.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            guard let sbase = src.baseAddress else { return }
            for row in 0..<layout.blocksH {
                memcpy(dbase + row * layout.dstRowBytes,
                       sbase + row * layout.srcRowBytes,
                       layout.srcRowBytes)
            }
        }
    }

    /// Convenience allocating variant for tests / non-hot paths: returns
    /// a fresh re-padded `Data` (or the payload unchanged when
    /// `passthrough`). The player itself uses `layout` + `fill` into a
    /// pooled buffer to avoid per-frame allocation.
    public static func repad(payload: Data, width: Int, height: Int,
                             blockBytes: Int) -> Data {
        let lay = layout(width: width, height: height, blockBytes: blockBytes)
        if lay.passthrough { return payload }
        var out = [UInt8](repeating: 0, count: lay.dstByteCount)
        out.withUnsafeMutableBytes { fill(into: $0, payload: payload, layout: lay) }
        return Data(out)
    }
}

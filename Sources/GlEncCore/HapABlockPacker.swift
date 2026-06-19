// SPDX-License-Identifier: MIT
/*
 * HapABlockPacker — v0.9.2 Phase B.
 *
 * Per-frame packer for HapA (HAP Alpha-only, RGTC1/BC4 single-channel).
 * Shape mirrors `HapYBlockPacker` exactly so `HapMEncoder` (v0.9.3)
 * can compose `HapYBlockPacker.packBlocks` + `HapABlockPacker.packBlocks`
 * without a refactor — HapM is just an outer-section wrap of one of
 * each.
 *
 * Public API:
 *
 *     let packer = HapABlockPacker()
 *     packer.prepare(width: w, height: h)
 *     let blocks = try packer.packBlocks(frame: frame)
 *     // blocks: (codedW/4) × (codedH/4) × 8 bytes of BC4 alpha
 *
 * The packer is policy-neutral: it produces BC4 blocks from any
 * source `PixelFrame`, including frames whose `alphaInfo` indicates
 * no usable alpha (the helper's `.forceOpaque` mode writes α=255
 * pixel-wide, BC4 collapses to a single endpoint = 255 per tile).
 * The "HapA requires source with alpha" reject policy (Phase A Q2)
 * lives in `HapAEncoder` (Phase C), which preflights via
 * `AlphaNormalization.mode(for:).sourceHasAlpha` before invoking
 * this packer. Keeping the policy out of the building block lets
 * HapM (v0.9.3) reuse the same packer with different opaque-source
 * semantics (HapM may emit an opaque alpha matte rather than reject).
 *
 * Coded-dimension alignment: 4-pixel multiples per the HAP spec
 * (Q3 decision). This packer is born correct; Hap1/Hap5/HapY
 * (v0.9.1 16-pixel alignment) are tightened to match in Phase C.5.
 *
 * Per-frame pipeline:
 *
 *     PixelFrame (BGRA8)
 *         │
 *         ▼  alpha-plane extract + AlphaNormalization.apply
 *     [single-channel alpha plane — codedW × codedH bytes, row-major,
 *      zero-padded outside presentation region]
 *         │
 *         ▼  BC4PlaneEncoder.encodePlane(...)
 *     [BC4 block stream — (codedW/4) × (codedH/4) × 8 bytes]
 *         │
 *         └→ returned to caller
 */

import Foundation

public final class HapABlockPacker {

    public enum HapAError: Error, CustomStringConvertible {
        case notPrepared
        case unexpectedFrameDimensions(expectedW: Int, expectedH: Int, gotW: Int, gotH: Int)
        case bgraSizeMismatch(expected: Int, got: Int)
        case unsupportedAlphaInfo(reason: String)
        public var description: String {
            switch self {
            case .notPrepared:
                return "HapABlockPacker: packBlocks() called before prepare()"
            case .unexpectedFrameDimensions(let ew, let eh, let gw, let gh):
                return "HapABlockPacker: prepared for \(ew)×\(eh) but got frame \(gw)×\(gh)"
            case .bgraSizeMismatch(let e, let g):
                return "HapABlockPacker: BGRA size \(g) ≠ expected \(e)"
            case .unsupportedAlphaInfo(let reason):
                return "HapABlockPacker: \(reason)"
            }
        }
    }

    private var presentationWidth: Int = 0
    private var presentationHeight: Int = 0
    /// Coded dimensions — 4-pixel multiples (HAP-native alignment).
    /// Distinct from v0.9.1's HapY/Hap1/Hap5 packers which use 16-pixel
    /// alignment; Phase C.5 tightens them to match this convention.
    private var codedWidth: Int = 0
    private var codedHeight: Int = 0
    private var prepared: Bool = false

    /// Single-channel alpha plane at coded dims, row-major.
    /// Pre-zeroed in prepare(); per-pixel overwrite in packBlocks
    /// covers the active region. Padding rows/cols stay at 0
    /// (= fully transparent matte tail, BC4-encodes trivially).
    private var alphaPlane: [UInt8] = []
    /// BC4 block stream: 8 bytes per 4×4 tile.
    private var bc4Buffer: [UInt8] = []

    public init() {}

    public func prepare(width: Int, height: Int) {
        precondition(width > 0 && height > 0)
        self.presentationWidth = width
        self.presentationHeight = height
        // 4-pixel block-boundary alignment per Q3 decision.
        self.codedWidth = (width + 3) & ~3
        self.codedHeight = (height + 3) & ~3
        self.alphaPlane = [UInt8](repeating: 0,
                                  count: codedWidth * codedHeight)
        let blocks = (codedWidth / 4) * (codedHeight / 4)
        self.bc4Buffer = [UInt8](repeating: 0, count: blocks * 8)
        self.prepared = true
    }

    /// Pack `frame`'s alpha channel into BC4 blocks. Returns the raw
    /// block stream (no Snappy, no section header). Caller wraps as
    /// needed; HapAEncoder (Phase C) does Snappy + HAP section header
    /// + VariantMOVWriter append.
    public func packBlocks(frame: PixelFrame) throws -> Data {
        guard prepared else { throw HapAError.notPrepared }
        guard frame.width == presentationWidth && frame.height == presentationHeight else {
            throw HapAError.unexpectedFrameDimensions(
                expectedW: presentationWidth, expectedH: presentationHeight,
                gotW: frame.width, gotH: frame.height)
        }
        let bgra = frame.bgraBytes()
        let expectedBGRA = presentationWidth * presentationHeight * 4
        guard bgra.count == expectedBGRA else {
            throw HapAError.bgraSizeMismatch(expected: expectedBGRA, got: bgra.count)
        }
        // Resolve normalization from source alphaInfo. `.alphaOnly`
        // throws — surfaced as our error type so callers see a
        // HapA-vocabulary message.
        let normalization: AlphaNormalization
        do {
            normalization = try AlphaNormalization.mode(for: frame.alphaInfo)
        } catch AlphaNormalization.Error.unsupportedAlphaInfo(let info) {
            throw HapAError.unsupportedAlphaInfo(
                reason: "alphaOnly source frames are not supported (got \(info.rawValue))")
        }

        // Step 1: extract + normalize the alpha plane into codedW × codedH.
        extractAlphaPlane(bgra: bgra, normalization: normalization)
        // Step 2: BC4-encode the plane. Output written into bc4Buffer.
        encodeAlphaPlane()
        return Data(bc4Buffer)
    }

    // MARK: - Extract + normalize alpha plane

    /// Copy alpha bytes from BGRA into the alpha plane at coded
    /// dimensions, applying source-alpha normalization per pixel.
    /// Padding rows/cols stay at 0 from prepare()'s zero-fill.
    private func extractAlphaPlane(bgra: Data, normalization: AlphaNormalization) {
        let pw = presentationWidth
        let ph = presentationHeight
        let cw = codedWidth
        let srcStride = pw * 4

        bgra.withUnsafeBytes { bgraRaw in
            let src = bgraRaw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            alphaPlane.withUnsafeMutableBufferPointer { planeBuf in
                let dst = planeBuf.baseAddress!
                for y in 0..<ph {
                    let srcRow = src.advanced(by: y * srcStride)
                    let dstRow = dst.advanced(by: y * cw)
                    for x in 0..<pw {
                        let s = srcRow.advanced(by: x * 4)
                        // BGRA byte order on source. We only need the
                        // output α; the helper normalizes all four
                        // channels but we discard R/G/B.
                        let (_, _, _, oa) = normalization.apply(
                            r: s[2], g: s[1], b: s[0], a: s[3])
                        dstRow[x] = oa
                    }
                }
            }
        }
    }

    // MARK: - BC4 plane encode

    /// BC4-encode the alpha plane into bc4Buffer. Calls
    /// `BC4PlaneEncoder.encodePlane` and copies the result into our
    /// owned buffer (BC4PlaneEncoder returns a fresh `[UInt8]`; the
    /// copy keeps `packBlocks`'s `Data(bc4Buffer)` cheap).
    private func encodeAlphaPlane() {
        let blocks = BC4PlaneEncoder.encodePlane(
            plane: alphaPlane,
            planeWidth: codedWidth,
            planeHeight: codedHeight)
        // Defensive — encodePlane returns exactly this many bytes,
        // but assert in case of an upstream refactor.
        precondition(blocks.count == bc4Buffer.count,
                     "HapABlockPacker: BC4 plane output size mismatch")
        bc4Buffer.withUnsafeMutableBufferPointer { dst in
            blocks.withUnsafeBufferPointer { src in
                dst.baseAddress!.update(from: src.baseAddress!,
                                        count: blocks.count)
            }
        }
    }
}

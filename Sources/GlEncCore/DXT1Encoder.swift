// SPDX-License-Identifier: MIT
/*
 * BC1 block encoder for one frame (the DXT1 texture): 4×4 RGBA tiles →
 * 8-byte BC1 blocks via BC1BlockEncoder, over the coded (aligned, zero-
 * padded) size. Used by the HAP encoders (Hap1, and HapFrameEncoder's
 * hap1 arm) with 4-pixel alignment.
 *
 * v1.4.0: DXV3 DXT1 packets are written by DXVKit (DXVKitFrameEncoder);
 * the DXV packet path that lived here (LZ pass via the LGPL DXVLZWriter +
 * 12-byte DXV3 header) is gone.
 *
 * BGRA→RGBA swizzle: PixelFrame carries BGRA bytes (CoreVideo's 32BGRA);
 * the BC1 encoder reads R, G, B, so the swizzle happens in the pad/copy.
 */

import Foundation

public final class DXT1Encoder {

    public enum DXT1Error: Error, CustomStringConvertible {
        case notPrepared
        case unexpectedFrameDimensions(expectedW: Int, expectedH: Int, gotW: Int, gotH: Int)
        case bgraSizeMismatch(expected: Int, got: Int)
        public var description: String {
            switch self {
            case .notPrepared:
                return "DXT1Encoder: encode() called before prepare()"
            case .unexpectedFrameDimensions(let ew, let eh, let gw, let gh):
                return "DXT1Encoder: prepared for \(ew)×\(eh) but got frame \(gw)×\(gh)"
            case .bgraSizeMismatch(let e, let g):
                return "DXT1Encoder: BGRA size \(g) ≠ expected \(e)"
            }
        }
    }

    // Configured by prepare()
    private var presentationWidth: Int = 0
    private var presentationHeight: Int = 0
    private var codedWidth: Int = 0
    private var codedHeight: Int = 0
    private var prepared: Bool = false

    // Reused buffers
    /// Padded RGBA buffer at coded dimensions, zero-filled. We only overwrite
    /// the active (presentation) region per frame; padding stays zero from
    /// initial fill.
    private var rgbaBuffer: [UInt8] = []
    /// BC1 block buffer (8 bytes per 4×4 tile). Size = blocks * 8.
    private var bc1Buffer: [UInt8] = []

    public init() {}

    /// Test-only access to the packed BC1 block buffer (post-encode-frame).
    /// Reachable from the test target via `@testable import GlEncCore` and
    /// used by the byte-divergence diagnostic. NOT a supported public API.
    internal var debugBC1Buffer: [UInt8] { bc1Buffer }
    internal var debugCodedDimensions: (Int, Int) { (codedWidth, codedHeight) }


    /// v0.9.2 Phase C.5 — parameterized prepare (the only one since v1.4.0).
    /// HAP callers (Hap1Encoder, HapFrameEncoder.prepare for .hap1)
    /// pass `codedAlignment: 4` — the HAP-native 4-pixel block-boundary
    /// alignment. The encoder's underlying buffers + block walker are
    /// alignment-agnostic; only the (w + a-1) & ~(a-1) rounding changes.
    /// `codedAlignment` must be a power of two ≥ 4 (BC1's tile size).
    public func prepare(width: Int, height: Int, fps: Double, hasAlpha: Bool,
                        codedAlignment: Int) throws {
        precondition(width > 0 && height > 0)
        precondition(codedAlignment >= 4 && (codedAlignment & (codedAlignment - 1)) == 0,
                     "codedAlignment must be a power of two ≥ 4")
        presentationWidth = width
        presentationHeight = height
        let mask = codedAlignment - 1
        codedWidth = (width + mask) & ~mask
        codedHeight = (height + mask) & ~mask
        let blocks = (codedWidth / 4) * (codedHeight / 4)
        rgbaBuffer = [UInt8](repeating: 0, count: codedWidth * codedHeight * 4)
        bc1Buffer = [UInt8](repeating: 0, count: blocks * 8)
        prepared = true
    }



    /// v0.9.1 Phase D — encode `frame` to raw BC1 block bytes. The HAP
    /// encoders use this; the BC1 stream is the post-padding raster of
    /// 8-byte blocks at `codedWidth × codedHeight` (presentation dims
    /// rounded up to the prepared alignment).
    ///
    /// Returns a copy of the internal `bc1Buffer` (reused per frame).
    @discardableResult
    public func encodeBlocks(frame: PixelFrame) throws -> Data {
        guard prepared else { throw DXT1Error.notPrepared }
        guard frame.width == presentationWidth && frame.height == presentationHeight else {
            throw DXT1Error.unexpectedFrameDimensions(
                expectedW: presentationWidth, expectedH: presentationHeight,
                gotW: frame.width, gotH: frame.height)
        }
        let bgra = frame.bgraBytes()
        let expectedBGRA = presentationWidth * presentationHeight * 4
        guard bgra.count == expectedBGRA else {
            throw DXT1Error.bgraSizeMismatch(expected: expectedBGRA, got: bgra.count)
        }
        // Step 1: BGRA → RGBA into the active region of the padded buffer.
        copyBGRAToPaddedRGBA(bgra)
        // Step 2: walk 4×4 tiles; encode each via BC1.
        encodeAllBlocks()
        return Data(bc1Buffer)
    }

    // MARK: - Helpers

    /// Copy BGRA presentation bytes into the top-left of the RGBA padded
    /// buffer, swapping channels 0 and 2. Padding columns and rows are NOT
    /// touched here — they were zero-filled in `prepare()` and never written.
    private func copyBGRAToPaddedRGBA(_ bgra: Data) {
        let pw = presentationWidth
        let ph = presentationHeight
        let cw = codedWidth
        let srcStride = pw * 4
        let dstStride = cw * 4

        bgra.withUnsafeBytes { bgraRaw in
            let src = bgraRaw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            rgbaBuffer.withUnsafeMutableBufferPointer { rgbaBuf in
                let dst = rgbaBuf.baseAddress!
                for y in 0..<ph {
                    let srcRow = src.advanced(by: y * srcStride)
                    let dstRow = dst.advanced(by: y * dstStride)
                    for x in 0..<pw {
                        let s = srcRow.advanced(by: x * 4)
                        let d = dstRow.advanced(by: x * 4)
                        d[0] = s[2]  // R ← BGRA byte 2
                        d[1] = s[1]  // G ← BGRA byte 1
                        d[2] = s[0]  // B ← BGRA byte 0
                        d[3] = s[3]  // A ← BGRA byte 3 (BC1 ignores it)
                    }
                }
            }
        }
    }

    /// Walk the 4×4 tiles and encode each one to bc1Buffer. Tile order:
    /// row-major over block coordinates, matching texturedsp_template.c's
    /// `exec_func`: y outer, x inner, both starting at 0.
    private func encodeAllBlocks() {
        let cw = codedWidth
        let ch = codedHeight
        let stride = cw * 4
        let wBlocks = cw / 4
        let hBlocks = ch / 4

        rgbaBuffer.withUnsafeBufferPointer { rgbaBuf in
            let rgba = rgbaBuf.baseAddress!
            bc1Buffer.withUnsafeMutableBufferPointer { bc1Buf in
                let bc1 = bc1Buf.baseAddress!
                for y in 0..<hBlocks {
                    let blockRowOffset = y * wBlocks
                    let pixelRow = rgba.advanced(by: y * 4 * stride)
                    for x in 0..<wBlocks {
                        let block = pixelRow.advanced(by: x * 16) // 4 pixels × 4 bytes
                        let dst = bc1.advanced(by: (blockRowOffset + x) * 8)
                        encodeBC1Block(block: block, stride: stride, dst: dst)
                    }
                }
            }
        }
    }
}

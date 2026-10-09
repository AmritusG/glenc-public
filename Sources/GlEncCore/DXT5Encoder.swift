// SPDX-License-Identifier: MIT
/*
 * BC3 block encoder for one frame (the DXT5 texture): 4×4 RGBA tiles →
 * 16-byte BC3 blocks (8-byte BC4 alpha + 8-byte BC1 colour) via
 * BC3BlockEncoder, over the coded (aligned, zero-padded) size. Used by
 * the HAP encoders (Hap5, and HapFrameEncoder's hap5 arm) with 4-pixel
 * alignment.
 *
 * v1.4.0: DXV3 DXT5 packets are written by DXVKit (DXVKitFrameEncoder);
 * the DXV packet path that lived here (LZ pass via the LGPL DXVLZWriter +
 * 12-byte DXV3 header) is gone.
 *
 * Source-alpha normalization (DECISIONS-2026-05-10-PassB.md, shared
 * AlphaNormalization): BC1 stores STRAIGHT RGB, BC4 STRAIGHT alpha —
 * premultiplied sources are un-premultiplied, straight ones pass, sources
 * without alpha get α = 255; alphaOnly fails.
 *
 * BGRA→RGBA swizzle happens during the pad/copy.
 */

import Foundation
import CoreGraphics

public final class DXT5Encoder {

    public enum DXT5Error: Error, CustomStringConvertible {
        case notPrepared
        case unexpectedFrameDimensions(expectedW: Int, expectedH: Int, gotW: Int, gotH: Int)
        case bgraSizeMismatch(expected: Int, got: Int)
        case unsupportedAlphaInfo(CGImageAlphaInfo)
        public var description: String {
            switch self {
            case .notPrepared:
                return "DXT5Encoder: encode() called before prepare()"
            case .unexpectedFrameDimensions(let ew, let eh, let gw, let gh):
                return "DXT5Encoder: prepared for \(ew)×\(eh) but got frame \(gw)×\(gh)"
            case .bgraSizeMismatch(let e, let g):
                return "DXT5Encoder: BGRA size \(g) ≠ expected \(e)"
            case .unsupportedAlphaInfo(let info):
                return "DXT5Encoder: alphaOnly source frames are not supported (got \(info.rawValue))"
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
    /// Padded RGBA buffer at coded dimensions, zero-filled. Active region
    /// (presentation) is overwritten per frame; padding stays zero.
    private var rgbaBuffer: [UInt8] = []
    /// BC3 block buffer (16 bytes per 4×4 tile).
    private var bc3Buffer: [UInt8] = []

    public init() {}

    /// Test-only access to the packed BC3 block buffer (post-encode-frame).
    internal var debugBC3Buffer: [UInt8] { bc3Buffer }
    internal var debugCodedDimensions: (Int, Int) { (codedWidth, codedHeight) }


    /// v0.9.2 Phase C.5 — parameterized prepare (the only one since v1.4.0).
    /// HAP callers (Hap5Encoder, HapFrameEncoder.prepare for .hap5)
    /// pass `codedAlignment: 4` — the HAP-native 4-pixel block-boundary
    /// alignment. `codedAlignment` must be a power of two ≥ 4
    /// (BC3's tile size).
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
        bc3Buffer = [UInt8](repeating: 0, count: blocks * 16)
        prepared = true
    }


    /// v0.9.1 Phase E — encode `frame` to raw BC3 (DXT5) block bytes.
    /// The HAP encoders use this; the BC3 stream is the post-padding
    /// raster of 16-byte blocks at `codedWidth × codedHeight`
    /// (presentation dims rounded up to the prepared alignment).
    ///
    /// Mirrors `DXT1Encoder.encodeBlocks`. Returns a copy of the
    /// internal `bc3Buffer` (reused per frame).
    @discardableResult
    public func encodeBlocks(frame: PixelFrame) throws -> Data {
        guard prepared else { throw DXT5Error.notPrepared }
        guard frame.width == presentationWidth && frame.height == presentationHeight else {
            throw DXT5Error.unexpectedFrameDimensions(
                expectedW: presentationWidth, expectedH: presentationHeight,
                gotW: frame.width, gotH: frame.height)
        }
        let bgra = frame.bgraBytes()
        let expectedBGRA = presentationWidth * presentationHeight * 4
        guard bgra.count == expectedBGRA else {
            throw DXT5Error.bgraSizeMismatch(expected: expectedBGRA, got: bgra.count)
        }
        let normalization = try alphaNormalization(for: frame.alphaInfo)
        // Step 1: BGRA → straight RGBA into the active region.
        copyBGRAToPaddedRGBA(bgra, normalization: normalization)
        // Step 2: walk 4×4 tiles → BC3 blocks.
        encodeAllBlocks()
        return Data(bc3Buffer)
    }


    // MARK: - Helpers

    /// v0.9.2 Phase B: delegates to the shared `AlphaNormalization`
    /// helper, then maps the helper's error into the DXT5Error
    /// vocabulary to preserve DXT5Encoder's existing error contract.
    private func alphaNormalization(for info: CGImageAlphaInfo) throws -> AlphaNormalization {
        do {
            return try AlphaNormalization.mode(for: info)
        } catch AlphaNormalization.Error.unsupportedAlphaInfo(let info) {
            throw DXT5Error.unsupportedAlphaInfo(info)
        } catch {
            throw error
        }
    }

    private func copyBGRAToPaddedRGBA(_ bgra: Data, normalization: AlphaNormalization) {
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
                        // BGRA byte order on source; AlphaNormalization
                        // takes (R, G, B, A) and returns the same.
                        let (or, og, ob, oa) = normalization.apply(
                            r: s[2], g: s[1], b: s[0], a: s[3])
                        d[0] = or
                        d[1] = og
                        d[2] = ob
                        d[3] = oa
                    }
                }
            }
        }
    }

    private func encodeAllBlocks() {
        let cw = codedWidth
        let ch = codedHeight
        let stride = cw * 4
        let wBlocks = cw / 4
        let hBlocks = ch / 4

        rgbaBuffer.withUnsafeBufferPointer { rgbaBuf in
            let rgba = rgbaBuf.baseAddress!
            bc3Buffer.withUnsafeMutableBufferPointer { bc3Buf in
                let bc3 = bc3Buf.baseAddress!
                for y in 0..<hBlocks {
                    let blockRowOffset = y * wBlocks
                    let pixelRow = rgba.advanced(by: y * 4 * stride)
                    for x in 0..<wBlocks {
                        let block = pixelRow.advanced(by: x * 16)
                        let dst = bc3.advanced(by: (blockRowOffset + x) * 16)
                        encodeBC3Block(block: block, stride: stride, dst: dst)
                    }
                }
            }
        }
    }
}

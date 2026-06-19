// SPDX-License-Identifier: MIT
/*
 * DXT5 (DXV3 Normal-quality + alpha) frame encoder.
 *
 * Top-level FrameEncoder for the DXT5 path. Composes:
 *   - BC3BlockEncoder: 4×4 RGBA tile → 16-byte BC3 block
 *     (8-byte BC4 alpha + 8-byte BC1 color).
 *   - DXVLZWriter.compressDXT5: BC3 block stream → LZ-compressed payload.
 *
 * Per Pass A + Pass B, the per-frame DXV3 packet is:
 *
 *     [tag 4 LE = 35 54 58 44]   // "DXT5" little-endian
 *     [version_major+1 = 0x04]
 *     [version_minor   = 0x00]
 *     [raw_flag        = 0x00]   // always compressed in Phase 3A
 *     [unknown         = 0x00]
 *     [size 4 LE       = LZ payload byte count]
 *     [LZ payload bytes...]
 *
 * Source-alpha normalization (DECISIONS-2026-05-10-PassB.md). BC1 stores
 * STRAIGHT RGB; BC4 stores STRAIGHT alpha. Source CGImageAlphaInfo is
 * inspected once per frame to decide which transform to apply when
 * copying BGRA → padded RGBA:
 *
 *   .premultipliedFirst / .premultipliedLast
 *       Un-premultiply: R' = round(R * 255 / α) when α > 0; α=0 → RGB=0.
 *       Same for G, B.
 *   .first / .last
 *       Straight RGB and straight alpha as-is.
 *   .noneSkipFirst / .noneSkipLast / .none
 *       α = 255 throughout (overwrite the X channel).
 *   .alphaOnly
 *       Degenerate input — fail with a clear error.
 *
 * 16-pixel alignment (Resolume mandate, same as DXT1): pad coded
 * dimensions up to the next 16-multiple, zero-fill padding.
 *
 * BGRA→RGBA swizzle: PixelFrame carries 32BGRA bytes. BC1 / BC4 read
 * R, G, B, A in that order, so the swizzle happens during the pad/copy.
 */

import Foundation
import CoreGraphics

public final class DXT5Encoder: FrameEncoder {

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
    private let lzWriter = DXVLZWriter()

    public init() {}

    /// Test-only access to the packed BC3 block buffer (post-encode-frame).
    internal var debugBC3Buffer: [UInt8] { bc3Buffer }
    internal var debugCodedDimensions: (Int, Int) { (codedWidth, codedHeight) }

    /// FrameEncoder protocol conformance — DXV3 path. Defaults to
    /// 16-pixel coded alignment (Resolume DXV3 mandate). DXV3 byte-
    /// identity must hold; do not change this default.
    public func prepare(width: Int, height: Int, fps: Double, hasAlpha: Bool) throws {
        try prepare(width: width, height: height, fps: fps,
                    hasAlpha: hasAlpha, codedAlignment: 16)
    }

    /// v0.9.2 Phase C.5 — parameterized prepare. DXV3 callers use the
    /// protocol overload (codedAlignment=16, sacred for byte-identity).
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

    public func encode(frame: PixelFrame) throws -> Data {
        // Steps 1-2 produce the BC3 block stream into `bc3Buffer`.
        try encodeBlocks(frame: frame)

        // Step 3: LZ-compress the BC3 block stream.
        let payload: Data = bc3Buffer.withUnsafeBufferPointer { buf in
            return lzWriter.compressDXT5(tex: buf.baseAddress!, count: buf.count)
        }

        // Step 4: prepend the 12-byte DXV3 frame header.
        var packet = Data(capacity: 12 + payload.count)
        packet.append(contentsOf: DXVFormat.dxt5.frameTagBytes!)  // 4 bytes (DXV3 variant)
        packet.append(0x04)                                      // version_major + 1
        packet.append(0x00)                                      // version_minor
        packet.append(0x00)                                      // raw_flag (compressed)
        packet.append(0x00)                                      // unknown
        let size = UInt32(payload.count)
        packet.append(UInt8( size        & 0xFF))
        packet.append(UInt8((size >>  8) & 0xFF))
        packet.append(UInt8((size >> 16) & 0xFF))
        packet.append(UInt8((size >> 24) & 0xFF))
        packet.append(payload)
        return packet
    }

    /// v0.9.1 Phase E — encode `frame` to raw BC3 (DXT5) block bytes
    /// (no LZ pass, no DXV3 framing). Hap5 uses this entry point; the
    /// BC3 stream is the post-padding raster of 16-byte blocks at
    /// `codedWidth × codedHeight` (presentation dims rounded up to a
    /// 16-multiple). The DXV3 `encode(frame:)` path now calls this
    /// for steps 1-2 and then applies the LZ pass + 12-byte DXV3
    /// header for steps 3-4.
    ///
    /// Mirrors `DXT1Encoder.encodeBlocks` (Phase D). Returns a `Data`
    /// view backed by the internal `bc3Buffer`; the caller must copy
    /// if they need ownership beyond the next call to
    /// `encode(frame:)` or `encodeBlocks(frame:)` on this encoder.
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

    public func finish() throws {
        // Nothing to flush — every frame is self-contained.
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

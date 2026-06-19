// SPDX-License-Identifier: MIT
/*
 * YG10 (DXV3 HQ + alpha) frame encoder.
 *
 * Top-level FrameEncoder for the YG10 path. Composes:
 *   - Source-alpha normalization → PREMULTIPLIED RGB
 *     (DECISIONS-2026-05-11-PassD.md: matches AME, not Alley).
 *   - YCoCgTransform: premultiplied RGBA → Y (full-res) + Co/Cg (half-res).
 *   - Alpha plane extraction at FULL resolution (no chroma-style subsample).
 *   - BC4PlaneEncoder × 4 (Y, A, Co, Cg).
 *   - DXVHQCgoWriter.encodeCocg × 2 (Y+A pass, Co+Cg pass).
 *   - DXVHQOpcodeWriter for each of the 4 opcode streams.
 *
 * Packet layout per dxv.c:655-670 and reference/yg10/FINDINGS.md
 * "four-stream layout":
 *
 *     [12-byte DXV3 header: tag YG10 + 0x04 0x00 raw=0 unknown=0 + size LE32]
 *     ─── pass 1 (Y + A → tex_data, cocg state machine) ───
 *     [op_offset_YA  LE32]   = (BC4 Y+A size) + 12
 *     [op_size_Y     LE32]   = Y opcode count
 *     [op_size_A     LE32]   = A opcode count
 *     [BC4 Y+A interleaved   op_offset_YA - 12 bytes; Y[0]/A[0]/Y[1]/A[1]...]
 *     [Y opcode stream encoding]
 *     [A opcode stream encoding]
 *     ─── pass 2 (Co + Cg → ctex_data, cocg state machine) ───
 *     [op_offset_CC  LE32]   = (BC4 Co+Cg size) + 12
 *     [op_size_Co    LE32]
 *     [op_size_Cg    LE32]
 *     [BC4 Co+Cg interleaved op_offset_CC - 12 bytes; Co[0]/Cg[0]/Co[1]/Cg[1]...]
 *     [Co opcode stream encoding]
 *     [Cg opcode stream encoding]
 *
 * Y+A interleave per Pass D archaeology: channel 0 = Y, channel 1 = A
 * (matches op_data[0]=Y, op_data[3]=A in dxv.c). 1:1 per-block
 * alternation in the cocg state machine, identical mechanism to YCG6's
 * Co+Cg pass — DXVHQCgoWriter.encodeCocg is plane-pair-agnostic and
 * reused verbatim.
 *
 * Source-alpha normalization (DECISIONS-2026-05-11-PassD.md). The
 * color planes (Y, Co, Cg) encode PREMULTIPLIED RGB:
 *
 *   .premultipliedFirst / .premultipliedLast
 *       Pass-through — RGB already premultiplied.
 *   .first / .last
 *       Straight RGB → multiply each channel by α/255 (α=0 → RGB=0).
 *   .noneSkipFirst / .noneSkipLast / .none
 *       α = 255 throughout (overwrite the X channel; RGB pass-through).
 *   .alphaOnly
 *       Degenerate input — fail.
 *
 * The alpha plane itself stores α straight (BC4 single-channel,
 * α ∈ [0, 255] verbatim) — the premult/straight distinction applies
 * only to the color planes.
 *
 * 16-pixel coded alignment (Resolume mandate). Y/A pad rows fill with
 * 0; Co/Cg pad cells fill with 128 (signed-zero) per YCoCgTransform.
 */

import Foundation
import CoreGraphics

public final class YG10Encoder: FrameEncoder {

    public enum YG10Error: Error, CustomStringConvertible {
        case notPrepared
        case unexpectedFrameDimensions(expectedW: Int, expectedH: Int, gotW: Int, gotH: Int)
        case bgraSizeMismatch(expected: Int, got: Int)
        case unsupportedAlphaInfo(CGImageAlphaInfo)
        public var description: String {
            switch self {
            case .notPrepared:
                return "YG10Encoder: encode() called before prepare()"
            case .unexpectedFrameDimensions(let ew, let eh, let gw, let gh):
                return "YG10Encoder: prepared for \(ew)×\(eh) but got frame \(gw)×\(gh)"
            case .bgraSizeMismatch(let e, let g):
                return "YG10Encoder: BGRA size \(g) ≠ expected \(e)"
            case .unsupportedAlphaInfo(let info):
                return "YG10Encoder: alphaOnly source frames are not supported (got \(info.rawValue))"
            }
        }
    }

    /// How to derive the premultiplied RGB the BC4 color planes will see.
    /// Derived once per frame from `PixelFrame.alphaInfo`.
    private enum AlphaNormalization {
        case forceOpaque        // α := 255, RGB pass-through (no premult needed)
        case premultiplyInPlace // straight α → multiply R/G/B by α/255
        case passThroughPremult // already premultiplied
    }

    // prepare() outputs
    private var presentationWidth: Int = 0
    private var presentationHeight: Int = 0
    private var codedWidth: Int = 0
    private var codedHeight: Int = 0
    private var prepared: Bool = false

    // Reused buffers
    /// Tightly-packed RGBA at presentation dims with premultiplied RGB.
    /// YCoCgTransform handles its own pad cells; we just feed it the
    /// presentation-sized buffer.
    private var rgbaPresentation: [UInt8] = []
    /// Alpha plane at CODED dimensions, zero-filled. Active region
    /// (presentation rows × cols) is overwritten per frame; pad cells
    /// stay 0 (BC4 will quantize an all-zero block cheaply).
    private var alphaCoded: [UInt8] = []

    public init() {}

    public func prepare(width: Int, height: Int, fps: Double, hasAlpha: Bool) throws {
        precondition(width > 0 && height > 0)
        // hasAlpha is informational. EncodePipeline currently hardcodes
        // hasAlpha=false; tests pass true. YG10 always carries alpha
        // regardless — the parameter doesn't gate behavior.
        presentationWidth = width
        presentationHeight = height
        codedWidth = (width + 15) & ~15
        codedHeight = (height + 15) & ~15
        rgbaPresentation = [UInt8](repeating: 0, count: width * height * 4)
        alphaCoded = [UInt8](repeating: 0, count: codedWidth * codedHeight)
        prepared = true
    }

    public func encode(frame: PixelFrame) throws -> Data {
        guard prepared else { throw YG10Error.notPrepared }
        guard frame.width == presentationWidth && frame.height == presentationHeight else {
            throw YG10Error.unexpectedFrameDimensions(
                expectedW: presentationWidth, expectedH: presentationHeight,
                gotW: frame.width, gotH: frame.height)
        }

        let bgra = frame.bgraBytes()
        let expectedBGRA = presentationWidth * presentationHeight * 4
        guard bgra.count == expectedBGRA else {
            throw YG10Error.bgraSizeMismatch(expected: expectedBGRA, got: bgra.count)
        }

        let normalization = try alphaNormalization(for: frame.alphaInfo)

        // Step 1: BGRA → premultiplied RGBA into rgbaPresentation, and
        // copy α bytes into the active region of alphaCoded.
        copyBGRAToRGBAAndAlpha(bgra, normalization: normalization)

        // Step 2: YCoCg + chroma half-res → Y / Co / Cg planes at coded dims.
        let planes = rgbaPresentation.withUnsafeBufferPointer { buf -> YCoCgPlanes in
            return YCoCgTransform.ycocgFromRGBA(
                rgba: buf.baseAddress!,
                presentationWidth: presentationWidth,
                presentationHeight: presentationHeight,
                codedWidth: codedWidth,
                codedHeight: codedHeight
            )
        }

        let chromaW = codedWidth / 2
        let chromaH = codedHeight / 2

        // Step 3: BC4-encode each of the four planes.
        let bc4Y  = BC4PlaneEncoder.encodePlane(plane: planes.luma,
                                                planeWidth: codedWidth,
                                                planeHeight: codedHeight)
        let bc4A  = BC4PlaneEncoder.encodePlane(plane: alphaCoded,
                                                planeWidth: codedWidth,
                                                planeHeight: codedHeight)
        let bc4Co = BC4PlaneEncoder.encodePlane(plane: planes.co,
                                                planeWidth: chromaW,
                                                planeHeight: chromaH)
        let bc4Cg = BC4PlaneEncoder.encodePlane(plane: planes.cg,
                                                planeWidth: chromaW,
                                                planeHeight: chromaH)

        let lumaBlockCount = (codedWidth / 4) * (codedHeight / 4)
        let chromaBlockCount = (chromaW / 4) * (chromaH / 4)

        // Step 4: cocg pass 1 (Y + A) and pass 2 (Co + Cg).
        let yaOut = DXVHQCgoWriter.encodeCocg(
            ch0Blocks: bc4Y, ch1Blocks: bc4A,
            blockCountPerChannel: lumaBlockCount)
        let cocgOut = DXVHQCgoWriter.encodeCocg(
            ch0Blocks: bc4Co, ch1Blocks: bc4Cg,
            blockCountPerChannel: chromaBlockCount)

        // Step 5: encode the four opcode streams.
        let yEncoded  = DXVHQOpcodeWriter.encodeStream(opcodes: yaOut.opcodes0)
        let aEncoded  = DXVHQOpcodeWriter.encodeStream(opcodes: yaOut.opcodes1)
        let coEncoded = DXVHQOpcodeWriter.encodeStream(opcodes: cocgOut.opcodes0)
        let cgEncoded = DXVHQOpcodeWriter.encodeStream(opcodes: cocgOut.opcodes1)

        // Step 6: stitch the YG10 packet payload.
        let opOffsetYA = UInt32(yaOut.texData.count + 12)
        let opSizeY = UInt32(yaOut.opcodes0.count)
        let opSizeA = UInt32(yaOut.opcodes1.count)
        let opOffsetCC = UInt32(cocgOut.texData.count + 12)
        let opSizeCo = UInt32(cocgOut.opcodes0.count)
        let opSizeCg = UInt32(cocgOut.opcodes1.count)

        let payloadSize = 12 + yaOut.texData.count + yEncoded.count + aEncoded.count
                        + 12 + cocgOut.texData.count + coEncoded.count + cgEncoded.count
        var packet = Data(capacity: 12 + payloadSize)

        // 12-byte DXV3 header.
        packet.append(contentsOf: DXVFormat.yg10.frameTagBytes!)  // 4 bytes (DXV3 variant)
        packet.append(0x04)
        packet.append(0x00)
        packet.append(0x00)  // raw_flag (compressed)
        packet.append(0x00)  // unknown
        appendLE32(&packet, UInt32(payloadSize))

        // Pass 1 (Y + A) prelude + data + opcode streams.
        appendLE32(&packet, opOffsetYA)
        appendLE32(&packet, opSizeY)
        appendLE32(&packet, opSizeA)
        packet.append(contentsOf: yaOut.texData)
        packet.append(yEncoded)
        packet.append(aEncoded)

        // Pass 2 (Co + Cg) prelude + data + opcode streams.
        appendLE32(&packet, opOffsetCC)
        appendLE32(&packet, opSizeCo)
        appendLE32(&packet, opSizeCg)
        packet.append(contentsOf: cocgOut.texData)
        packet.append(coEncoded)
        packet.append(cgEncoded)

        return packet
    }

    public func finish() throws {
        // Every frame is self-contained; nothing to flush.
    }

    // MARK: - Helpers

    private func alphaNormalization(for info: CGImageAlphaInfo) throws -> AlphaNormalization {
        switch info {
        case .premultipliedFirst, .premultipliedLast:
            return .passThroughPremult
        case .first, .last:
            return .premultiplyInPlace
        case .noneSkipFirst, .noneSkipLast, .none:
            return .forceOpaque
        case .alphaOnly:
            throw YG10Error.unsupportedAlphaInfo(info)
        @unknown default:
            // Safest default: treat unknown as straight RGB and
            // premultiply. The HQ decoder will composite either way.
            return .premultiplyInPlace
        }
    }

    /// One pass over the source BGRA: swizzle to RGBA, apply alpha
    /// normalization to the RGB triple, copy α into both the RGBA
    /// alpha byte (for YCoCg's view, though it ignores α) AND into the
    /// alphaCoded plane (for BC4 alpha encoding). α plane padding
    /// cells stay 0 from prepare()'s zero-fill.
    private func copyBGRAToRGBAAndAlpha(_ bgra: Data, normalization: AlphaNormalization) {
        let pw = presentationWidth
        let ph = presentationHeight
        let cw = codedWidth
        let srcStride = pw * 4
        let presStride = pw * 4

        bgra.withUnsafeBytes { bgraRaw in
            let src = bgraRaw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            rgbaPresentation.withUnsafeMutableBufferPointer { rgbaBuf in
                let rgba = rgbaBuf.baseAddress!
                alphaCoded.withUnsafeMutableBufferPointer { alphaBuf in
                    let alpha = alphaBuf.baseAddress!
                    for y in 0..<ph {
                        let srcRow = src.advanced(by: y * srcStride)
                        let dstRow = rgba.advanced(by: y * presStride)
                        let alphaRow = alpha.advanced(by: y * cw)
                        for x in 0..<pw {
                            let s = srcRow.advanced(by: x * 4)
                            let d = dstRow.advanced(by: x * 4)
                            let b = s[0]
                            let g = s[1]
                            let r = s[2]
                            let a = s[3]
                            let aOut: UInt8
                            switch normalization {
                            case .forceOpaque:
                                d[0] = r
                                d[1] = g
                                d[2] = b
                                aOut = 255
                            case .passThroughPremult:
                                d[0] = r
                                d[1] = g
                                d[2] = b
                                aOut = a
                            case .premultiplyInPlace:
                                if a == 0 {
                                    d[0] = 0
                                    d[1] = 0
                                    d[2] = 0
                                } else if a == 255 {
                                    d[0] = r
                                    d[1] = g
                                    d[2] = b
                                } else {
                                    // R' = round(R * α / 255). Integer
                                    // arithmetic with +127 bias for
                                    // round-to-nearest.
                                    let aInt = Int(a)
                                    d[0] = UInt8((Int(r) * aInt + 127) / 255)
                                    d[1] = UInt8((Int(g) * aInt + 127) / 255)
                                    d[2] = UInt8((Int(b) * aInt + 127) / 255)
                                }
                                aOut = a
                            }
                            d[3] = aOut
                            alphaRow[x] = aOut
                        }
                    }
                }
            }
        }
    }

    @inline(__always)
    private func appendLE32(_ data: inout Data, _ v: UInt32) {
        data.append(UInt8( v        & 0xFF))
        data.append(UInt8((v >>  8) & 0xFF))
        data.append(UInt8((v >> 16) & 0xFF))
        data.append(UInt8((v >> 24) & 0xFF))
    }
}

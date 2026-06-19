// SPDX-License-Identifier: MIT
/*
 * YCG6 (DXV3 HQ, no alpha) frame encoder.
 *
 * Top-level FrameEncoder for the YCG6 path. Composes:
 *   - YCoCgTransform: BGRA → Y (full-res) + Co/Cg (half-res) planes,
 *     non-reversible YCoCg, integer arithmetic, Co/Cg stored with
 *     +128 offset so decoder reads straight UInt8 - 128.
 *   - BC4PlaneEncoder: each plane → 8-byte BC4 blocks.
 *   - DXVHQCgoWriter: yo (luma) + cocg (chroma) cgo state-machine
 *     encoding; ops 0/1/3 baseline.
 *   - DXVHQOpcodeWriter: raw or byte-fill opcode stream encoding.
 *
 * On-disk packet layout per dxv.c:982-1004 + Pass C:
 *
 *     [12-byte DXV3 header: tag YCG6 + 0x04 0x00 raw=0 unknown=0 + size LE32]
 *     ─── yo (Y plane) ───
 *     [op_offset_Y    LE32]
 *     [op_size_Y      LE32]
 *     [BC4-Y bytes    op_offset_Y - 8 bytes]
 *     [Y opcode stream encoding]
 *     ─── cocg (Co + Cg planes) ───
 *     [op_offset_C    LE32]
 *     [op_size_Co     LE32]
 *     [op_size_Cg     LE32]
 *     [BC4-Co+Cg bytes (interleaved)  op_offset_C - 12 bytes]
 *     [Co opcode stream encoding]
 *     [Cg opcode stream encoding]
 *
 * 16-pixel coded alignment is mandatory (Resolume mandate, same as
 * DXT1/DXT5). For 1920×1080 input: codedW=1920, codedH=1088. The
 * YCoCg transform fills luma's pad rows with zeros and chroma's pad
 * cells with 128 (= signed-zero Co/Cg).
 *
 * No source-alpha normalization — YCG6 carries no alpha channel. Any
 * source alpha is discarded during the BGRA→RGBA swizzle.
 */

import Foundation
import CoreGraphics

public final class YCG6Encoder: FrameEncoder {

    public enum YCG6Error: Error, CustomStringConvertible {
        case notPrepared
        case alphaRequested
        case unexpectedFrameDimensions(expectedW: Int, expectedH: Int, gotW: Int, gotH: Int)
        case bgraSizeMismatch(expected: Int, got: Int)
        public var description: String {
            switch self {
            case .notPrepared:
                return "YCG6Encoder: encode() called before prepare()"
            case .alphaRequested:
                return "YCG6Encoder: hasAlpha=true requested but YCG6 has no alpha plane (use YG10 for HQ+alpha)"
            case .unexpectedFrameDimensions(let ew, let eh, let gw, let gh):
                return "YCG6Encoder: prepared for \(ew)×\(eh) but got frame \(gw)×\(gh)"
            case .bgraSizeMismatch(let e, let g):
                return "YCG6Encoder: BGRA size \(g) ≠ expected \(e)"
            }
        }
    }

    // prepare() outputs
    private var presentationWidth: Int = 0
    private var presentationHeight: Int = 0
    private var codedWidth: Int = 0
    private var codedHeight: Int = 0
    private var prepared: Bool = false

    // Reused buffers (allocated in prepare, reused per frame).
    private var rgbaPresentation: [UInt8] = []

    public init() {}

    public func prepare(width: Int, height: Int, fps: Double, hasAlpha: Bool) throws {
        precondition(width > 0 && height > 0)
        if hasAlpha {
            throw YCG6Error.alphaRequested
        }
        presentationWidth = width
        presentationHeight = height
        codedWidth = (width + 15) & ~15
        codedHeight = (height + 15) & ~15
        rgbaPresentation = [UInt8](repeating: 0, count: width * height * 4)
        prepared = true
    }

    public func encode(frame: PixelFrame) throws -> Data {
        guard prepared else { throw YCG6Error.notPrepared }
        guard frame.width == presentationWidth && frame.height == presentationHeight else {
            throw YCG6Error.unexpectedFrameDimensions(
                expectedW: presentationWidth, expectedH: presentationHeight,
                gotW: frame.width, gotH: frame.height)
        }

        let bgra = frame.bgraBytes()
        let expectedBGRA = presentationWidth * presentationHeight * 4
        guard bgra.count == expectedBGRA else {
            throw YCG6Error.bgraSizeMismatch(expected: expectedBGRA, got: bgra.count)
        }

        // Step 1: BGRA → RGBA (presentation dims; YCoCgTransform handles
        // pad rows/cols itself via the +128 fill).
        copyBGRAToRGBA(bgra)

        // Step 2: YCoCg + half-res chroma subsample → 3 planes at coded dims.
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

        // Step 3: BC4-encode each plane.
        let bc4Y  = BC4PlaneEncoder.encodePlane(plane: planes.luma,
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

        // Step 4: cgo-encode the Y plane (yo path) and Co/Cg (cocg path).
        let yoOut = DXVHQCgoWriter.encodeYo(blocks: bc4Y, blockCount: lumaBlockCount)
        let cocgOut = DXVHQCgoWriter.encodeCocg(
            ch0Blocks: bc4Co, ch1Blocks: bc4Cg, blockCountPerChannel: chromaBlockCount
        )

        // Step 5: encode opcode streams.
        let yEncoded  = DXVHQOpcodeWriter.encodeStream(opcodes: yoOut.opcodes0)
        let coEncoded = DXVHQOpcodeWriter.encodeStream(opcodes: cocgOut.opcodes0)
        let cgEncoded = DXVHQOpcodeWriter.encodeStream(opcodes: cocgOut.opcodes1)

        // Step 6: stitch the YCG6 packet payload.
        // ── yo block ──
        // BC4-Y data section = yoOut.texData (op_offset_Y - 8 bytes)
        let opOffsetY = UInt32(yoOut.texData.count + 8)
        let opSizeY = UInt32(yoOut.opcodes0.count)
        // ── cocg block ──
        let opOffsetC = UInt32(cocgOut.texData.count + 12)
        let opSizeCo = UInt32(cocgOut.opcodes0.count)
        let opSizeCg = UInt32(cocgOut.opcodes1.count)

        // Payload size (excluding the 12-byte DXV3 header).
        let payloadSize = 8 + yoOut.texData.count + yEncoded.count
                        + 12 + cocgOut.texData.count + coEncoded.count + cgEncoded.count
        var packet = Data(capacity: 12 + payloadSize)

        // 12-byte DXV3 header.
        packet.append(contentsOf: DXVFormat.ycg6.frameTagBytes!)  // 4 bytes (DXV3 variant)
        packet.append(0x04)
        packet.append(0x00)
        packet.append(0x00)  // raw_flag (compressed)
        packet.append(0x00)  // unknown
        appendLE32(&packet, UInt32(payloadSize))

        // yo prelude + data + opcodes.
        appendLE32(&packet, opOffsetY)
        appendLE32(&packet, opSizeY)
        packet.append(contentsOf: yoOut.texData)
        packet.append(yEncoded)

        // cocg prelude + data + opcodes.
        appendLE32(&packet, opOffsetC)
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

    private func copyBGRAToRGBA(_ bgra: Data) {
        let pw = presentationWidth
        let ph = presentationHeight
        bgra.withUnsafeBytes { bgraRaw in
            let src = bgraRaw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            rgbaPresentation.withUnsafeMutableBufferPointer { dstBuf in
                let dst = dstBuf.baseAddress!
                for y in 0..<ph {
                    let rowOff = y * pw * 4
                    let s = src.advanced(by: rowOff)
                    let d = dst.advanced(by: rowOff)
                    for x in 0..<pw {
                        let sp = s.advanced(by: x * 4)
                        let dp = d.advanced(by: x * 4)
                        dp[0] = sp[2]   // R ← BGRA byte 2
                        dp[1] = sp[1]   // G
                        dp[2] = sp[0]   // B
                        dp[3] = 255     // YCG6 has no alpha; ignored by transform
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

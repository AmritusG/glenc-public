// SPDX-License-Identifier: MIT
/*
 * HapYBlockPacker — v0.9.1 Phase G.
 *
 * Per-frame packer for HapY (Scaled YCoCg DXT5). Extracted from the
 * Phase F `HapYEncoder` so both the standalone convenience encoder
 * (`HapYEncoder`) and the pipeline-driven `HapFrameEncoder` can share
 * the same block-packing implementation.
 *
 * Public API mirrors `DXT1Encoder.encodeBlocks` / `DXT5Encoder.
 * encodeBlocks`: prepare with coded dims, feed a frame, get raw
 * 16-byte BC3 blocks back. No DXV3 framing, no Snappy, no section
 * header — those are the caller's job.
 *
 * See `HapYEncoder.swift` for the format spec (Castaño & van Waveren
 * 2007 scaled YCoCg-DXT5) and per-block scale selection algorithm.
 * This file is the implementation detail; the docs there are the
 * canonical reference.
 */

import Foundation

public final class HapYBlockPacker {

    public enum HapYError: Error, CustomStringConvertible {
        case notPrepared
        case unexpectedFrameDimensions(expectedW: Int, expectedH: Int, gotW: Int, gotH: Int)
        case bgraSizeMismatch(expected: Int, got: Int)
        public var description: String {
            switch self {
            case .notPrepared:
                return "HapYBlockPacker: packBlocks() called before prepare()"
            case .unexpectedFrameDimensions(let ew, let eh, let gw, let gh):
                return "HapYBlockPacker: prepared for \(ew)×\(eh) but got frame \(gw)×\(gh)"
            case .bgraSizeMismatch(let e, let g):
                return "HapYBlockPacker: BGRA size \(g) ≠ expected \(e)"
            }
        }
    }

    private var presentationWidth: Int = 0
    private var presentationHeight: Int = 0
    private var codedWidth: Int = 0
    private var codedHeight: Int = 0
    private var prepared: Bool = false

    /// Intermediate RGBA at coded dims: (R=Co_scaled+128, G=Cg_scaled+128,
    /// B=scale_byte, A=Y). Zero-pad survives BC3 round-trip into
    /// transparent black via the HapY inverse formula.
    private var intermediateRGBA: [UInt8] = []
    /// BC3 block stream: 16 bytes per 4×4 tile.
    private var bc3Buffer: [UInt8] = []

    public init() {}

    public func prepare(width: Int, height: Int) {
        precondition(width > 0 && height > 0)
        self.presentationWidth = width
        self.presentationHeight = height
        // v0.9.2 Phase C.5: 4-pixel HAP-native alignment (was 16-pixel
        // inherited from DXV3 encoders in v0.9.1). HapYBlockPacker is
        // HAP-only — no DXV3 sharing — so the constant flips directly.
        // HapABlockPacker was born at 4-pixel in Phase B; all four
        // HAP variants now share the same convention.
        self.codedWidth = (width + 3) & ~3
        self.codedHeight = (height + 3) & ~3
        // Zero-fill so pad cells encode as (Co=0, Cg=0, scale=0, Y=0).
        self.intermediateRGBA = [UInt8](repeating: 0,
                                        count: codedWidth * codedHeight * 4)
        let blocks = (codedWidth / 4) * (codedHeight / 4)
        self.bc3Buffer = [UInt8](repeating: 0, count: blocks * 16)
        self.prepared = true
    }

    /// Pack `frame` into HapY-style BC3 blocks. Returns the raw block
    /// stream (no Snappy, no section header). Caller wraps as needed.
    public func packBlocks(frame: PixelFrame) throws -> Data {
        guard prepared else { throw HapYError.notPrepared }
        guard frame.width == presentationWidth && frame.height == presentationHeight else {
            throw HapYError.unexpectedFrameDimensions(
                expectedW: presentationWidth, expectedH: presentationHeight,
                gotW: frame.width, gotH: frame.height)
        }
        let bgra = frame.bgraBytes()
        let expectedBGRA = presentationWidth * presentationHeight * 4
        guard bgra.count == expectedBGRA else {
            throw HapYError.bgraSizeMismatch(expected: expectedBGRA, got: bgra.count)
        }
        packScaledYCoCg(bgra: bgra)
        encodeAllBlocks()
        return Data(bc3Buffer)
    }

    // MARK: - Pack: BGRA → ScaledYCoCg-RGBA per 4×4 block

    private func packScaledYCoCg(bgra: Data) {
        let pw = presentationWidth
        let ph = presentationHeight
        let cw = codedWidth
        let srcStride = pw * 4
        let dstStride = cw * 4

        bgra.withUnsafeBytes { bgraRaw in
            let src = bgraRaw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            intermediateRGBA.withUnsafeMutableBufferPointer { dstBuf in
                let dst = dstBuf.baseAddress!

                var yBuf = [UInt8](repeating: 0, count: 16)
                var coBuf = [Int](repeating: 0, count: 16)
                var cgBuf = [Int](repeating: 0, count: 16)

                var by = 0
                while by < ph {
                    var bx = 0
                    while bx < pw {
                        var maxAbs = 0
                        for ty in 0..<4 {
                            let sy = by + ty
                            for tx in 0..<4 {
                                let sx = bx + tx
                                let idx = ty * 4 + tx
                                if sy < ph && sx < pw {
                                    let sp = src.advanced(by: sy * srcStride + sx * 4)
                                    let b = Int(sp[0])
                                    let g = Int(sp[1])
                                    let r = Int(sp[2])
                                    let (yi, coi, cgi) = ycocgFromRGB(r: r, g: g, b: b)
                                    yBuf[idx] = yi
                                    coBuf[idx] = coi
                                    cgBuf[idx] = cgi
                                    let absMax = max(abs(coi), abs(cgi))
                                    if absMax > maxAbs { maxAbs = absMax }
                                } else {
                                    yBuf[idx] = 0
                                    coBuf[idx] = 0
                                    cgBuf[idx] = 0
                                }
                            }
                        }

                        let scaleFactor: Int
                        let scaleByte: UInt8
                        if maxAbs <= 31 {
                            scaleFactor = 4
                            scaleByte = 24
                        } else if maxAbs <= 63 {
                            scaleFactor = 2
                            scaleByte = 8
                        } else {
                            scaleFactor = 1
                            scaleByte = 0
                        }

                        for ty in 0..<4 {
                            let dy = by + ty
                            if dy >= codedHeight { continue }
                            for tx in 0..<4 {
                                let dx = bx + tx
                                if dx >= codedWidth { continue }
                                let idx = ty * 4 + tx
                                let dp = dst.advanced(by: dy * dstStride + dx * 4)
                                let rRaw = coBuf[idx] * scaleFactor + 128
                                let gRaw = cgBuf[idx] * scaleFactor + 128
                                dp[0] = UInt8(clamping: rRaw)
                                dp[1] = UInt8(clamping: gRaw)
                                dp[2] = scaleByte
                                dp[3] = yBuf[idx]
                            }
                        }
                        bx += 4
                    }
                    by += 4
                }
            }
        }
    }

    @inline(__always)
    private func ycocgFromRGB(r: Int, g: Int, b: Int) -> (UInt8, Int, Int) {
        let y = (r + 2 * g + b + 2) >> 2
        let co = (r - b) >> 1
        let cg = (-r + 2 * g - b) >> 2
        return (UInt8(clamping: y), co, cg)
    }

    private func encodeAllBlocks() {
        let cw = codedWidth
        let ch = codedHeight
        let stride = cw * 4
        let wBlocks = cw / 4
        let hBlocks = ch / 4

        intermediateRGBA.withUnsafeBufferPointer { rgbaBuf in
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

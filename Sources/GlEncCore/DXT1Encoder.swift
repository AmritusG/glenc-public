// SPDX-License-Identifier: MIT
/*
 * DXT1 (DXV3 Normal-quality, no alpha) frame encoder.
 *
 * Top-level FrameEncoder for the DXT1 path. Composes:
 *   - BC1BlockEncoder: 4×4 RGBA tile → 8-byte BC1 block.
 *   - DXVLZWriter: BC1 block stream → LZ-compressed payload.
 *
 * Per Pass A (DECISIONS-2026-05-09-PassA.md), the per-frame DXV3 packet is:
 *
 *     [tag 4 LE = 31 54 58 44]
 *     [version_major+1 = 0x04]
 *     [version_minor   = 0x00]
 *     [raw_flag        = 0x00]   // always compressed in dxvenc.c — Phase 2A mirrors
 *     [unknown         = 0x00]
 *     [size 4 LE       = LZ payload byte count]
 *     [LZ payload bytes...]
 *
 * 16-pixel alignment: BC1 needs 4×4, but Resolume refuses to display frames
 * not padded to a 16-multiple. dxvenc.c pads coded_width/height up and
 * zero-fills the padding RGBA. We mirror that here.
 *
 * BGRA→RGBA swizzle: PixelFrame carries BGRA bytes (CoreVideo's 32BGRA).
 * texturedspenc.c's BC1 encoder reads `block[0]=R, block[1]=G, block[2]=B`,
 * so the swizzle is performed during the pad/copy step.
 */

import Foundation

public final class DXT1Encoder: FrameEncoder {

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
    private let lzWriter = DXVLZWriter()

    public init() {}

    /// Test-only access to the packed BC1 block buffer (post-encode-frame).
    /// Reachable from the test target via `@testable import GlEncCore` and
    /// used by the byte-divergence diagnostic. NOT a supported public API.
    internal var debugBC1Buffer: [UInt8] { bc1Buffer }
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

    public func encode(frame: PixelFrame) throws -> Data {
        // Steps 1-2 produce the BC1 block stream into `bc1Buffer`.
        try encodeBlocks(frame: frame)

        // Step 3: LZ-compress the BC1 block stream.
        let payload: Data = bc1Buffer.withUnsafeBufferPointer { buf in
            return lzWriter.compressDXT1(tex: buf.baseAddress!, count: buf.count)
        }

        // Step 4: prepend the 12-byte DXV3 frame header.
        var packet = Data(capacity: 12 + payload.count)
        packet.append(contentsOf: DXVFormat.dxt1.frameTagBytes!)  // 4 bytes (DXV3 variant)
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

    public func finish() throws {
        // Nothing to flush — every frame is self-contained.
    }

    /// v0.9.1 Phase D — encode `frame` to raw BC1 block bytes (no
    /// LZ pass, no DXV3 framing). HAP encoders use this entry point;
    /// the BC1 stream is the post-padding raster of 8-byte blocks at
    /// `codedWidth × codedHeight` (presentation dims rounded up to a
    /// 16-multiple). The DXV3 `encode(frame:)` path now calls this
    /// for steps 1-2 and then applies the LZ pass + 12-byte DXV3
    /// header for steps 3-4.
    ///
    /// Returns: `Data` view backed by the internal `bc1Buffer`. The
    /// caller must copy if they need ownership beyond the next call
    /// to `encode(frame:)` or `encodeBlocks(frame:)` on this encoder
    /// (the buffer is reused for the next frame).
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

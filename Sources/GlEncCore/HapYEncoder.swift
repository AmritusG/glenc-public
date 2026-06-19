// SPDX-License-Identifier: MIT
/*
 * HapYEncoder — v0.9.1 Phase F (refactored in Phase G).
 *
 * Convenience encoder that wraps a `HapYBlockPacker` (per-frame
 * scaled-YCoCg → BC3) + Snappy + HAP section header + a
 * `VariantMOVWriter`. Owns its own writer; suited to direct callers
 * and unit tests.
 *
 * The pipeline-driven path uses `HapFrameEncoder` (FrameEncoder-
 * conforming, codec-parameterized) and an externally-managed
 * VariantMOVWriter. Both code paths share `HapYBlockPacker`.
 *
 * Reference: Castaño & van Waveren, *Real-Time YCoCg-DXT Compression*,
 * 2007; Vidvox HAP spec at
 *   https://github.com/Vidvox/hap/blob/master/documentation/HapVideoDRAFT.md
 *
 * HapY packs one 4×4 RGB source tile into a 16-byte BC3 (DXT5) block
 * by reinterpreting the four channels:
 *
 *     Alpha (BC4 block, 8 B)  = Y         (full-res per-pixel luminance)
 *     Red   (BC1 byte 0..7)   = Co_scaled + 128
 *     Green (BC1 byte 0..7)   = Cg_scaled + 128
 *     Blue  (BC1 byte 0..7)   = scale_byte ∈ {0, 8, 24} (CONSTANT per block)
 *
 * Per-block scale selection: pick the largest factor s ∈ {4, 2, 1}
 * that keeps all 16 pixels' (Co·s, Cg·s) in [-128, 127]. The scale
 * byte survives BC1 round-trip losslessly because {0, 8, 24} map to
 * 5-bit blue endpoints {0, 1, 3} which expand back via
 * `(v << 3) | (v >> 2)` to exactly {0, 8, 24}.
 *
 * Section type 0xBF per Vidvox HAP spec (high nibble 0xB = Snappy,
 * low nibble 0xF = ScaledYCoCgDXT5).
 */

import Foundation
import CoreMedia

public final class HapYEncoder {

    /// HAP section type byte for Snappy-compressed Scaled-YCoCg DXT5.
    private static let sectionTypeHapYSnappy: UInt8 = 0xBF

    private let packer = HapYBlockPacker()
    private let writer: VariantMOVWriter

    public init(width: Int, height: Int, fps: Double, destURL: URL) throws {
        precondition(width > 0 && height > 0)
        packer.prepare(width: width, height: height)
        self.writer = try VariantMOVWriter(
            destURL: destURL,
            format: .hapY,
            presentationWidth: width,
            presentationHeight: height,
            fps: fps,
            // writerVersion: falls through to VariantMOVWriter's
            // "GlEnc" default. See Hap1Encoder for the v0.9.2 D.5
            // rationale.
            codecFourCC: "HapY")
    }

    public func append(frame: PixelFrame, presentationTime: CMTime) throws {
        let bc3 = try packer.packBlocks(frame: frame)
        let snappyPayload = SnappyCompressor.compress(bc3)
        let packet = try Self.makeHapYSnappySection(payload: snappyPayload)
        try writer.append(packet: packet, presentationTime: presentationTime)
    }

    public func finish() throws {
        try writer.finish()
    }

    // MARK: - Section header

    internal static func makeHapYSnappySection(payload: Data) throws -> Data {
        try HAPSection.make(payload: payload, type: sectionTypeHapYSnappy)
    }
}

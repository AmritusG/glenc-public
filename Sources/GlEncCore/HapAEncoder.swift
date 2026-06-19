// SPDX-License-Identifier: MIT
/*
 * HapAEncoder — v0.9.2 Phase C.
 *
 * Convenience encoder that wraps `HapABlockPacker` + Snappy + HAP
 * section header (type 0xB1) + a `VariantMOVWriter`. Owns its own
 * writer; suited to direct callers and unit tests. Mirrors
 * `HapYEncoder`'s shape exactly (Hap1 / Hap5 / HapY siblings).
 *
 * The pipeline-driven path uses `HapFrameEncoder(codec: .hapA)` and
 * an externally-managed `VariantMOVWriter` — same dispatch the other
 * HAP variants take in `EncodeQueue.run`.
 *
 * HapA encodes only the source's alpha channel into RGTC1/BC4. Per
 * the v0.9.2 Phase A Q2 decision, opaque sources (alphaInfo in
 * `.noneSkipFirst / .noneSkipLast / .none`) are rejected: HapA with
 * no usable alpha is a user error. The preflight runs in `append`
 * before any encoding work — error propagates through EncodeQueue's
 * existing failure path and surfaces in the queue row.
 *
 * Per-frame pipeline:
 *
 *     PixelFrame (BGRA8)
 *         │  PREFLIGHT: AlphaNormalization.mode(for: frame.alphaInfo).sourceHasAlpha
 *         │  false → throw HapAEncoderError.sourceHasNoAlpha
 *         ▼  HapABlockPacker.packBlocks(frame:)
 *     [BC4 alpha block stream — (codedW/4) × (codedH/4) × 8 B]
 *         │
 *         ▼  SnappyCompressor.compress(_:)
 *     [Snappy-compressed BC4 stream]
 *         │
 *         ▼  HAPSection.make(payload:, type: 0xB1)
 *     [HAP section header || payload]
 *         │
 *         ▼  VariantMOVWriter(codecFourCC: "HapA").append(packet:presentationTime:)
 *     [.mov mdat sample]
 *
 * Section type 0xB1 per Vidvox HAP spec (high nibble 0xB = Snappy,
 * low nibble 0x1 = RGTC1). Verified against GlanceCore.HAPPacketDecoder.
 */

import Foundation
import CoreMedia

/// Errors that can surface from HapA encoding. `HapFrameEncoder` reuses
/// `sourceHasNoAlpha` when its `.hapA` dispatch path preflights an
/// opaque source — same error vocabulary across both code paths.
public enum HapAEncoderError: Error, CustomStringConvertible {
    case sourceHasNoAlpha
    public var description: String {
        switch self {
        case .sourceHasNoAlpha:
            return "HapAEncoder: HapA requires a source with an alpha channel"
        }
    }
}

public final class HapAEncoder {

    /// HAP section type byte for Snappy-compressed RGTC1/BC4 alpha.
    private static let sectionTypeHapASnappy: UInt8 = 0xB1

    private let packer = HapABlockPacker()
    private let writer: VariantMOVWriter

    public init(width: Int, height: Int, fps: Double, destURL: URL) throws {
        precondition(width > 0 && height > 0)
        packer.prepare(width: width, height: height)
        self.writer = try VariantMOVWriter(
            destURL: destURL,
            format: .hapA,
            presentationWidth: width,
            presentationHeight: height,
            fps: fps,
            // writerVersion: falls through to VariantMOVWriter's
            // "GlEnc" default. See Hap1Encoder for the v0.9.2 D.5
            // rationale.
            codecFourCC: "HapA")
    }

    public func append(frame: PixelFrame, presentationTime: CMTime) throws {
        // Q2 preflight: HapA requires usable alpha. If alphaInfo
        // indicates no alpha (.noneSkipFirst/.noneSkipLast/.none),
        // sourceHasAlpha is false → reject before doing any work.
        let mode = try AlphaNormalization.mode(for: frame.alphaInfo)
        guard mode.sourceHasAlpha else {
            throw HapAEncoderError.sourceHasNoAlpha
        }

        let bc4 = try packer.packBlocks(frame: frame)
        let snappyPayload = SnappyCompressor.compress(bc4)
        let packet = try Self.makeHapASnappySection(payload: snappyPayload)
        try writer.append(packet: packet, presentationTime: presentationTime)
    }

    public func finish() throws {
        try writer.finish()
    }

    // MARK: - Section header

    /// Thin wrapper around `HAPSection.make` that locks in the
    /// Snappy + RGTC1 section-type byte. Exposed `internal` so tests
    /// can construct sections directly without going through the full
    /// encoder.
    internal static func makeHapASnappySection(payload: Data) throws -> Data {
        try HAPSection.make(payload: payload, type: sectionTypeHapASnappy)
    }
}

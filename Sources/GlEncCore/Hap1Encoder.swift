// SPDX-License-Identifier: MIT
/*
 * Hap1Encoder — v0.9.1 Phase D.
 *
 * Wires the existing BC1 (DXT1) block compression + Phase B's
 * SnappyCompressor + Phase C's parameterized VariantMOVWriter into
 * a complete Hap1 encoder. Produces .mov files with `Hap1` codec
 * FourCC that GlanceCore's HAPPacketDecoder reads correctly.
 *
 * Per-frame pipeline:
 *
 *     PixelFrame (BGRA8)
 *         │
 *         ▼  DXT1Encoder.encodeBlocks(frame:)
 *     [DXT1 block bytes — coded_w/4 × coded_h/4 × 8 B each]
 *         │
 *         ▼  SnappyCompressor.compress(_:)
 *     [Snappy-compressed DXT1 stream]
 *         │
 *         ▼  prepend 4-byte HAP section header (or 8-byte extended
 *            when payload ≥ 16 MB — extremely unlikely for compressed
 *            DXT1 at typical VJ resolutions, but handled correctly):
 *               bytes 0..2: payload length LSB→MSB
 *               byte 3:     section type 0xBB (Snappy + DXT1 = Hap1)
 *               bytes 4..7: 32-bit LE extended length (extended form only,
 *                           signaled by bytes 0..2 being zero)
 *         │
 *         ▼  VariantMOVWriter.append(packet:presentationTime:)
 *     [.mov mdat sample]
 *
 * Section-type byte layout per Vidvox HAP spec (high nibble =
 * compression, low nibble = format):
 *
 *     0xA_ = no compression          0x_B = DXT1 (Hap1)
 *     0xB_ = Snappy                  0x_E = DXT5 (Hap5)
 *     0xC_ = chunked Snappy          0x_F = scaled-YCoCg-DXT5 (HapY)
 *                                    0x_1 = RGTC1 alpha (HapA)
 *
 * Phase D emits 0xBB only (Snappy-compressed Hap1). The uncompressed
 * 0xAB form is valid HAP1 but ~5× larger and offers no Resolume
 * compatibility benefit; we don't expose it.
 */

import Foundation
import CoreMedia

public final class Hap1Encoder {

    /// HAP section type byte for Snappy-compressed DXT1 RGB.
    private static let sectionTypeHap1Snappy: UInt8 = 0xBB

    private let dxt1: DXT1Encoder
    private let writer: VariantMOVWriter

    public init(width: Int, height: Int, fps: Double, destURL: URL) throws {
        let dxt1 = DXT1Encoder()
        // v0.9.2 Phase C.5: HAP-native 4-pixel coded alignment (was
        // 16-pixel via the default prepare in v0.9.1). DXV3 callers
        // keep using the default-alignment prepare; HAP callers pass 4.
        try dxt1.prepare(width: width, height: height, fps: fps,
                         hasAlpha: false, codedAlignment: 4)
        self.dxt1 = dxt1
        self.writer = try VariantMOVWriter(
            destURL: destURL,
            // .dxt1 is informational on VariantMOVWriter (stored but
            // unused inside the writer; kept to preserve the API
            // surface and as a hint to call-site readers).
            format: .dxt1,
            presentationWidth: width,
            presentationHeight: height,
            fps: fps,
            // writerVersion intentionally not supplied — falls through
            // to VariantMOVWriter's "GlEnc" default. Production callers
            // (EncodeQueue's WriterFactory) supply AppVersion.writerVersion
            // directly; the convenience encoders here are reached only
            // by unit tests, which don't assert on the ©swr atom.
            codecFourCC: "Hap1")
    }

    public func append(frame: PixelFrame, presentationTime: CMTime) throws {
        // Steps 1-2 (in DXT1Encoder.encodeBlocks): BGRA → padded RGBA → BC1 blocks.
        let dxt1Bytes = try dxt1.encodeBlocks(frame: frame)
        // Step 3: Snappy.
        let snappyPayload = SnappyCompressor.compress(dxt1Bytes)
        // Step 4: prepend HAP section header.
        let packet = try Self.makeHap1SnappySection(payload: snappyPayload)
        // Step 5: hand to the writer.
        try writer.append(packet: packet, presentationTime: presentationTime)
    }

    public func finish() throws {
        try writer.finish()
    }

    // MARK: - Section header

    /// Thin wrapper around `HAPSection.make` that locks in the
    /// Snappy + DXT1 section-type byte. Exposed `internal` so tests
    /// can construct sections directly without going through the full
    /// encoder. Phase E centralized the byte layout in `HAPSection`;
    /// keeping this entry point preserves the Phase D test API.
    internal static func makeHap1SnappySection(payload: Data) throws -> Data {
        try HAPSection.make(payload: payload, type: sectionTypeHap1Snappy)
    }
}

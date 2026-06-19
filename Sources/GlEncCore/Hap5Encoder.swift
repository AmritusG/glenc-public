// SPDX-License-Identifier: MIT
/*
 * Hap5Encoder — v0.9.1 Phase E.
 *
 * Wires the existing BC3 (DXT5) block compression + Phase B's
 * SnappyCompressor + Phase C's parameterized VariantMOVWriter into
 * a complete Hap5 encoder. Produces .mov files with `Hap5` codec
 * FourCC that GlanceCore's HAPPacketDecoder reads correctly.
 *
 * Per-frame pipeline:
 *
 *     PixelFrame (BGRA8)
 *         │
 *         ▼  DXT5Encoder.encodeBlocks(frame:)
 *     [BC3 block bytes — coded_w/4 × coded_h/4 × 16 B each
 *      (8 B BC4 alpha + 8 B BC1 color per 4×4 tile)]
 *         │
 *         ▼  SnappyCompressor.compress(_:)
 *     [Snappy-compressed BC3 stream]
 *         │
 *         ▼  HAPSection.make(payload:, type: 0xBE)
 *     [4 / 8-byte HAP section header || payload]
 *         │
 *         ▼  VariantMOVWriter.append(packet:presentationTime:)
 *     [.mov mdat sample]
 *
 * Section-type byte 0xBE per Vidvox HAP spec: high nibble 0xB =
 * Snappy compression, low nibble 0xE = DXT5 format. The 0xAE
 * (uncompressed Hap5) variant is valid HAP5 but not exposed —
 * Snappy is the only sensible default for Resolume playback.
 */

import Foundation
import CoreMedia

public final class Hap5Encoder {

    /// HAP section type byte for Snappy-compressed DXT5 RGBA.
    private static let sectionTypeHap5Snappy: UInt8 = 0xBE

    private let dxt5: DXT5Encoder
    private let writer: VariantMOVWriter

    public init(width: Int, height: Int, fps: Double, destURL: URL) throws {
        let dxt5 = DXT5Encoder()
        // v0.9.2 Phase C.5: HAP-native 4-pixel coded alignment (was
        // 16-pixel via the default prepare in v0.9.1). DXV3 callers
        // keep using the default-alignment prepare; HAP callers pass 4.
        try dxt5.prepare(width: width, height: height, fps: fps,
                         hasAlpha: true, codedAlignment: 4)
        self.dxt5 = dxt5
        self.writer = try VariantMOVWriter(
            destURL: destURL,
            // .dxt5 is informational on VariantMOVWriter (stored but
            // unused inside the writer; the codecFourCC parameter is
            // what actually drives the stsd entry).
            format: .dxt5,
            presentationWidth: width,
            presentationHeight: height,
            fps: fps,
            // writerVersion: falls through to VariantMOVWriter's
            // "GlEnc" default. See Hap1Encoder for the v0.9.2 D.5
            // rationale.
            codecFourCC: "Hap5")
    }

    public func append(frame: PixelFrame, presentationTime: CMTime) throws {
        // Steps 1-2 (in DXT5Encoder.encodeBlocks): BGRA → padded RGBA
        // (with source-alpha normalization per Pass B) → BC3 blocks.
        let dxt5Bytes = try dxt5.encodeBlocks(frame: frame)
        // Step 3: Snappy.
        let snappyPayload = SnappyCompressor.compress(dxt5Bytes)
        // Step 4: prepend HAP section header.
        let packet = try Self.makeHap5SnappySection(payload: snappyPayload)
        // Step 5: hand to the writer.
        try writer.append(packet: packet, presentationTime: presentationTime)
    }

    public func finish() throws {
        try writer.finish()
    }

    // MARK: - Section header

    /// Thin wrapper around `HAPSection.make` that locks in the
    /// Snappy + DXT5 section-type byte. Exposed `internal` so tests
    /// can construct sections directly without going through the full
    /// encoder.
    internal static func makeHap5SnappySection(payload: Data) throws -> Data {
        try HAPSection.make(payload: payload, type: sectionTypeHap5Snappy)
    }
}

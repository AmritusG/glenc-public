// SPDX-License-Identifier: MIT
/*
 * HapMEncoder — v0.9.3 Phase B.
 *
 * Convenience encoder for HapM, the Resolume-loadable HAP + alpha
 * format. HapM is an outer 0x0D section wrapping two inner sections:
 * a HapY (Scaled YCoCg DXT5) section carrying RGB, and a HapA
 * (RGTC1/BC4) section carrying alpha. Per the v0.9.2 D-rollback
 * finding, standalone HapA is not Resolume-importable; HapM is the
 * variant Arena loads as a clip codec.
 *
 * This encoder COMPOSES the existing primitives — no new low-level
 * encoding code. Building blocks:
 *
 *   - HapYBlockPacker  (v0.9.1 Phase G)  → BC3 blocks for color
 *   - HapABlockPacker  (v0.9.2 Phase B)  → BC4 blocks for alpha
 *   - SnappyCompressor (v0.9.1 Phase B)  → per-inner-section Snappy
 *   - HAPSection.make  (v0.9.1 Phase E)  → short/long-form section header
 *   - VariantMOVWriter (v0.9.1 Phase C)  → MOV writer parameterized by FourCC
 *
 * The pipeline-driven dispatch (HapFrameEncoder.Codec.hapM,
 * DXVFormat.hapM, EncodeQueue dispatch, UI re-enable) is Phase C work.
 * This file ships the encoder API on its own so it can be tested
 * independently — same pattern as HapYEncoder / HapAEncoder.
 *
 * Per-frame pipeline:
 *
 *     PixelFrame (BGRA8)
 *         │
 *         ├──→ HapYBlockPacker.packBlocks(frame:)
 *         │      → [BC3 blocks — (codedW/4) × (codedH/4) × 16 B]
 *         │      → SnappyCompressor.compress(_:)
 *         │      → HAPSection.make(payload:, type: 0xBF)   inner HapY section
 *         │
 *         └──→ HapABlockPacker.packBlocks(frame:)
 *                → [BC4 blocks — (codedW/4) × (codedH/4) × 8 B]
 *                → SnappyCompressor.compress(_:)
 *                → HAPSection.make(payload:, type: 0xB1)   inner HapA section
 *
 *     concat(innerHapY, innerHapA)            // Q2: HapY first, HapA second
 *         │
 *         ▼  HAPSection.make(payload:, type: 0x0D)         outer wrapper
 *     [HAP section header || (innerHapY || innerHapA)]
 *         │
 *         ▼  VariantMOVWriter(codecFourCC: "HapM").append
 *     [.mov mdat sample]
 *
 * Q1 — inner section compression. Locked: single-Snappy (0xBF for HapY,
 * 0xB1 for HapA). Real HapM files in the wild commonly use chunked-
 * Snappy (0xCF/0xC1) but Glance's decoder accepts both forms; we ship
 * the simpler single-Snappy emission and revisit only if Arena
 * rejects.
 *
 * Q3 — opaque-source handling. Locked: NO rejection. Opaque sources
 * (alpha info indicating none) pass through HapABlockPacker normally;
 * the BC4 plane encodes alpha=255 across every block, the outer
 * 0x0D still wraps a normal HapY + HapA pair. This matches Hap5's
 * behaviour (a Hap5 of an opaque source produces an opaque DXT5 alpha
 * byte), differing from standalone HapA's Q2 reject (HapA is alpha-
 * only and an opaque source there means no signal at all).
 */

import Foundation
import CoreMedia

public final class HapMEncoder {

    /// HAP section type bytes used by HapM. The outer 0x0D wraps a
    /// concatenation of these two inner sections (Q1 single-Snappy
    /// form). Both inner type bytes are identical to the standalone
    /// HapY/HapA encoders — HapM doesn't introduce a new texture
    /// kind, only a new container.
    private static let outerSectionTypeHapM: UInt8 = 0x0D
    private static let innerSectionTypeHapYSnappy: UInt8 = 0xBF
    private static let innerSectionTypeHapASnappy: UInt8 = 0xB1

    private let yPacker = HapYBlockPacker()
    private let aPacker = HapABlockPacker()
    private let writer: VariantMOVWriter

    public init(width: Int, height: Int, fps: Double, destURL: URL) throws {
        precondition(width > 0 && height > 0)
        // 4-pixel HAP-native coded alignment is built into both packers
        // (HapYBlockPacker.prepare line 64-65; HapABlockPacker.prepare
        // line 93-94) since v0.9.2 Phase C.5. No alignment work here —
        // just forward the presentation dims.
        yPacker.prepare(width: width, height: height)
        aPacker.prepare(width: width, height: height)
        self.writer = try VariantMOVWriter(
            destURL: destURL,
            // .hapA is informational on VariantMOVWriter — used as a
            // typed hint at call-sites; the writer's behavior is driven
            // by codecFourCC. We pass .hapA here as the closest existing
            // DXVFormat case (HapM's DXVFormat.hapM is Phase C; this
            // encoder ships ahead of that wiring). The codecFourCC
            // "HapM" string is what the stsd atom receives.
            format: .hapA,
            presentationWidth: width,
            presentationHeight: height,
            fps: fps,
            // writerVersion intentionally not supplied — falls through
            // to VariantMOVWriter's "GlEnc" default. Production callers
            // (Phase C's EncodeQueue WriterFactory) supply
            // AppVersion.writerVersion directly; this convenience
            // encoder is reached only by unit tests.
            codecFourCC: "HapM")
    }

    public func append(frame: PixelFrame, presentationTime: CMTime) throws {
        // Q3 — no opaque-source reject. HapABlockPacker handles every
        // alphaInfo case (the "force opaque" mode of AlphaNormalization
        // writes α=255 pixel-wide; BC4 then encodes that as a trivial
        // single-endpoint block). Opaque HapM is a valid HapM.
        let bc3 = try yPacker.packBlocks(frame: frame)
        let bc4 = try aPacker.packBlocks(frame: frame)

        // Compress each inner block stream INDEPENDENTLY — the outer
        // 0x0D is structural only, not a compression boundary.
        let snappyY = SnappyCompressor.compress(bc3)
        let snappyA = SnappyCompressor.compress(bc4)

        // Wrap each into its inner HAP section. HAPSection.make picks
        // short-form (4-byte) vs extended-form (8-byte) automatically
        // based on payload size; either is spec-legal and Glance's
        // decoder handles both.
        let innerY = try HAPSection.make(payload: snappyY,
                                         type: Self.innerSectionTypeHapYSnappy)
        let innerA = try HAPSection.make(payload: snappyA,
                                         type: Self.innerSectionTypeHapASnappy)

        // Q2 — HapY first, HapA second. Inner-section order is not
        // fixed by spec; Glance's decoder routes by texture kind, not
        // position. We pick HapY-first to match natural read order
        // (color before alpha; mirrors standalone Hap5's "color first"
        // intuition).
        var combined = Data(capacity: innerY.count + innerA.count)
        combined.append(innerY)
        combined.append(innerA)

        // Outer 0x0D wraps the concatenation. HAPSection.make auto-
        // picks long-form when the combined inner sections push past
        // the 16 MB short-form ceiling — extremely rare at HD/FHD
        // (combined inner sections at 1080p typically sit under a few
        // MB) but handled correctly.
        let packet = try HAPSection.make(payload: combined,
                                         type: Self.outerSectionTypeHapM)
        try writer.append(packet: packet, presentationTime: presentationTime)
    }

    public func finish() throws {
        try writer.finish()
    }

    // MARK: - Section header constructors (exposed for tests)

    /// Build an inner HapY (Snappy) section from already-Snappy'd BC3
    /// bytes. Exposed `internal` so unit tests can construct the
    /// piece-wise layout without invoking a full encode.
    internal static func makeInnerHapYSection(snappyPayload: Data) throws -> Data {
        try HAPSection.make(payload: snappyPayload, type: innerSectionTypeHapYSnappy)
    }

    /// Build an inner HapA (Snappy) section from already-Snappy'd BC4
    /// bytes.
    internal static func makeInnerHapASection(snappyPayload: Data) throws -> Data {
        try HAPSection.make(payload: snappyPayload, type: innerSectionTypeHapASnappy)
    }

    /// Build the outer 0x0D section from a pre-concatenated inner
    /// section buffer (innerHapY || innerHapA per Q2).
    internal static func makeOuterHapMSection(innerSectionsConcat: Data) throws -> Data {
        try HAPSection.make(payload: innerSectionsConcat, type: outerSectionTypeHapM)
    }
}

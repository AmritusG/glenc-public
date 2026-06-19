// SPDX-License-Identifier: MIT
/*
 * HapFrameEncoder — v0.9.1 Phase G; .hapM added in v0.9.3 Phase C.
 *
 * `FrameEncoder`-conforming adapter that emits HAP section packets
 * suitable for piping into `VariantMOVWriter` via `EncodePipeline`.
 * Codec-parameterized: Hap1 / Hap5 / HapY / HapA / HapM share the
 * same wrap (BC blocks → Snappy → HAP section header) but HapM
 * additionally composes two inner sections under an outer 0x0D
 * wrapper.
 *
 *     codec    block source(s)                       section type(s) emitted
 *     ─────    ──────────────────────────────────    ────────────────────────
 *     hap1     DXT1Encoder.encodeBlocks              0xBB (single section)
 *     hap5     DXT5Encoder.encodeBlocks              0xBE (single section)
 *     hapY     HapYBlockPacker.packBlocks            0xBF (single section)
 *     hapA     HapABlockPacker.packBlocks            0xB1 (single section, v0.9.2)
 *     hapM     HapYBlockPacker + HapABlockPacker     0x0D outer wrapping
 *                                                    0xBF (HapY) + 0xB1 (HapA)  (v0.9.3)
 *
 * Per-frame, this encoder returns the full HAP section packet (header
 * + Snappy-compressed BC stream — or for HapM, the outer 0x0D packet
 * containing two inner sections). The caller's writer factory should
 * produce a `VariantMOVWriter` with the matching `codecFourCC`
 * ("Hap1" / "Hap5" / "HapY" / "HapA" / "HapM") so the stsd entry is
 * right.
 *
 * Phase F's standalone `Hap1Encoder` / `Hap5Encoder` / `HapYEncoder`
 * / `HapAEncoder` / `HapMEncoder` (the last from v0.9.3 Phase B)
 * remain available for direct callers (and their unit tests); this
 * type is what EncodeQueue dispatches through.
 */

import Foundation

public final class HapFrameEncoder: FrameEncoder {

    /// Which HAP variant to emit. Drives both the inner block encoder
    /// selection and the section-type byte. HapM (v0.9.3) is the
    /// composite variant — it wraps two inner sections under a 0x0D
    /// outer, so its `sectionType` is the OUTER wrapper type.
    public enum Codec: Sendable {
        case hap1
        case hap5
        case hapY
        case hapA
        case hapM

        var sectionType: UInt8 {
            switch self {
            case .hap1: return 0xBB
            case .hap5: return 0xBE
            case .hapY: return 0xBF
            case .hapA: return 0xB1
            case .hapM: return 0x0D
            }
        }

        var fourCC: String {
            switch self {
            case .hap1: return "Hap1"
            case .hap5: return "Hap5"
            case .hapY: return "HapY"
            case .hapA: return "HapA"
            case .hapM: return "HapM"
            }
        }
    }

    /// Inner section type bytes for HapM's two inner sections.
    /// Mirrors HapMEncoder.swift's constants — kept private here
    /// because HapFrameEncoder is the pipeline-side composition
    /// entry; the standalone HapMEncoder owns the equivalent
    /// definitions for its own callers.
    private static let hapMInnerHapYSnappy: UInt8 = 0xBF
    private static let hapMInnerHapASnappy: UInt8 = 0xB1

    public let codec: Codec

    // Per-case state. For .hap1/.hap5/.hapY/.hapA exactly one of these
    // is non-nil after `prepare`. For .hapM BOTH `hapY` and `hapA`
    // are non-nil — HapM composes a HapY (color) section + a HapA
    // (alpha) section per frame.
    private var dxt1: DXT1Encoder?
    private var dxt5: DXT5Encoder?
    private var hapY: HapYBlockPacker?
    private var hapA: HapABlockPacker?

    public init(codec: Codec) {
        self.codec = codec
    }

    public func prepare(width: Int, height: Int, fps: Double, hasAlpha: Bool) throws {
        switch codec {
        case .hap1:
            let e = DXT1Encoder()
            // v0.9.2 Phase C.5: HAP-native 4-pixel coded alignment.
            // DXV3 callers (EncodeQueue's case .dxt1) keep using the
            // default-alignment prepare which gives 16-pixel — DXV3
            // byte-identity preserved.
            try e.prepare(width: width, height: height, fps: fps,
                          hasAlpha: false, codedAlignment: 4)
            dxt1 = e
        case .hap5:
            let e = DXT5Encoder()
            try e.prepare(width: width, height: height, fps: fps,
                          hasAlpha: true, codedAlignment: 4)
            dxt5 = e
        case .hapY:
            let p = HapYBlockPacker()
            p.prepare(width: width, height: height)  // 4-pixel post-C.5
            hapY = p
        case .hapA:
            let p = HapABlockPacker()
            p.prepare(width: width, height: height)  // 4-pixel since Phase B
            hapA = p
        case .hapM:
            // v0.9.3 Phase C: HapM prepares BOTH packers at the same
            // dims (both already 4-pixel-aligned per their own
            // prepare implementations). The composite encode body
            // below uses both per frame.
            let yp = HapYBlockPacker()
            yp.prepare(width: width, height: height)
            hapY = yp
            let ap = HapABlockPacker()
            ap.prepare(width: width, height: height)
            hapA = ap
        }
    }

    public func encode(frame: PixelFrame) throws -> Data {
        // HapM is structurally different from the other four — it
        // produces an outer 0x0D wrapping two inner sections rather
        // than a single Snappy-compressed BC stream. Branch out here
        // so the other four can keep their uniform "blocks → Snappy →
        // single HAPSection" shape.
        if codec == .hapM {
            return try encodeHapM(frame: frame)
        }

        let blocks: Data
        switch codec {
        case .hap1:
            guard let e = dxt1 else { fatalError("HapFrameEncoder(.hap1): encode before prepare") }
            blocks = try e.encodeBlocks(frame: frame)
        case .hap5:
            guard let e = dxt5 else { fatalError("HapFrameEncoder(.hap5): encode before prepare") }
            blocks = try e.encodeBlocks(frame: frame)
        case .hapY:
            guard let p = hapY else { fatalError("HapFrameEncoder(.hapY): encode before prepare") }
            blocks = try p.packBlocks(frame: frame)
        case .hapA:
            // Q2 preflight: HapA requires usable alpha. Same reject
            // policy HapAEncoder (the convenience encoder) enforces;
            // both pipeline + standalone paths share the rule.
            guard let p = hapA else { fatalError("HapFrameEncoder(.hapA): encode before prepare") }
            let mode = try AlphaNormalization.mode(for: frame.alphaInfo)
            guard mode.sourceHasAlpha else {
                throw HapAEncoderError.sourceHasNoAlpha
            }
            blocks = try p.packBlocks(frame: frame)
        case .hapM:
            // Handled in the early-return branch above.
            fatalError("unreachable — .hapM is handled in encodeHapM(frame:)")
        }
        let snappyPayload = SnappyCompressor.compress(blocks)
        return try HAPSection.make(payload: snappyPayload, type: codec.sectionType)
    }

    public func finish() throws {
        // No flush state to clear — every frame is self-contained.
    }

    // MARK: - HapM composition (v0.9.3 Phase C)

    /// HapM per-frame: pack a HapY color section + a HapA alpha
    /// section (both Snappy-compressed, both wrapped in their own
    /// inner HAP section header), concatenate HapY-first (Q2), and
    /// wrap the concatenation in an outer 0x0D section.
    ///
    /// Q3 — opaque sources are NOT rejected. HapABlockPacker handles
    /// every alphaInfo case (the AlphaNormalization helper's force-
    /// opaque mode writes α=255 throughout; BC4 collapses that to a
    /// trivial single-endpoint block per tile). An opaque HapM is a
    /// valid HapM. This differs from the .hapA case above, which
    /// rejects opaque sources because standalone HapA encodes ONLY
    /// alpha and an opaque source there means no signal at all.
    private func encodeHapM(frame: PixelFrame) throws -> Data {
        guard let yp = hapY, let ap = hapA else {
            fatalError("HapFrameEncoder(.hapM): encode before prepare")
        }
        let bc3 = try yp.packBlocks(frame: frame)
        let bc4 = try ap.packBlocks(frame: frame)
        let snappyY = SnappyCompressor.compress(bc3)
        let snappyA = SnappyCompressor.compress(bc4)
        let innerY = try HAPSection.make(payload: snappyY,
                                         type: Self.hapMInnerHapYSnappy)
        let innerA = try HAPSection.make(payload: snappyA,
                                         type: Self.hapMInnerHapASnappy)
        // Q2 — HapY first, HapA second.
        var combined = Data(capacity: innerY.count + innerA.count)
        combined.append(innerY)
        combined.append(innerA)
        return try HAPSection.make(payload: combined, type: codec.sectionType)
    }
}

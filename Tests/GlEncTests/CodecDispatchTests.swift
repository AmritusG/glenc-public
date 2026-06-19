/*
 * CodecDispatchTests — v0.9.1 Phase G.
 *
 * Validates the (QualityTier × AlphaMode) → DXVFormat mapping and
 * the per-format family / FourCC / qualityTier round-trip used by
 * EncodeQueue dispatch, AutoNameEngine, and VariantMOVWriter.
 */

import XCTest
import Foundation
@testable import GlEnc
@testable import GlEncCore

@MainActor
final class CodecDispatchTests: XCTestCase {

    /// Every (tier, alpha) combination produces a valid DXVFormat
    /// and a round-trip back through `.qualityTier` / `.alphaMode`
    /// is identity-preserving. v0.9.3 Phase C: (.hapQ, .withAlpha)
    /// now resolves to .hapM (was .hapY stub in v0.9.2); all 8 cells
    /// of the matrix are first-class round-trippable.
    func testQualityTierAlphaMatrix() {
        let cases: [(QualityTier, AlphaMode, DXVFormat)] = [
            (.normal, .withoutAlpha, .dxt1),
            (.normal, .withAlpha,    .dxt5),
            (.hq,     .withoutAlpha, .ycg6),
            (.hq,     .withAlpha,    .yg10),
            (.hap,    .withoutAlpha, .hap1),
            (.hap,    .withAlpha,    .hap5),
            (.hapQ,   .withoutAlpha, .hapY),
            (.hapQ,   .withAlpha,    .hapM),  // v0.9.3 Phase C
        ]
        for (tier, alpha, expected) in cases {
            let f = DXVFormat(tier: tier, alpha: alpha)
            XCTAssertEqual(f, expected,
                           "(\(tier), \(alpha)) should map to \(expected)")
            XCTAssertEqual(f.qualityTier, tier,
                           "round-trip qualityTier mismatch for \(expected)")
            XCTAssertEqual(f.alphaMode, alpha,
                           "round-trip alphaMode mismatch for \(expected)")
        }
    }

    /// HAP Q + With Alpha now resolves to .hapM. v0.9.3 Phase C
    /// replaces the v0.9.2 .hapY stub fallback with the real
    /// composite variant. The swap is unconditional (Q3 + Q4):
    /// no opaque-source branch, no defensive .hapY fallback.
    func testHapQWithAlphaResolvesToHapM() {
        let f = DXVFormat(tier: .hapQ, alpha: .withAlpha)
        XCTAssertEqual(f, .hapM,
                       "HAP Q + With Alpha should resolve to .hapM as of v0.9.3 Phase C")
        XCTAssertEqual(DXVFormat.hapM.qualityTier, .hapQ,
                       ".hapM should decompose to HAP Q tier")
        XCTAssertEqual(DXVFormat.hapM.alphaMode, .withAlpha,
                       ".hapM carries alpha by definition")
    }

    /// (.hapQ, .withoutAlpha) is unchanged — still .hapY. Spot-check
    /// guarding against accidental over-correction during the Phase C
    /// resolver swap.
    func testHapQNoAlphaUnchanged() {
        XCTAssertEqual(DXVFormat(tier: .hapQ, alpha: .withoutAlpha), .hapY)
    }

    /// v0.9.2 Phase D-rollback: standalone HapA is NOT exposed in the
    /// user-facing Codec dropdown (Resolume doesn't import the variant
    /// — Phase F finding), but `DXVFormat.hapA` and the HapA encoder
    /// remain fully shipped for v0.9.3's HapM to compose with.
    /// `.hapA.qualityTier` maps to `.hap` (no dedicated UI tier in
    /// v0.9.2; v0.9.3 → HapM revisits the HAP+alpha UI story).
    /// `.hapA.alphaMode` is `.withAlpha` (HapA carries alpha by
    /// definition — alpha-only RGTC1 BC4).
    func testHapAEncoderFormatPreserved() {
        XCTAssertEqual(DXVFormat.hapA.qualityTier, .hap,
                       ".hapA decomposes to .hap (no dedicated UI tier in v0.9.2 post-D-rollback)")
        XCTAssertEqual(DXVFormat.hapA.alphaMode, .withAlpha,
                       ".hapA carries alpha by definition")
    }

    /// `.family` partitions all 9 cases correctly (v0.9.3 adds HapM).
    func testFamilyPartition() {
        let dxv3: [DXVFormat] = [.dxt1, .dxt5, .ycg6, .yg10]
        let hap:  [DXVFormat] = [.hap1, .hap5, .hapY, .hapA, .hapM]
        for f in dxv3 {
            XCTAssertEqual(f.family, .dxv3, "\(f) should be DXV3 family")
        }
        for f in hap {
            XCTAssertEqual(f.family, .hap, "\(f) should be HAP family")
        }
    }

    /// MOV stream FourCC: DXV3 variants share "DXD3"; HAP variants
    /// use their own FourCC.
    func testStreamFourCC() {
        XCTAssertEqual(DXVFormat.dxt1.streamFourCC, "DXD3")
        XCTAssertEqual(DXVFormat.dxt5.streamFourCC, "DXD3")
        XCTAssertEqual(DXVFormat.ycg6.streamFourCC, "DXD3")
        XCTAssertEqual(DXVFormat.yg10.streamFourCC, "DXD3")
        XCTAssertEqual(DXVFormat.hap1.streamFourCC, "Hap1")
        XCTAssertEqual(DXVFormat.hap5.streamFourCC, "Hap5")
        XCTAssertEqual(DXVFormat.hapY.streamFourCC, "HapY")
        XCTAssertEqual(DXVFormat.hapA.streamFourCC, "HapA")
        XCTAssertEqual(DXVFormat.hapM.streamFourCC, "HapM")
    }

    /// HAP variants have no per-frame DXV3 tag.
    func testHapFormatsHaveNoFrameTag() {
        XCTAssertNil(DXVFormat.hap1.frameTagBytes)
        XCTAssertNil(DXVFormat.hap5.frameTagBytes)
        XCTAssertNil(DXVFormat.hapY.frameTagBytes)
        XCTAssertNil(DXVFormat.hapA.frameTagBytes)
        XCTAssertNil(DXVFormat.hapM.frameTagBytes)
    }

    /// DXV3 variants keep their existing per-frame tags exactly.
    func testDXV3FrameTagsUnchanged() {
        XCTAssertEqual(DXVFormat.dxt1.frameTagBytes, [0x31, 0x54, 0x58, 0x44])
        XCTAssertEqual(DXVFormat.dxt5.frameTagBytes, [0x35, 0x54, 0x58, 0x44])
        XCTAssertEqual(DXVFormat.ycg6.frameTagBytes, [0x36, 0x47, 0x43, 0x59])
        XCTAssertEqual(DXVFormat.yg10.frameTagBytes, [0x30, 0x31, 0x47, 0x59])
    }

    /// QualityTier dropdown lists 4 user-facing options. (v0.9.2's
    /// .hapAlpha tier was rolled back in Phase D-rollback — Resolume
    /// doesn't import standalone HapA. The HapA encoder ships intact
    /// for v0.9.3's HapM.)
    func testQualityTierAllCases() {
        XCTAssertEqual(QualityTier.allCases.map(\.rawValue),
                       ["normal", "hq", "hap", "hap_q"])
    }

    /// User-visible labels for the 4 v0.9.2 Codec dropdown entries.
    func testQualityTierLabels() {
        XCTAssertEqual(QualityTier.normal.label, "DXV3 Normal")
        XCTAssertEqual(QualityTier.hq.label,     "DXV3 HQ")
        XCTAssertEqual(QualityTier.hap.label,    "HAP")
        XCTAssertEqual(QualityTier.hapQ.label,   "HAP Q")
    }
}

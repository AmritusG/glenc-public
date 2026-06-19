/*
 * ResizeTypesTests — Resize Release Phase B.
 *
 * Unit tests for the three pure value types: ResizeQuality,
 * StandardResolution, OutputSize. Every expected value is derived
 * from the locked decisions (CROP_RESIZE_PLAN.md L1-L3 + Q1-Q5,
 * RESIZE_PLAN.md Q1-Q3) or the format spec — never pasted from
 * emitted output (standing rule).
 */

import XCTest
import Foundation
@testable import GlEncCore

final class ResizeQualityTests: XCTestCase {

    // MARK: - rawValue round-trip

    /// All 4 cases round-trip through their String rawValues. This
    /// is the UserDefaults persistence path the Phase C wiring uses
    /// (AppSettings.defaultResizeQuality.rawValue stored / loaded).
    func testRawValueRoundTrip() {
        for q in ResizeQuality.allCases {
            let r = q.rawValue
            let recovered = ResizeQuality(rawValue: r)
            XCTAssertEqual(recovered, q, "\(q) rawValue round-trip failed (rawValue=\(r))")
        }
    }

    func testAllCasesCount() {
        XCTAssertEqual(ResizeQuality.allCases.count, 4,
                       "ResizeQuality must have exactly 4 cases (auto/nearest/bilinear/lanczos)")
    }

    func testDisplayLabelsNonEmpty() {
        for q in ResizeQuality.allCases {
            XCTAssertFalse(q.displayLabel.isEmpty,
                           "\(q) must expose a non-empty displayLabel for the UI picker")
        }
    }

    // MARK: - Auto resolution by scale direction (Q1 + Q2)

    /// Downscale (output smaller than source on both axes): Auto
    /// resolves to .lanczos. Derived from CROP_RESIZE_PLAN.md Q4
    /// (downscale → Lanczos).
    func testAutoResolvesToLanczosOnDownscale() {
        let r = ResizeQuality.auto.resolved(
            forSourceWidth: 1920, sourceHeight: 1080,
            outputWidth: 1280, outputHeight: 720)
        XCTAssertEqual(r, .lanczos,
                       "Auto must pick Lanczos when downscaling (1920×1080 → 1280×720)")
    }

    /// Upscale (output larger on either axis): Auto resolves to
    /// .bilinear. Derived from RESIZE_PLAN.md Q1 (upscale →
    /// bilinear).
    func testAutoResolvesToBilinearOnUpscale() {
        let r = ResizeQuality.auto.resolved(
            forSourceWidth: 1280, sourceHeight: 720,
            outputWidth: 1920, outputHeight: 1080)
        XCTAssertEqual(r, .bilinear,
                       "Auto must pick Bilinear when upscaling (1280×720 → 1920×1080)")
    }

    /// Mixed direction (one axis shrinks, the other grows): Auto
    /// treats as upscale (any growth-axis benefits from the softer
    /// filter). Derived from the resolved() doc comment which
    /// documents the "BOTH axes ≤ source" downscale predicate; the
    /// alternative is upscale.
    func testAutoResolvesToBilinearOnMixedDirection() {
        let r = ResizeQuality.auto.resolved(
            forSourceWidth: 1920, sourceHeight: 720,
            outputWidth: 1080, outputHeight: 1920)
        XCTAssertEqual(r, .bilinear,
                       "Auto must treat mixed-direction scale as upscale (Bilinear)")
    }

    /// Equal dims: Auto resolves to .bilinear (a neutral default
    /// the resizer can detect and skip; the equal-dims case is moot
    /// — caller treats as no-op pass-through).
    func testAutoResolvesOnEqualDimensions() {
        let r = ResizeQuality.auto.resolved(
            forSourceWidth: 1920, sourceHeight: 1080,
            outputWidth: 1920, outputHeight: 1080)
        XCTAssertEqual(r, .bilinear,
                       "Auto on equal-dims returns bilinear (neutral; caller skips)")
    }

    /// Non-auto cases return themselves (the explicit-override
    /// contract — Auto is the only case that reads source/output dims).
    func testNonAutoCasesReturnSelf() {
        let cases: [ResizeQuality] = [.nearest, .bilinear, .lanczos]
        for q in cases {
            // Try both directions to confirm the dims don't affect
            // the non-auto cases.
            let down = q.resolved(forSourceWidth: 1920, sourceHeight: 1080,
                                  outputWidth: 1280, outputHeight: 720)
            let up = q.resolved(forSourceWidth: 1280, sourceHeight: 720,
                                outputWidth: 1920, outputHeight: 1080)
            XCTAssertEqual(down, q, "\(q) must return self on downscale")
            XCTAssertEqual(up, q, "\(q) must return self on upscale")
        }
    }

    /// Q2 — no soft scale-threshold. A 1-pixel difference still
    /// classifies strictly by direction.
    func testAutoHasNoSoftScaleThreshold() {
        // Downscale by 1 pixel on one axis → still .lanczos.
        let almostDown = ResizeQuality.auto.resolved(
            forSourceWidth: 1920, sourceHeight: 1080,
            outputWidth: 1920, outputHeight: 1079)
        XCTAssertEqual(almostDown, .lanczos,
                       "Auto must classify by direction even at 1-pixel difference (downscale)")
        // Upscale by 1 pixel on one axis → still .bilinear.
        let almostUp = ResizeQuality.auto.resolved(
            forSourceWidth: 1920, sourceHeight: 1080,
            outputWidth: 1920, outputHeight: 1081)
        XCTAssertEqual(almostUp, .bilinear,
                       "Auto must classify by direction even at 1-pixel difference (upscale)")
    }
}

final class StandardResolutionTests: XCTestCase {

    /// Count is exactly 16 per the locked preset list
    /// (RESIZE_PLAN.md §4 / CROP_RESIZE_PLAN.md §5):
    ///   HD/UHD: 4 entries
    ///   DCI: 2 entries
    ///   Square: 3 entries
    ///   Vertical: 3 entries
    ///   ---
    ///   Total: 12 (the LED / Projection category was removed in
    ///   Phase F per user verdict — the original plan listed 15
    ///   with LED, but VJ workflow doesn't reach for those dims).
    func testCaseCountMatchesPresetList() {
        XCTAssertEqual(StandardResolution.allCases.count, 12,
                       "StandardResolution case count must match the locked preset list in RESIZE_PLAN.md §4 (less the LED category dropped in Phase F)")
    }

    /// L3: every dimension reaching the encoder must be 4-pixel-
    /// aligned. This test guards the preset table itself — if any
    /// entry is not 4-multiple on either axis, the table is wrong
    /// and the build fails. Q3 confirmed L3 is uniform across all
    /// codecs (no HQ-conditional 16-multiple rounding).
    func testAllPresetsAre4PixelLegal() {
        for preset in StandardResolution.allCases {
            let (w, h) = preset.dimensions
            XCTAssertEqual(w % 4, 0,
                           "\(preset).width \(w) is not a multiple of 4 (L3 violation)")
            XCTAssertEqual(h % 4, 0,
                           "\(preset).height \(h) is not a multiple of 4 (L3 violation)")
        }
    }

    /// Spot-check a known entry to catch typos in the dimensions
    /// table. Full HD is the canonical reference dim.
    func testFullHDDimensions() {
        XCTAssertEqual(StandardResolution.fhd_1920_1080.dimensions.width, 1920)
        XCTAssertEqual(StandardResolution.fhd_1920_1080.dimensions.height, 1080)
    }

    func testAllDisplayLabelsNonEmpty() {
        for preset in StandardResolution.allCases {
            XCTAssertFalse(preset.displayLabel.isEmpty,
                           "\(preset) must expose a non-empty displayLabel")
        }
    }

    /// rawValue round-trip — drives Codable persistence at Phase C.
    func testRawValueRoundTrip() {
        for preset in StandardResolution.allCases {
            let r = preset.rawValue
            let recovered = StandardResolution(rawValue: r)
            XCTAssertEqual(recovered, preset, "\(preset) rawValue round-trip failed")
        }
    }
}

final class OutputSizeTests: XCTestCase {

    // MARK: - resolvedDimensions

    /// `.original` returns source dims unchanged.
    func testOriginalReturnsSourceDimensions() {
        let r = OutputSize.original.resolvedDimensions(sourceWidth: 1920, sourceHeight: 1080)
        XCTAssertEqual(r.width, 1920)
        XCTAssertEqual(r.height, 1080)
    }

    /// `.preset` returns the preset's dims (ignoring source).
    func testPresetReturnsPresetDimensions() {
        let r = OutputSize.preset(.fhd_1920_1080).resolvedDimensions(
            sourceWidth: 1280, sourceHeight: 720)
        XCTAssertEqual(r.width, 1920)
        XCTAssertEqual(r.height, 1080)
    }

    /// `.custom` returns its stored dims (ignoring source).
    func testCustomReturnsCustomDimensions() {
        let r = OutputSize.custom(width: 1500, height: 844).resolvedDimensions(
            sourceWidth: 1920, sourceHeight: 1080)
        XCTAssertEqual(r.width, 1500)
        XCTAssertEqual(r.height, 844)
    }

    // MARK: - Codable round-trip (JSON — the AppSettings path)

    private func jsonRoundTrip(_ value: OutputSize) throws -> OutputSize {
        let encoded = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(OutputSize.self, from: encoded)
    }

    func testCodableRoundTripOriginal() throws {
        let original = OutputSize.original
        XCTAssertEqual(try jsonRoundTrip(original), original)
    }

    func testCodableRoundTripPreset() throws {
        let preset = OutputSize.preset(.fhd_1920_1080)
        XCTAssertEqual(try jsonRoundTrip(preset), preset)
    }

    func testCodableRoundTripCustom() throws {
        let custom = OutputSize.custom(width: 1500, height: 844)
        XCTAssertEqual(try jsonRoundTrip(custom), custom)
    }

    /// Cross-check the cases are distinct via Hashable.
    func testCasesAreDistinct() {
        let set: Set<OutputSize> = [
            .original,
            .preset(.fhd_1920_1080),
            .preset(.hd_1280_720),
            .custom(width: 1920, height: 1080),
            .custom(width: 1920, height: 1084),  // 4-pixel-aligned ✓
        ]
        XCTAssertEqual(set.count, 5, "All five OutputSize values must be distinct")
    }

    /// Phase B does NOT silently round .custom — that's Phase F's
    /// Custom… sheet's job. A non-4-multiple custom is constructible
    /// here (caller's responsibility to align before encoding).
    /// Documenting the contract via test: .custom with non-aligned
    /// dims is allowed by the type system.
    func testCustomDoesNotSilentlyRound() {
        let nonAligned = OutputSize.custom(width: 1921, height: 1081)
        let r = nonAligned.resolvedDimensions(sourceWidth: 0, sourceHeight: 0)
        XCTAssertEqual(r.width, 1921, "OutputSize must not silently round .custom width")
        XCTAssertEqual(r.height, 1081, "OutputSize must not silently round .custom height")
    }
}

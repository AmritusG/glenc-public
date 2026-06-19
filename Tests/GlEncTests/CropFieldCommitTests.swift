/*
 * CropFieldCommitTests — Crop Release Phase E.9.
 *
 * Headless coverage for `commitCropFieldValue`, the pure field-
 * commit math behind rowCrop edit-mode text fields. Two
 * dimensions of coverage:
 *
 *   - Correction kinds: no-correction, round-to-4, source-bounds
 *     clamp, minimum (W/H min 4, X/Y min 0), combined (round +
 *     clamp).
 *   - Field isolation: editing W never touches X/Y/H, etc.
 *
 * The orange-flash cue in the UI is driven by
 * `result.wasCorrected`; every test asserts that flag along with
 * the corrected value and the updated rect.
 *
 * Source dims (1920 × 1080) match the most common VJ pipeline
 * target. Tests that exercise the dims-unknown fallback pass
 * Int.max as documented in CropFieldCommit.swift.
 */

import XCTest
import CoreGraphics
@testable import GlEnc

final class CropFieldCommitTests: XCTestCase {

    // MARK: - Codec-aware alignment (the "DXV crop still rounds to 4" fix)

    private let bigRect = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    func testCommit_Alignment1_NoRounding() {
        // ProRes/DXV/HAP/MJPEG (dimensionAlignment 1): odd typed crop dims
        // are accepted EXACTLY — no rounding (was: forced to 4).
        let r = commitCropFieldValue(field: .width, typedValue: 1921, currentRect: bigRect,
                                     sourceWidth: 4000, sourceHeight: 4000, alignment: 1)
        XCTAssertEqual(r.correctedValue, 1921, "alignment 1 must not round")
        XCTAssertEqual(Int(r.updatedRect.width), 1921)
        XCTAssertFalse(r.wasCorrected)
    }

    func testCommit_Alignment2_RoundsEven() {
        let r = commitCropFieldValue(field: .height, typedValue: 1081, currentRect: bigRect,
                                     sourceWidth: 4000, sourceHeight: 4000, alignment: 2)
        XCTAssertEqual(r.correctedValue, 1082, "H.264/HEVC → nearest even")
    }

    func testCommit_Default4_StillRoundsTo4() {
        // Back-compat: callers that don't pass alignment keep 4-px rounding.
        let r = commitCropFieldValue(field: .width, typedValue: 1921, currentRect: bigRect,
                                     sourceWidth: 4000, sourceHeight: 4000)
        XCTAssertEqual(r.correctedValue, 1920)
    }

    /// Default full-source rect for tests that don't need anything
    /// fancier. Mirrors the overlay's `fullFrameSeedRect` shape.
    private func fullFrame(_ w: Int = 1920, _ h: Int = 1080) -> CGRect {
        CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h))
    }

    // MARK: - 1. No correction needed

    func testCommit_NoCorrectionNeeded_FlagIsFalse() {
        let result = commitCropFieldValue(
            field: .width,
            typedValue: 1280,
            currentRect: fullFrame(),
            sourceWidth: 1920, sourceHeight: 1080)
        XCTAssertEqual(result.correctedValue, 1280)
        XCTAssertFalse(result.wasCorrected,
                       "1280 is 4-aligned and in bounds — no correction "
                       + "should fire, no orange flash")
        XCTAssertEqual(result.updatedRect,
                       CGRect(x: 0, y: 0, width: 1280, height: 1080))
    }

    // MARK: - 2. Round to nearest 4-multiple

    func testCommit_TypedW1281_RoundsDownTo1280() {
        // 1281 is closer to 1280 (distance 1) than 1284 (distance 3) —
        // rounds DOWN. (Round-half-up semantic only kicks in at ties.)
        let result = commitCropFieldValue(
            field: .width,
            typedValue: 1281,
            currentRect: fullFrame(),
            sourceWidth: 1920, sourceHeight: 1080)
        XCTAssertEqual(result.correctedValue, 1280)
        XCTAssertTrue(result.wasCorrected)
        XCTAssertEqual(result.updatedRect.width, 1280)
    }

    func testCommit_TypedW1282_TiesRoundUpTo1284() {
        // 1282 is equidistant from 1280 and 1284 — Phase D's
        // round-half-up semantic picks 1284.
        let result = commitCropFieldValue(
            field: .width,
            typedValue: 1282,
            currentRect: fullFrame(),
            sourceWidth: 1920, sourceHeight: 1080)
        XCTAssertEqual(result.correctedValue, 1284)
        XCTAssertTrue(result.wasCorrected)
    }

    // MARK: - 3. Source-bounds clamp (W)

    func testCommit_TypedW5000_ClampsToSourceWidth() {
        // 5000 > sourceWidth (1920). With X=0 the max W is 1920.
        // Already 4-aligned.
        let result = commitCropFieldValue(
            field: .width,
            typedValue: 5000,
            currentRect: fullFrame(),
            sourceWidth: 1920, sourceHeight: 1080)
        XCTAssertEqual(result.correctedValue, 1920)
        XCTAssertTrue(result.wasCorrected)
        XCTAssertEqual(result.updatedRect.width, 1920)
    }

    // MARK: - 4. Minimum clamp (W ≥ 4, negative input)

    func testCommit_TypedW0_ClampsTo4() {
        let result = commitCropFieldValue(
            field: .width,
            typedValue: 0,
            currentRect: fullFrame(),
            sourceWidth: 1920, sourceHeight: 1080)
        XCTAssertEqual(result.correctedValue, 4)
        XCTAssertTrue(result.wasCorrected)
    }

    func testCommit_TypedWNegative100_ClampsTo4() {
        let result = commitCropFieldValue(
            field: .width,
            typedValue: -100,
            currentRect: fullFrame(),
            sourceWidth: 1920, sourceHeight: 1080)
        XCTAssertEqual(result.correctedValue, 4)
        XCTAssertTrue(result.wasCorrected)
    }

    // MARK: - 5. X out of bounds (push past right edge)

    func testCommit_TypedXPastRightEdge_ClampsToMaxX() {
        // Rect width 1200, source 1920 → max X = 1920 - 1200 = 720.
        // Typed X=1000 → 1000 > 720, clamp to 720.
        let rect = CGRect(x: 0, y: 0, width: 1200, height: 720)
        let result = commitCropFieldValue(
            field: .x,
            typedValue: 1000,
            currentRect: rect,
            sourceWidth: 1920, sourceHeight: 1080)
        XCTAssertEqual(result.correctedValue, 720)
        XCTAssertTrue(result.wasCorrected)
        XCTAssertEqual(result.updatedRect,
                       CGRect(x: 720, y: 0, width: 1200, height: 720))
    }

    // MARK: - 6. X negative clamp

    func testCommit_TypedXNegative50_ClampsTo0() {
        let result = commitCropFieldValue(
            field: .x,
            typedValue: -50,
            currentRect: CGRect(x: 400, y: 0, width: 800, height: 600),
            sourceWidth: 1920, sourceHeight: 1080)
        XCTAssertEqual(result.correctedValue, 0,
                       "X has minimum 0 (top-left corner of source)")
        XCTAssertTrue(result.wasCorrected)
    }

    // MARK: - 7. Y mirrors X (smoke)

    func testCommit_TypedYPastBottomEdge_ClampsToMaxY() {
        // Rect height 600, source 1080 → max Y = 1080 - 600 = 480.
        // Typed Y=2000 (already 4-aligned) → clamp to 480.
        let rect = CGRect(x: 0, y: 0, width: 800, height: 600)
        let result = commitCropFieldValue(
            field: .y,
            typedValue: 2000,
            currentRect: rect,
            sourceWidth: 1920, sourceHeight: 1080)
        XCTAssertEqual(result.correctedValue, 480)
        XCTAssertTrue(result.wasCorrected)
    }

    // MARK: - 8. Combined round + clamp

    func testCommit_TypedW4999_RoundsThenClamps() {
        // 4999 rounds to 5000 (((4999+2)/4)*4 = 5000), then clamps to
        // 1920. Single wasCorrected=true; the UI flashes once.
        let result = commitCropFieldValue(
            field: .width,
            typedValue: 4999,
            currentRect: fullFrame(),
            sourceWidth: 1920, sourceHeight: 1080)
        XCTAssertEqual(result.correctedValue, 1920)
        XCTAssertTrue(result.wasCorrected)
    }

    // MARK: - 9. Field isolation

    func testCommit_EditingWidth_DoesNotTouchXYH() {
        let rect = CGRect(x: 320, y: 180, width: 1600, height: 720)
        let result = commitCropFieldValue(
            field: .width,
            typedValue: 800,
            currentRect: rect,
            sourceWidth: 1920, sourceHeight: 1080)
        XCTAssertEqual(result.updatedRect.minX, 320,
                       "X must be byte-equal to currentRect.minX")
        XCTAssertEqual(result.updatedRect.minY, 180,
                       "Y must be byte-equal to currentRect.minY")
        XCTAssertEqual(result.updatedRect.height, 720,
                       "H must be byte-equal to currentRect.height")
        XCTAssertEqual(result.updatedRect.width, 800,
                       "W must be the (uncorrected) typed value 800")
        XCTAssertFalse(result.wasCorrected,
                       "800 is 4-aligned and in bounds against the "
                       + "rect's X=320 (max W = 1920-320=1600)")
    }

    // MARK: - Bonus: dims-unknown fallback (Int.max)

    /// When source dims are temporarily unknown (PreviewArea hasn't
    /// reported yet for the editing job), the UI passes Int.max for
    /// both — round-to-4 + minimum fire, bounds-clamp is suppressed.
    func testCommit_WithIntMaxSourceDims_RoundAndMinFireButBoundsDoNotClamp() {
        let result = commitCropFieldValue(
            field: .width,
            typedValue: 9999,
            currentRect: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            sourceWidth: .max, sourceHeight: .max)
        // 9999 → ((9999+2)/4)*4 = 10000. No bounds clamp (max W is
        // (Int.max - 0)/4*4 which is enormous).
        XCTAssertEqual(result.correctedValue, 10000)
        XCTAssertTrue(result.wasCorrected,
                      "round-to-4 fires even when bounds are disabled")
    }

    // MARK: - Fix-Brief A: nil source dims must NOT disable the clamp
    //
    // The test above documents the DANGER: feeding Int.max disables the
    // source-bounds clamp (10000 accepted on a 1920×1080 source). The fix
    // is caller-side — JobCardView.commitCropField now refuses the edit
    // when dims are unknown instead of substituting Int.max. The
    // `cropClampSourceDims` seam isolates that nil-vs-known decision so it
    // is unit-testable here.

    /// Either axis unknown → nil, so the caller reverts the field rather
    /// than passing the clamp-disabling sentinel.
    func testCropClampSourceDims_NilWhenEitherAxisUnknown() {
        XCTAssertNil(cropClampSourceDims(sourceWidth: nil, sourceHeight: 1080))
        XCTAssertNil(cropClampSourceDims(sourceWidth: 1920, sourceHeight: nil))
        XCTAssertNil(cropClampSourceDims(sourceWidth: nil, sourceHeight: nil))
    }

    /// Both axes known → the dims pass straight through to the clamp.
    func testCropClampSourceDims_PassesThroughKnownDims() {
        let dims = cropClampSourceDims(sourceWidth: 1920, sourceHeight: 1080)
        XCTAssertEqual(dims?.width, 1920)
        XCTAssertEqual(dims?.height, 1080)
    }

    /// Regression pin (the exact human-gate case): with KNOWN dims an
    /// oversize typed width clamps to the source — 2000 on a 1920-wide
    /// source → 1920. Byte-identical to pre-fix behavior.
    func testWidthOversize_ClampsToSource_2000on1920() {
        let r = commitCropFieldValue(
            field: .width, typedValue: 2000,
            currentRect: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            sourceWidth: 1920, sourceHeight: 1080, alignment: 4)
        XCTAssertEqual(r.correctedValue, 1920)
        XCTAssertTrue(r.wasCorrected)
    }

    /// Same pin on the height axis — 2000 on a 1080-tall source → 1080.
    func testHeightOversize_ClampsToSource_2000on1080() {
        let r = commitCropFieldValue(
            field: .height, typedValue: 2000,
            currentRect: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            sourceWidth: 1920, sourceHeight: 1080, alignment: 4)
        XCTAssertEqual(r.correctedValue, 1080)
        XCTAssertTrue(r.wasCorrected)
    }

    // MARK: - Fix-Brief A-2: no commit on empty focus-out (dirty check)
    //
    // A focus-in → focus-out with no typing must commit and seed NOTHING.
    // JobCardView captures the field's string when it gains focus and only
    // commits on blur when it changed (cropFieldDidEdit). These pin the
    // pure decision; the no-commit means commitCropField is never reached,
    // so no fullFrameSeedRect fires and no (0,0,1,H) / full-frame rect is
    // written.

    /// Untouched field (current == focus-gain baseline) → clean → no commit.
    func testCropFieldDidEdit_FalseWhenUnchanged() {
        XCTAssertFalse(cropFieldDidEdit(current: "1920", baseline: "1920"))
    }

    /// The exact bug case: an uncropped row seeded "0" while dims weren't
    /// ready, focused and blurred with no typing → clean → no commit (so
    /// the old roundToAlignMinDim(0,1)=1 + full-frame seed never runs).
    func testCropFieldDidEdit_FalseForSeededZeroUntouched() {
        XCTAssertFalse(cropFieldDidEdit(current: "0", baseline: "0"))
    }

    /// A real edit (typed value differs from baseline) → dirty → commit.
    func testCropFieldDidEdit_TrueWhenUserTyped() {
        XCTAssertTrue(cropFieldDidEdit(current: "500", baseline: "1920"))
    }

    /// Type-then-revert to the original nets no change → clean → no commit.
    func testCropFieldDidEdit_FalseWhenTypedThenReverted() {
        XCTAssertFalse(cropFieldDidEdit(current: "800", baseline: "800"))
    }

    /// Regression pin retained: a dirty edit that DOES commit still clamps
    /// oversize to source (the Brief-A behavior is unchanged by A-2).
    func testDirtyEditStillClampsOversize_2000on1920() {
        XCTAssertTrue(cropFieldDidEdit(current: "2000", baseline: "1920"))
        let r = commitCropFieldValue(
            field: .width, typedValue: 2000,
            currentRect: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            sourceWidth: 1920, sourceHeight: 1080, alignment: 4)
        XCTAssertEqual(r.correctedValue, 1920)
        XCTAssertTrue(r.wasCorrected)
    }
}

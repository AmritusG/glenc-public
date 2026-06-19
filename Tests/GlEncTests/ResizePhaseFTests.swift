/*
 * ResizePhaseFTests — Resize Release Phase F.
 *
 * Phase F is UI (per-row Output Size + Quality menus, defaults row,
 * Custom… sheet). The only piece of non-view logic that ships in
 * Phase F is `roundedToFourPixelMultiple`, the 4-pixel rounding
 * helper invoked by the Custom sheet's commit path.
 *
 * The helper lives in Sources/GlEnc (target GlEnc) — NOT in
 * GlEncCore. Tests import @testable GlEnc to reach it.
 */

import XCTest
@testable import GlEnc

final class RoundedToFourPixelMultipleTests: XCTestCase {

    // MARK: - Spec cases from the Phase F plan

    /// 1281 -> 1280: 1281 is closer to 1280 (Δ1) than 1284 (Δ3).
    func testRoundDownToNearest() {
        XCTAssertEqual(roundedToFourPixelMultiple(1281), 1280)
    }

    /// 1283 -> 1284: 1283 is closer to 1284 (Δ1) than 1280 (Δ3).
    func testRoundUpToNearest() {
        XCTAssertEqual(roundedToFourPixelMultiple(1283), 1284)
    }

    /// 722 -> 724: 722 is closer to 724 (Δ2) than 720 (Δ2) — tie,
    /// rule is round-half-up.
    func testRoundHalfUp() {
        XCTAssertEqual(roundedToFourPixelMultiple(722), 724)
    }

    // MARK: - Already-aligned values

    /// Multiples of 4 must pass through unchanged.
    func testAlreadyAlignedUnchanged() {
        let aligned: [Int] = [4, 8, 16, 320, 720, 1080, 1280, 1920, 2160, 3840, 4096, 16384]
        for n in aligned {
            XCTAssertEqual(roundedToFourPixelMultiple(n), n, "\(n) should pass through unchanged")
        }
    }

    // MARK: - Non-positive input

    /// Spec: n <= 0 clamps to the minimum legal output dim of 4
    /// (the helper is total — callers reject non-positive input
    /// BEFORE calling, but the fallback prevents a crash).
    func testZeroClampsToFour() {
        XCTAssertEqual(roundedToFourPixelMultiple(0), 4)
    }

    func testNegativeClampsToFour() {
        XCTAssertEqual(roundedToFourPixelMultiple(-1), 4)
        XCTAssertEqual(roundedToFourPixelMultiple(-100), 4)
        XCTAssertEqual(roundedToFourPixelMultiple(Int.min), 4)
    }

    // MARK: - Boundary / tie cases

    /// Tie at the half-way point: 2 -> 4 (round-half-up), 6 -> 8.
    /// 1282 is the half-way between 1280 and 1284 → 1284.
    func testHalfwayTiesRoundUp() {
        XCTAssertEqual(roundedToFourPixelMultiple(2), 4)
        XCTAssertEqual(roundedToFourPixelMultiple(6), 8)
        XCTAssertEqual(roundedToFourPixelMultiple(1282), 1284)
    }

    /// Just above an aligned value rounds down.
    func testJustAboveAligned() {
        XCTAssertEqual(roundedToFourPixelMultiple(1281), 1280)
        XCTAssertEqual(roundedToFourPixelMultiple(1921), 1920)
    }

    /// Just below an aligned value rounds up.
    func testJustBelowAligned() {
        XCTAssertEqual(roundedToFourPixelMultiple(1283), 1284)
        XCTAssertEqual(roundedToFourPixelMultiple(1919), 1920)
    }

    /// Smallest positive input (1) clamps to 4 (the minimum legal
    /// 4-multiple). Naive (1+2)/4*4 = 0, which is illegal, so the
    /// helper clamps results below 4 up to 4.
    func testSmallestPositive() {
        XCTAssertEqual(roundedToFourPixelMultiple(1), 4)
    }

    /// 3 -> 4 (closest 4-multiple).
    func testThree() {
        XCTAssertEqual(roundedToFourPixelMultiple(3), 4)
    }

    // MARK: - Common real-world dimensions

    /// Every dim used by the 15 StandardResolution presets must be a
    /// clean 4-multiple, and the rounder must leave them alone.
    func testPresetDimsAllPassThrough() {
        let presetDims: [Int] = [
            // HD / UHD
            720, 1080, 1280, 1440, 1920, 2160, 2560, 3840,
            // DCI Cinema
            2048, 4096,
            // Square
            1024, 1080, 2048,
            // Vertical
            720, 1080, 1280, 1440, 1920, 2560,
        ]
        for n in presetDims {
            XCTAssertEqual(roundedToFourPixelMultiple(n), n,
                           "preset dim \(n) should be 4-aligned and pass through unchanged")
        }
    }
}

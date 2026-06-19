/*
 * CropAspectFitTests — Crop Release Phase C.
 *
 * Pure-math coverage for CropAspectFit's view↔source coordinate
 * mapping: matched aspect, square-into-wide (pillarbox), wide-into-
 * square (letterbox), round-trip identity in both directions,
 * top-left-origin sanity, and unclamped off-fitted-area mapping.
 *
 * One case uses realistic dims (1920×1080 source into an 800×450
 * view) — the v0.9.1 H.3 lesson, restated: exercise the helper at
 * sizes it will actually see.
 */

import XCTest
import Foundation
import CoreGraphics
@testable import GlEncCore

final class CropAspectFitTests: XCTestCase {

    private let accuracy: CGFloat = 0.0001

    // MARK: - 1. Matched aspect

    /// Square source into a square view → fitted rect equals the view
    /// rect exactly, scale is view-width / source-width.
    func testMatchedAspectSquareIntoSquare() {
        let view = CGRect(x: 0, y: 0, width: 400, height: 400)
        let fit = CropAspectFit(sourceWidth: 512, sourceHeight: 512,
                                viewRect: view)
        XCTAssertEqual(fit.fittedViewRect, view)
        XCTAssertEqual(fit.scale, 400.0 / 512.0, accuracy: accuracy)
    }

    // MARK: - 2. Square source into a wide view

    /// Square source in a 16:9 view → centered square, vertical bars
    /// left and right. Fitted height fills the view; fitted width
    /// equals the view height (the square shape).
    func testSquareSourceIntoWideViewPillarboxes() {
        let view = CGRect(x: 0, y: 0, width: 1600, height: 900)
        let fit = CropAspectFit(sourceWidth: 512, sourceHeight: 512,
                                viewRect: view)
        XCTAssertEqual(fit.fittedViewRect.height, view.height,
                       accuracy: accuracy)
        XCTAssertEqual(fit.fittedViewRect.width, view.height,
                       accuracy: accuracy)
        // Centered: equal bars left and right.
        XCTAssertEqual(fit.fittedViewRect.minX,
                       (view.width - view.height) / 2, accuracy: accuracy)
        XCTAssertEqual(fit.fittedViewRect.minY, 0, accuracy: accuracy)
    }

    // MARK: - 3. Wide source into a square view

    /// 16:9 source in a square view → centered horizontal strip,
    /// horizontal bars top and bottom. Fitted width fills the view;
    /// fitted height is view-width × 9/16.
    func testWideSourceIntoSquareViewLetterboxes() {
        let view = CGRect(x: 0, y: 0, width: 600, height: 600)
        let fit = CropAspectFit(sourceWidth: 1920, sourceHeight: 1080,
                                viewRect: view)
        XCTAssertEqual(fit.fittedViewRect.width, view.width,
                       accuracy: accuracy)
        XCTAssertEqual(fit.fittedViewRect.height,
                       view.width * 9.0 / 16.0, accuracy: accuracy)
        XCTAssertEqual(fit.fittedViewRect.minX, 0, accuracy: accuracy)
        XCTAssertEqual(fit.fittedViewRect.minY,
                       (view.height - view.width * 9.0 / 16.0) / 2,
                       accuracy: accuracy)
    }

    // MARK: - 4. Round-trip identity — rect

    /// A source rect through `viewRect(forSourceRect:)` then
    /// `sourceRect(forViewRect:)` returns the original. Realistic
    /// dims: 1920×1080 source into an 800×450 view.
    func testRectRoundTripIdentity() {
        let view = CGRect(x: 12, y: 34, width: 800, height: 450)
        let fit = CropAspectFit(sourceWidth: 1920, sourceHeight: 1080,
                                viewRect: view)
        let original = CGRect(x: 320, y: 180, width: 640, height: 360)
        let roundTrip = fit.sourceRect(
            forViewRect: fit.viewRect(forSourceRect: original))
        XCTAssertEqual(roundTrip.minX, original.minX, accuracy: accuracy)
        XCTAssertEqual(roundTrip.minY, original.minY, accuracy: accuracy)
        XCTAssertEqual(roundTrip.width, original.width, accuracy: accuracy)
        XCTAssertEqual(roundTrip.height, original.height, accuracy: accuracy)
    }

    // MARK: - 5. Round-trip identity — point

    /// A view point inside `fittedViewRect` through
    /// `sourcePoint(forViewPoint:)` then `viewPoint(forSourcePoint:)`
    /// returns the original point.
    func testPointRoundTripIdentity() {
        let view = CGRect(x: 0, y: 0, width: 1600, height: 900)
        let fit = CropAspectFit(sourceWidth: 512, sourceHeight: 512,
                                viewRect: view)
        // A point comfortably inside the centered fitted square.
        let original = CGPoint(x: 700, y: 400)
        XCTAssertTrue(fit.fittedViewRect.contains(original),
                      "test point must lie inside the fitted rect")
        let roundTrip = fit.viewPoint(
            forSourcePoint: fit.sourcePoint(forViewPoint: original))
        XCTAssertEqual(roundTrip.x, original.x, accuracy: accuracy)
        XCTAssertEqual(roundTrip.y, original.y, accuracy: accuracy)
    }

    // MARK: - 6. Top-left origin sanity

    /// Source `(0, 0)` maps to the TOP-LEFT of the fitted area, not
    /// the bottom-left. The origin-convention check (CROP_PLAN.md Q2).
    func testTopLeftOriginMapping() {
        let view = CGRect(x: 0, y: 0, width: 600, height: 600)
        let fit = CropAspectFit(sourceWidth: 1920, sourceHeight: 1080,
                                viewRect: view)
        let topLeft = fit.viewPoint(forSourcePoint: CGPoint(x: 0, y: 0))
        XCTAssertEqual(topLeft.x, fit.fittedViewRect.minX, accuracy: accuracy)
        XCTAssertEqual(topLeft.y, fit.fittedViewRect.minY, accuracy: accuracy)
        // The bottom-left source corner maps BELOW the top — proving
        // y increases downward (no flip).
        let bottomLeft = fit.viewPoint(
            forSourcePoint: CGPoint(x: 0, y: 1080))
        XCTAssertGreaterThan(bottomLeft.y, topLeft.y)
        XCTAssertEqual(bottomLeft.y, fit.fittedViewRect.maxY,
                       accuracy: accuracy)
    }

    // MARK: - 7. Off-fitted-area mapping is defined

    /// A view point inside a letterbox bar maps to a source point
    /// with a component outside `[0, sourceDim)`. The helper does not
    /// clamp; it must still return a finite value and not crash.
    func testOffFittedAreaMapsOutsideSourceBounds() {
        let view = CGRect(x: 0, y: 0, width: 600, height: 600)
        let fit = CropAspectFit(sourceWidth: 1920, sourceHeight: 1080,
                                viewRect: view)
        // (300, 50): horizontally centered, but y=50 is above the
        // fitted strip's top edge → inside the top letterbox bar.
        let inBar = CGPoint(x: 300, y: 50)
        XCTAssertFalse(fit.fittedViewRect.contains(inBar),
                       "test point must lie in a letterbox bar")
        let src = fit.sourcePoint(forViewPoint: inBar)
        XCTAssertTrue(src.y.isFinite && src.x.isFinite,
                      "off-area mapping must stay finite")
        XCTAssertLessThan(src.y, 0,
                          "a point above the fitted area maps to negative source y")
    }

    // MARK: - 8. Degenerate inputs

    /// Zero source dims (a clip not yet loaded) → zero fit, zero
    /// scale, zero-producing mapping. No divide-by-zero, no trap.
    func testDegenerateInputsYieldZero() {
        let view = CGRect(x: 0, y: 0, width: 800, height: 450)
        let noSource = CropAspectFit(sourceWidth: 0, sourceHeight: 0,
                                     viewRect: view)
        XCTAssertEqual(noSource.fittedViewRect, .zero)
        XCTAssertEqual(noSource.scale, 0)
        XCTAssertEqual(noSource.sourcePoint(forViewPoint: CGPoint(x: 10, y: 10)),
                       .zero)

        let emptyView = CropAspectFit(sourceWidth: 1920, sourceHeight: 1080,
                                      viewRect: .zero)
        XCTAssertEqual(emptyView.fittedViewRect, .zero)
        XCTAssertEqual(emptyView.scale, 0)
    }
}

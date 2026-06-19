/*
 * CropDragMathTests — Crop Release Phase D.
 *
 * Headless coverage for the pure drag math behind CropOverlayView:
 * corner resize (each of the four corners, opposite-corner-fixed),
 * the past-opposite-corner 4-px collapse, out-of-bounds clamp,
 * non-4-aligned input snap, and interior translation clamped to all
 * four source edges.
 *
 * SwiftUI gestures / @State / layout are NOT covered here — that is
 * the CropOverlayView preview harness + the post-Phase-E human
 * click-test (the v0.9.4 Phase H Bug 5 lesson: only the extracted
 * pure functions are headlessly testable).
 *
 * Source dims are 1920×1080 throughout — realistic, per the v0.9.1
 * H.3 lesson.
 */

import XCTest
import Foundation
import CoreGraphics
@testable import GlEnc

final class CropDragMathTests: XCTestCase {

    private let accuracy: CGFloat = 0.0001
    private let srcW = 1920
    private let srcH = 1080

    // MARK: - snappedResizedRect — per corner

    /// Dragging the top-left corner inward: top-left moves, the
    /// bottom-right corner is held fixed, width/height shrink.
    func testResizeTopLeftInward() {
        let original = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let r = CropDragMath.snappedResizedRect(
            original: original, draggedCorner: .topLeft,
            newCornerSourcePoint: CGPoint(x: 200, y: 100),
            sourceWidth: srcW, sourceHeight: srcH)
        XCTAssertEqual(r.minX, 200, accuracy: accuracy)
        XCTAssertEqual(r.minY, 100, accuracy: accuracy)
        // Bottom-right unchanged.
        XCTAssertEqual(r.maxX, 1920, accuracy: accuracy)
        XCTAssertEqual(r.maxY, 1080, accuracy: accuracy)
        XCTAssertEqual(r.width, 1720, accuracy: accuracy)
        XCTAssertEqual(r.height, 980, accuracy: accuracy)
    }

    /// Dragging the bottom-right corner outward: bottom-right moves,
    /// the top-left corner is held fixed.
    func testResizeBottomRightOutward() {
        let original = CGRect(x: 200, y: 100, width: 1000, height: 600)
        let r = CropDragMath.snappedResizedRect(
            original: original, draggedCorner: .bottomRight,
            newCornerSourcePoint: CGPoint(x: 1400, y: 800),
            sourceWidth: srcW, sourceHeight: srcH)
        // Top-left unchanged.
        XCTAssertEqual(r.minX, 200, accuracy: accuracy)
        XCTAssertEqual(r.minY, 100, accuracy: accuracy)
        XCTAssertEqual(r.maxX, 1400, accuracy: accuracy)
        XCTAssertEqual(r.maxY, 800, accuracy: accuracy)
    }

    /// Dragging the top-right corner: bottom-left corner is fixed.
    func testResizeTopRightOppositeFixed() {
        let original = CGRect(x: 200, y: 100, width: 1000, height: 600)
        let r = CropDragMath.snappedResizedRect(
            original: original, draggedCorner: .topRight,
            newCornerSourcePoint: CGPoint(x: 1300, y: 48),
            sourceWidth: srcW, sourceHeight: srcH)
        // Bottom-left (minX, maxY) unchanged.
        XCTAssertEqual(r.minX, 200, accuracy: accuracy)
        XCTAssertEqual(r.maxY, 700, accuracy: accuracy)
        XCTAssertEqual(r.maxX, 1300, accuracy: accuracy)
        XCTAssertEqual(r.minY, 48, accuracy: accuracy)
    }

    /// Dragging the bottom-left corner: top-right corner is fixed.
    func testResizeBottomLeftOppositeFixed() {
        let original = CGRect(x: 200, y: 100, width: 1000, height: 600)
        let r = CropDragMath.snappedResizedRect(
            original: original, draggedCorner: .bottomLeft,
            newCornerSourcePoint: CGPoint(x: 300, y: 900),
            sourceWidth: srcW, sourceHeight: srcH)
        // Top-right (maxX, minY) unchanged.
        XCTAssertEqual(r.maxX, 1200, accuracy: accuracy)
        XCTAssertEqual(r.minY, 100, accuracy: accuracy)
        XCTAssertEqual(r.minX, 300, accuracy: accuracy)
        XCTAssertEqual(r.maxY, 900, accuracy: accuracy)
    }

    // MARK: - snappedResizedRect — clamps and snapping

    /// Dragging a corner PAST the opposite corner collapses the rect
    /// to the 4-pixel minimum at the boundary — no inversion, no
    /// negative dimensions.
    func testResizeDragPastOppositeCollapsesToFourPxFloor() {
        let original = CGRect(x: 200, y: 100, width: 1000, height: 600)
        // Drag top-left far past the fixed bottom-right (1200, 700).
        let r = CropDragMath.snappedResizedRect(
            original: original, draggedCorner: .topLeft,
            newCornerSourcePoint: CGPoint(x: 5000, y: 5000),
            sourceWidth: srcW, sourceHeight: srcH)
        XCTAssertEqual(r.width, 4, accuracy: accuracy)
        XCTAssertEqual(r.height, 4, accuracy: accuracy)
        XCTAssertGreaterThanOrEqual(r.width, 0)
        XCTAssertGreaterThanOrEqual(r.height, 0)
        // Collapsed against the fixed bottom-right corner.
        XCTAssertEqual(r.maxX, 1200, accuracy: accuracy)
        XCTAssertEqual(r.maxY, 700, accuracy: accuracy)
    }

    /// Dragging a corner outside source bounds clamps to the source
    /// bounds; the result stays 4-pixel-aligned.
    func testResizeDragOutsideBoundsClamps() {
        let original = CGRect(x: 200, y: 100, width: 1000, height: 600)
        let r = CropDragMath.snappedResizedRect(
            original: original, draggedCorner: .topLeft,
            newCornerSourcePoint: CGPoint(x: -80, y: -40),
            sourceWidth: srcW, sourceHeight: srcH)
        XCTAssertEqual(r.minX, 0, accuracy: accuracy)
        XCTAssertEqual(r.minY, 0, accuracy: accuracy)
        XCTAssertEqual(Int(r.width.rounded()) % 4, 0)
        XCTAssertEqual(Int(r.height.rounded()) % 4, 0)
    }

    /// A non-4-aligned dragged point is snapped to the nearest
    /// 4-multiple (ties round up, per `roundedToFourPixelMultiple`).
    func testResizeSnapsNonAlignedInput() {
        let original = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let r = CropDragMath.snappedResizedRect(
            original: original, draggedCorner: .topLeft,
            newCornerSourcePoint: CGPoint(x: 101.7, y: 50.3),
            sourceWidth: srcW, sourceHeight: srcH)
        // 101.7 → 102 → nearest 4 = 104; 50.3 → 50 → nearest 4 = 52.
        XCTAssertEqual(r.minX, 104, accuracy: accuracy)
        XCTAssertEqual(r.minY, 52, accuracy: accuracy)
    }

    // MARK: - snappedTranslatedRect

    /// Translating by a non-4-aligned delta snaps the new origin to a
    /// 4-multiple; width and height are unchanged.
    func testTranslateSnapsNonAlignedToFourPx() {
        let original = CGRect(x: 100, y: 100, width: 400, height: 200)
        let r = CropDragMath.snappedTranslatedRect(
            original: original,
            translationInSource: CGSize(width: 7, height: 3),
            sourceWidth: srcW, sourceHeight: srcH)
        // 100+7=107 → 108; 100+3=103 → 104.
        XCTAssertEqual(r.minX, 108, accuracy: accuracy)
        XCTAssertEqual(r.minY, 104, accuracy: accuracy)
        XCTAssertEqual(r.width, 400, accuracy: accuracy)
        XCTAssertEqual(r.height, 200, accuracy: accuracy)
    }

    /// Translating off the left edge clamps `x` to 0; width unchanged.
    func testTranslateOffLeftClampsToZero() {
        let original = CGRect(x: 100, y: 100, width: 400, height: 200)
        let r = CropDragMath.snappedTranslatedRect(
            original: original,
            translationInSource: CGSize(width: -500, height: 0),
            sourceWidth: srcW, sourceHeight: srcH)
        XCTAssertEqual(r.minX, 0, accuracy: accuracy)
        XCTAssertEqual(r.width, 400, accuracy: accuracy)
    }

    /// Translating off the right edge clamps so `x + width` equals the
    /// source width.
    func testTranslateOffRightClampsToBounds() {
        let original = CGRect(x: 100, y: 100, width: 400, height: 200)
        let r = CropDragMath.snappedTranslatedRect(
            original: original,
            translationInSource: CGSize(width: 5000, height: 0),
            sourceWidth: srcW, sourceHeight: srcH)
        XCTAssertEqual(r.maxX, CGFloat(srcW), accuracy: accuracy)
        XCTAssertEqual(r.width, 400, accuracy: accuracy)
    }

    /// Translating off the top edge clamps `y` to 0.
    func testTranslateOffTopClampsToZero() {
        let original = CGRect(x: 100, y: 100, width: 400, height: 200)
        let r = CropDragMath.snappedTranslatedRect(
            original: original,
            translationInSource: CGSize(width: 0, height: -500),
            sourceWidth: srcW, sourceHeight: srcH)
        XCTAssertEqual(r.minY, 0, accuracy: accuracy)
        XCTAssertEqual(r.height, 200, accuracy: accuracy)
    }

    /// Translating off the bottom edge clamps so `y + height` equals
    /// the source height.
    func testTranslateOffBottomClampsToBounds() {
        let original = CGRect(x: 100, y: 100, width: 400, height: 200)
        let r = CropDragMath.snappedTranslatedRect(
            original: original,
            translationInSource: CGSize(width: 0, height: 5000),
            sourceWidth: srcW, sourceHeight: srcH)
        XCTAssertEqual(r.maxY, CGFloat(srcH), accuracy: accuracy)
        XCTAssertEqual(r.height, 200, accuracy: accuracy)
    }

    // MARK: - snappedResizeFromCorner (Phase E.10 — arrow-key resize)

    /// Top-left + delta (-4, -4): top-left moves up-left by 4px each,
    /// bottom-right unchanged. Rect grows by 4px on left + top edges.
    func testCornerResize_TopLeft_MoveLeftAndUp() {
        let r = CropDragMath.snappedResizeFromCorner(
            rect: CGRect(x: 320, y: 180, width: 1280, height: 720),
            corner: .topLeft,
            delta: CGVector(dx: -4, dy: -4),
            sourceWidth: srcW, sourceHeight: srcH)
        XCTAssertEqual(r, CGRect(x: 316, y: 176, width: 1284, height: 724))
    }

    /// Top-right + delta (+4, -4): right edge moves out, top edge moves
    /// up; minX and bottom edge unchanged.
    func testCornerResize_TopRight_MoveRightAndUp() {
        let r = CropDragMath.snappedResizeFromCorner(
            rect: CGRect(x: 320, y: 180, width: 1280, height: 720),
            corner: .topRight,
            delta: CGVector(dx: 4, dy: -4),
            sourceWidth: srcW, sourceHeight: srcH)
        XCTAssertEqual(r, CGRect(x: 320, y: 176, width: 1284, height: 724))
    }

    /// Bottom-left + delta (-4, +4): minX decreases, maxY increases.
    func testCornerResize_BottomLeft_MoveLeftAndDown() {
        let r = CropDragMath.snappedResizeFromCorner(
            rect: CGRect(x: 320, y: 180, width: 1280, height: 720),
            corner: .bottomLeft,
            delta: CGVector(dx: -4, dy: 4),
            sourceWidth: srcW, sourceHeight: srcH)
        XCTAssertEqual(r, CGRect(x: 316, y: 180, width: 1284, height: 724))
    }

    /// Bottom-right + delta (+4, +4): rect grows on right + bottom.
    func testCornerResize_BottomRight_MoveRightAndDown() {
        let r = CropDragMath.snappedResizeFromCorner(
            rect: CGRect(x: 320, y: 180, width: 1280, height: 720),
            corner: .bottomRight,
            delta: CGVector(dx: 4, dy: 4),
            sourceWidth: srcW, sourceHeight: srcH)
        XCTAssertEqual(r, CGRect(x: 320, y: 180, width: 1284, height: 724))
    }

    /// Non-4-aligned delta snaps to nearest 4-multiple (round-half-up
    /// inherited from `snapCoordinate`).
    func testCornerResize_SnapToFourPx() {
        // bottom-right + (3, 3): 1600+3=1603 → snaps to 1604;
        // 900+3=903 → snaps to 904.
        let r = CropDragMath.snappedResizeFromCorner(
            rect: CGRect(x: 320, y: 180, width: 1280, height: 720),
            corner: .bottomRight,
            delta: CGVector(dx: 3, dy: 3),
            sourceWidth: srcW, sourceHeight: srcH)
        XCTAssertEqual(r, CGRect(x: 320, y: 180, width: 1284, height: 724))
    }

    /// Top-left dragged off the source clamps to (0, 0); bottom-right
    /// unchanged. Inherits `snappedResizedRect`'s source-bounds clamp.
    func testCornerResize_ClampToSourceBounds_TopLeft() {
        let r = CropDragMath.snappedResizeFromCorner(
            rect: CGRect(x: 4, y: 4, width: 1280, height: 720),
            corner: .topLeft,
            delta: CGVector(dx: -100, dy: -100),
            sourceWidth: srcW, sourceHeight: srcH)
        XCTAssertEqual(r, CGRect(x: 0, y: 0, width: 1284, height: 724))
    }

    /// Dragging top-left past the opposite (bottom-right) corner
    /// collapses to the 4-px floor at the opposite corner. The rect
    /// can't invert.
    func testCornerResize_ClampToOppositeEdge() {
        // bottom-right is at (1280, 720). Top-left delta (+10000,
        // +10000) wants to move it way past — clamp to (1276, 716)
        // so rect = 4×4 at the bottom-right corner.
        let r = CropDragMath.snappedResizeFromCorner(
            rect: CGRect(x: 0, y: 0, width: 1280, height: 720),
            corner: .topLeft,
            delta: CGVector(dx: 10000, dy: 10000),
            sourceWidth: srcW, sourceHeight: srcH)
        XCTAssertEqual(r, CGRect(x: 1276, y: 716, width: 4, height: 4))
    }

    /// Top-left moves; the bottom-right corner's source coordinates
    /// (maxX, maxY) must be byte-equal to the original's.
    func testCornerResize_OppositeCornerStaysFixed_TopLeft() {
        let original = CGRect(x: 320, y: 180, width: 1280, height: 720)
        // original.maxX = 1600, original.maxY = 900.
        let r = CropDragMath.snappedResizeFromCorner(
            rect: original,
            corner: .topLeft,
            delta: CGVector(dx: 16, dy: 8),
            sourceWidth: srcW, sourceHeight: srcH)
        XCTAssertEqual(r.maxX, 1600,
                       "bottom-right's X must not move when topLeft is dragged")
        XCTAssertEqual(r.maxY, 900,
                       "bottom-right's Y must not move when topLeft is dragged")
    }

    /// Bottom-right moves; the top-left corner's source coordinates
    /// (minX, minY) must be byte-equal to the original's.
    func testCornerResize_OppositeCornerStaysFixed_BottomRight() {
        let original = CGRect(x: 320, y: 180, width: 1280, height: 720)
        let r = CropDragMath.snappedResizeFromCorner(
            rect: original,
            corner: .bottomRight,
            delta: CGVector(dx: 16, dy: 8),
            sourceWidth: srcW, sourceHeight: srcH)
        XCTAssertEqual(r.minX, 320,
                       "top-left's X must not move when bottomRight is dragged")
        XCTAssertEqual(r.minY, 180,
                       "top-left's Y must not move when bottomRight is dragged")
    }

    // MARK: - fullFrameSeedRect

    /// For a 4-pixel-aligned source the seed rect is exactly the
    /// source frame at the origin.
    func testFullFrameSeedRectIsExactSourceForAlignedDims() {
        let r = CropDragMath.fullFrameSeedRect(sourceWidth: srcW,
                                               sourceHeight: srcH)
        XCTAssertEqual(r, CGRect(x: 0, y: 0, width: 1920, height: 1080))
    }
}

/*
 * CropBadgeFormatTests — Crop Release Phase E.7.
 *
 * Headless coverage for `JobCardView.formatCropBadge`, the pure
 * formatter behind the rowCrop badge. Two display modes:
 *
 *   - Passive (this row is NOT the editing row): dims-only "WxH",
 *     or "—  (no crop)" when uncropped — the long-standing badge
 *     shape introduced in Phase G.
 *   - Live (this row IS the editing row, Phase E.7): dims +
 *     position "WxH @ (X, Y)" derived from queue.pendingCropRect
 *     so the user can read the rect's exact coordinates during
 *     drag / keyboard nudge — or "—  (no crop yet)" between Edit
 *     click and first placement.
 *
 * The formatter is the entire surface area E.7 changes; SwiftUI
 * @Published triggers re-render on every pendingCropRect tick, so
 * the UI behaviour falls out for free once the formatter is right.
 * Click-test covers gesture wiring (v0.9.4 Phase H Bug 5: tests
 * verify the formatter, the eye verifies the binding).
 */

import XCTest
import CoreGraphics
@testable import GlEnc

final class CropBadgeFormatTests: XCTestCase {

    /// Passive mode, uncropped job: neutral dash placeholder.
    func testCropBadge_NotEditing_NoCommittedCrop_ReturnsStaticDash() {
        let s = JobCardView.formatCropBadge(
            pendingCropRect: nil,
            committedCropRect: nil,
            isEditing: false)
        XCTAssertEqual(s, "—  (no crop)")
    }

    /// Passive mode, cropped job: dims only, no position, no @.
    func testCropBadge_NotEditing_WithCommittedCrop_ReturnsDimsOnly() {
        let s = JobCardView.formatCropBadge(
            pendingCropRect: nil,
            committedCropRect: CGRect(x: 0, y: 0, width: 1280, height: 720),
            isEditing: false)
        XCTAssertEqual(s, "1280x720")
    }

    /// Edit mode, no rect placed yet: "yet"-disambiguated dash
    /// distinguishes "in edit, no rect" from passive "no crop".
    func testCropBadge_Editing_NoPendingRect_ReturnsEditDash() {
        let s = JobCardView.formatCropBadge(
            pendingCropRect: nil,
            committedCropRect: nil,
            isEditing: true)
        XCTAssertEqual(s, "—  (no crop yet)")
    }

    /// Edit mode, rect placed: live "WxH @ (X, Y)" format.
    func testCropBadge_Editing_WithPendingRect_ReturnsLiveFormat() {
        let s = JobCardView.formatCropBadge(
            pendingCropRect: CGRect(x: 320, y: 180, width: 1280, height: 720),
            committedCropRect: nil,
            isEditing: true)
        XCTAssertEqual(s, "1280x720 @ (320, 180)")
    }

    /// Edit mode, top-left crop: position rendered as "(0, 0)".
    func testCropBadge_Editing_PositionAtOrigin() {
        let s = JobCardView.formatCropBadge(
            pendingCropRect: CGRect(x: 0, y: 0, width: 800, height: 800),
            committedCropRect: nil,
            isEditing: true)
        XCTAssertEqual(s, "800x800 @ (0, 0)")
    }

    /// Edit mode, fractional input: rounds defensively to nearest
    /// integer for display (pipeline-side validation guarantees
    /// integer dims at apply-time; this is belt-and-braces).
    func testCropBadge_Editing_FractionalRectRoundsCleanly() {
        let s = JobCardView.formatCropBadge(
            pendingCropRect: CGRect(x: 320.4, y: 180.6, width: 1280.2, height: 720.8),
            committedCropRect: nil,
            isEditing: true)
        XCTAssertEqual(s, "1280x721 @ (320, 181)")
    }

    /// Edit mode wins over committed: pending drives the display,
    /// even when a different committed rect exists.
    func testCropBadge_EditingState_ShadowsCommitted() {
        let s = JobCardView.formatCropBadge(
            pendingCropRect: CGRect(x: 0, y: 0, width: 100, height: 100),
            committedCropRect: CGRect(x: 0, y: 0, width: 200, height: 200),
            isEditing: true)
        XCTAssertEqual(s, "100x100 @ (0, 0)")
    }
}

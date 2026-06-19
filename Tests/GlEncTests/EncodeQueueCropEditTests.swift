/*
 * EncodeQueueCropEditTests — Crop Release Phase E.
 *
 * Headless coverage for the crop-edit state machine on EncodeQueue
 * (`cropEditingJobID` / `pendingCropRect` + beginCropEdit /
 * applyCropEdit / cancelCropEdit).
 *
 * What these tests CAN validate — and do:
 *   - beginCropEdit sets the editing-job id and seeds the pending
 *     rect from the target job's committed cropRect (incl. the nil
 *     case for an uncropped job),
 *   - applyCropEdit commits pendingCropRect onto the job and clears
 *     both edit fields,
 *   - cancelCropEdit clears both fields and leaves the job's
 *     committed cropRect untouched (whatever it was — a rect or nil),
 *   - serialized edit (Q3): beginCropEdit on a second row while a
 *     first is editing cancels the first,
 *   - the collapsed-preview-pane state (Q9) is saved on begin and
 *     restored on apply / cancel.
 *
 * What they CANNOT validate (per the v0.9.4 Phase H "Bug 5" rule):
 *   the CropOverlayView rendering, dim mask, focused-state border,
 *   drag gestures, and keyboard nudge are SwiftUI-binding and
 *   view-layout dependent — the SwiftUI preview harness and the
 *   human click-test are their gates, not this file.
 *
 * AppSettings note: beginCropEdit/endCropEdit read and write
 * `AppSettings.shared.previewPaneVisibleByDefault` (the only
 * collapsed-pane state in the app). setUp/tearDown reset the shared
 * singleton so these mutations do not leak into the xctest tool's
 * persistent UserDefaults domain — same guard EncodeQueueTests uses.
 */

import XCTest
import Foundation
import CoreGraphics
@testable import GlEnc
@testable import GlEncCore

@MainActor
final class EncodeQueueCropEditTests: XCTestCase {

    override func setUp() {
        super.setUp()
        AppSettings.shared.resetToDefaults()
    }
    override func tearDown() {
        AppSettings.shared.resetToDefaults()
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeJob(crop: CGRect? = nil) -> EncodeJob {
        EncodeJob(sourceURL: URL(fileURLWithPath: "/tmp/glenc-crop-test.mov"),
                  cropRect: crop)
    }

    // MARK: - beginCropEdit

    func testBeginCropEditSetsEditingIDAndSeedsFromJob() {
        let queue = EncodeQueue()
        let crop = CGRect(x: 400, y: 200, width: 800, height: 600)
        let job = makeJob(crop: crop)
        queue.jobs = [job]

        queue.beginCropEdit(jobID: job.id)

        XCTAssertEqual(queue.cropEditingJobID, job.id,
                       "beginCropEdit must mark the target row as editing")
        XCTAssertEqual(queue.pendingCropRect, crop,
                       "pendingCropRect must be seeded from the job's cropRect")
    }

    func testBeginCropEditSeedsNilFromUncroppedJob() {
        let queue = EncodeQueue()
        let job = makeJob(crop: nil)
        queue.jobs = [job]

        queue.beginCropEdit(jobID: job.id)

        XCTAssertEqual(queue.cropEditingJobID, job.id)
        XCTAssertNil(queue.pendingCropRect,
                     "An uncropped job seeds a nil pending rect — the "
                     + "overlay seeds a full-frame rect on first drag")
    }

    func testBeginCropEditOnUnknownIDIsNoOp() {
        let queue = EncodeQueue()
        queue.jobs = [makeJob()]

        queue.beginCropEdit(jobID: UUID())

        XCTAssertNil(queue.cropEditingJobID,
                     "beginCropEdit on an id not in the queue must not "
                     + "enter edit mode")
    }

    // MARK: - applyCropEdit

    func testApplyCropEditCommitsPendingRectAndClears() {
        let queue = EncodeQueue()
        let job = makeJob(crop: nil)
        queue.jobs = [job]

        queue.beginCropEdit(jobID: job.id)
        let edited = CGRect(x: 0, y: 0, width: 1280, height: 720)
        queue.pendingCropRect = edited
        queue.applyCropEdit()

        XCTAssertEqual(queue.jobs[0].cropRect, edited,
                       "applyCropEdit must write pendingCropRect onto "
                       + "the job's committed cropRect")
        XCTAssertNil(queue.cropEditingJobID, "edit mode must clear on apply")
        XCTAssertNil(queue.pendingCropRect, "pending rect must clear on apply")
    }

    // MARK: - cancelCropEdit

    func testCancelCropEditDiscardsEditAndPreservesOriginalRect() {
        let queue = EncodeQueue()
        let original = CGRect(x: 100, y: 100, width: 640, height: 480)
        let job = makeJob(crop: original)
        queue.jobs = [job]

        queue.beginCropEdit(jobID: job.id)
        // Simulate a drag that moved the pending rect somewhere else.
        queue.pendingCropRect = CGRect(x: 0, y: 0, width: 320, height: 240)
        queue.cancelCropEdit()

        XCTAssertEqual(queue.jobs[0].cropRect, original,
                       "cancelCropEdit must leave the committed cropRect "
                       + "exactly as it was before begin")
        XCTAssertNil(queue.cropEditingJobID, "edit mode must clear on cancel")
        XCTAssertNil(queue.pendingCropRect, "pending rect must clear on cancel")
    }

    func testCancelCropEditPreservesNilOriginalForUncroppedJob() {
        let queue = EncodeQueue()
        let job = makeJob(crop: nil)
        queue.jobs = [job]

        queue.beginCropEdit(jobID: job.id)
        queue.pendingCropRect = CGRect(x: 0, y: 0, width: 800, height: 600)
        queue.cancelCropEdit()

        XCTAssertNil(queue.jobs[0].cropRect,
                     "cancelCropEdit on a job that had no crop must leave "
                     + "it uncropped")
    }

    // MARK: - clearCropEdit (Phase E.8)

    func testClearCropEdit_SetsCommittedCropRectToNil() {
        let queue = EncodeQueue()
        let original = CGRect(x: 0, y: 0, width: 1280, height: 720)
        let job = makeJob(crop: original)
        queue.jobs = [job]

        queue.beginCropEdit(jobID: job.id)
        queue.clearCropEdit()

        XCTAssertNil(queue.jobs[0].cropRect,
                     "clearCropEdit must remove the committed cropRect")
        XCTAssertNil(queue.cropEditingJobID,
                     "edit mode must clear on clear (shared endCropEdit teardown)")
        XCTAssertNil(queue.pendingCropRect,
                     "pending rect must clear on clear (shared endCropEdit teardown)")
    }

    func testClearCropEdit_OnJobWithNoCommittedCrop_NoOpSemantics() {
        let queue = EncodeQueue()
        let job = makeJob(crop: nil)
        queue.jobs = [job]

        queue.beginCropEdit(jobID: job.id)
        queue.clearCropEdit()

        XCTAssertNil(queue.jobs[0].cropRect,
                     "clearCropEdit on a job that had no crop must leave "
                     + "the committed cropRect nil (no crash, no surprise)")
        XCTAssertNil(queue.cropEditingJobID, "edit state must clear cleanly")
        XCTAssertNil(queue.pendingCropRect, "pending must clear cleanly")
    }

    /// Pins the "Clear ≠ Cancel + remove" semantic: even when the
    /// user has dragged the pending rect to a different shape during
    /// the edit, Clear removes the ORIGINAL committed value, not the
    /// in-flight pending. This is the unconditional contract.
    func testClearCropEdit_IgnoresInFlightPending() {
        let queue = EncodeQueue()
        let original = CGRect(x: 0, y: 0, width: 1280, height: 720)
        let inFlight = CGRect(x: 100, y: 100, width: 800, height: 600)
        let job = makeJob(crop: original)
        queue.jobs = [job]

        queue.beginCropEdit(jobID: job.id)
        // User dragged to a different rect mid-edit but never clicked Apply.
        queue.pendingCropRect = inFlight
        queue.clearCropEdit()

        XCTAssertNil(queue.jobs[0].cropRect,
                     "clearCropEdit must remove the ORIGINAL committed "
                     + "cropRect, not replace it with the in-flight pending")
        XCTAssertNil(queue.cropEditingJobID)
        XCTAssertNil(queue.pendingCropRect)
    }

    // MARK: - Serialized edit (CROP_PLAN.md Q3)

    func testBeginCropEditOnSecondRowSerializesByCancellingFirst() {
        let queue = EncodeQueue()
        let cropA = CGRect(x: 10, y: 10, width: 200, height: 200)
        let cropB = CGRect(x: 20, y: 20, width: 400, height: 400)
        let jobA = makeJob(crop: cropA)
        let jobB = makeJob(crop: cropB)
        queue.jobs = [jobA, jobB]

        queue.beginCropEdit(jobID: jobA.id)
        // Move A's pending rect, then jump to editing B without
        // applying — the first edit must be silently cancelled.
        queue.pendingCropRect = CGRect(x: 0, y: 0, width: 999, height: 999)
        queue.beginCropEdit(jobID: jobB.id)

        XCTAssertEqual(queue.cropEditingJobID, jobB.id,
                       "the second beginCropEdit takes over the edit")
        XCTAssertEqual(queue.pendingCropRect, cropB,
                       "pending rect must reseed from the new target (B)")
        XCTAssertEqual(queue.jobs[0].cropRect, cropA,
                       "row A's committed cropRect must be untouched — its "
                       + "in-flight edit was discarded, not applied")
    }

    // MARK: - Collapsed-pane handling (CROP_PLAN.md Q9)

    func testCollapsedPanePriorStateRestoredOnApplyAndCancel() {
        let queue = EncodeQueue()
        let job = makeJob()
        queue.jobs = [job]

        // Pane starts collapsed.
        AppSettings.shared.previewPaneVisibleByDefault = false

        queue.beginCropEdit(jobID: job.id)
        XCTAssertTrue(AppSettings.shared.previewPaneVisibleByDefault,
                      "beginCropEdit must force-expand a collapsed pane")

        queue.applyCropEdit()
        XCTAssertFalse(AppSettings.shared.previewPaneVisibleByDefault,
                       "applyCropEdit must restore the pane's prior "
                       + "(collapsed) state")

        // Same for cancel.
        AppSettings.shared.previewPaneVisibleByDefault = false
        queue.beginCropEdit(jobID: job.id)
        XCTAssertTrue(AppSettings.shared.previewPaneVisibleByDefault)
        queue.cancelCropEdit()
        XCTAssertFalse(AppSettings.shared.previewPaneVisibleByDefault,
                       "cancelCropEdit must restore the prior pane state")
    }

    func testExpandedPaneStaysExpandedAcrossEdit() {
        let queue = EncodeQueue()
        let job = makeJob()
        queue.jobs = [job]

        // Pane already visible — begin/cancel must leave it visible.
        AppSettings.shared.previewPaneVisibleByDefault = true
        queue.beginCropEdit(jobID: job.id)
        XCTAssertTrue(AppSettings.shared.previewPaneVisibleByDefault)
        queue.cancelCropEdit()
        XCTAssertTrue(AppSettings.shared.previewPaneVisibleByDefault,
                      "an already-expanded pane must remain expanded "
                      + "after the edit ends")
    }
}

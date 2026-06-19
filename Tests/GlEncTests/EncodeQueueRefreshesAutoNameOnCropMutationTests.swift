/*
 * EncodeQueueRefreshesAutoNameOnCropMutationTests — Crop Release
 * Phase G.2.
 *
 * Phase G added the AutoNameEngine `[WxH]` crop token; Phase G.1
 * wired the two EncodeJob suggestedName call sites to forward the
 * job's cropRect to the engine. The Arena gate then surfaced a
 * THIRD gap one layer up: when the user clicks Apply on the crop
 * overlay, EncodeQueue.applyCropEdit mutates jobs[i].cropRect, but
 * the job's outputName — already computed at construction time
 * when cropRect was nil — was NOT refreshed. Same gap for
 * clearCropEdit (token should disappear when going back to nil).
 *
 * G.2's fix is a single refreshAutoNameIfNeeded call after each
 * cropRect mutation in EncodeQueue's apply/clear methods. This
 * file is the regression test that the calls actually happen.
 *
 * Discriminator
 * ─────────────
 * Both tests construct a job (or set its cropRect) and then
 * exercise the EncodeQueue path that mutates cropRect.
 *
 *   - testApplyCropEdit: starts with cropRect = nil, drives a
 *     pendingCropRect → applyCropEdit. The job's outputName must
 *     gain the `[1280x720]` token.
 *   - testClearCropEdit: starts with cropRect set (so outputName
 *     already carries the token), drives beginCropEdit →
 *     clearCropEdit. The job's outputName must lose the token.
 *
 * Verified discriminative — with the two refreshAutoNameIfNeeded
 * call sites removed from EncodeQueue, both tests FAIL with the
 * diagnostic messages below; with the calls restored, both PASS.
 *
 * The override-gate behavior (Phase 8C-b) is unchanged: a
 * manually-renamed job is left alone. That guard lives inside
 * refreshAutoNameIfNeeded and is exercised by other test files.
 */

import XCTest
import Foundation
import CoreGraphics
@testable import GlEnc
@testable import GlEncCore

@MainActor
final class EncodeQueueRefreshesAutoNameOnCropMutationTests: XCTestCase {

    override func setUp() {
        super.setUp()
        AppSettings.shared.resetToDefaults()
    }
    override func tearDown() {
        AppSettings.shared.resetToDefaults()
        super.tearDown()
    }

    /// Fixture source URL with a known stem so the expected
    /// token substring is unambiguous regardless of the rest of the
    /// auto-name format.
    private func srcURL(_ filename: String = "Clip.mov") -> URL {
        URL(fileURLWithPath: "/Users/test/Movies/\(filename)")
    }

    /// Apply path: a job constructed with cropRect = nil starts
    /// without the [WxH] token. After applyCropEdit, the committed
    /// cropRect is set AND the auto-name must be refreshed so the
    /// token appears in outputName.
    func testApplyCropEdit_RefreshesOutputNameToContainCropToken() {
        let queue = EncodeQueue()
        var job = EncodeJob(sourceURL: srcURL(), format: .dxt1)
        // Pre-condition: no token yet.
        XCTAssertFalse(
            job.outputName.contains("[1280x720]"),
            "pre-condition: fresh job with cropRect == nil must "
            + "not carry the [WxH] token; got \"\(job.outputName)\"")
        queue.jobs = [job]

        queue.beginCropEdit(jobID: job.id)
        queue.pendingCropRect = CGRect(x: 320, y: 180, width: 1280, height: 720)
        queue.applyCropEdit()

        XCTAssertTrue(
            queue.jobs[0].outputName.contains("[1280x720]"),
            "outputName=\"\(queue.jobs[0].outputName)\" did not "
            + "contain \"[1280x720]\" after applyCropEdit. "
            + "EncodeQueue.applyCropEdit is not refreshing the "
            + "auto-name after cropRect mutation (the Phase G.2 gap).")
        // Sanity: committed cropRect actually moved (so we're
        // not just lucking out on an unmutated job).
        XCTAssertEqual(
            queue.jobs[0].cropRect,
            CGRect(x: 320, y: 180, width: 1280, height: 720),
            "sanity: applyCropEdit should still commit the pending rect")
        // Suppress the unused-var warning on `job` (we kept the
        // local for the pre-condition assertion).
        _ = job
    }

    /// Clear path: a job constructed with cropRect set already
    /// carries the [WxH] token. After clearCropEdit, the committed
    /// cropRect goes nil AND the auto-name must be refreshed so the
    /// token disappears.
    func testClearCropEdit_RefreshesOutputNameToRemoveCropToken() {
        let queue = EncodeQueue()
        let job = EncodeJob(
            sourceURL: srcURL(),
            format: .dxt1,
            cropRect: CGRect(x: 320, y: 180, width: 1280, height: 720))
        // Pre-condition: token present (proves G.1 is in place and
        // the test isn't lucking into a stem that happens to lack
        // the substring).
        XCTAssertTrue(
            job.outputName.contains("[1280x720]"),
            "pre-condition: a job constructed with cropRect set must "
            + "carry the [WxH] token; got \"\(job.outputName)\" — "
            + "if this fails, Phase G.1's forwards are not in place "
            + "and G.2's test cannot be reasoned about")
        queue.jobs = [job]

        queue.beginCropEdit(jobID: job.id)
        queue.clearCropEdit()

        XCTAssertFalse(
            queue.jobs[0].outputName.contains("[1280x720]"),
            "outputName=\"\(queue.jobs[0].outputName)\" still "
            + "contains \"[1280x720]\" after clearCropEdit. "
            + "EncodeQueue.clearCropEdit is not refreshing the "
            + "auto-name after cropRect mutation (the Phase G.2 gap).")
        // Sanity: committed cropRect was actually cleared.
        XCTAssertNil(
            queue.jobs[0].cropRect,
            "sanity: clearCropEdit should leave the committed cropRect nil")
    }
}

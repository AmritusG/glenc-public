/*
 * EncodeJobForwardsCropRectToAutoNameTests — Crop Release Phase G.1.
 *
 * Phase G added the `cropRect:` parameter to AutoNameEngine.
 * suggestedName and proved the `[WxH]` token correct via 5 byte-
 * exact engine unit tests, but the two suggestedName call sites in
 * EncodeJob.swift (init + setOutputNameAuto) did not forward
 * `cropRect`. G.1 adds the forwards; this file is the regression
 * test that proves they actually happen.
 *
 * Discriminator
 * ─────────────
 * `EncodeJob.outputName` is set by both call sites. With the G.1
 * forwards in place, constructing a job with a non-nil cropRect
 * produces an outputName containing the engine's `[WxH]` token. With
 * the forwards reverted, the same construction produces a name
 * WITHOUT the token (the engine receives the parameter default of
 * nil and emits no token).
 *
 * Verified discriminative — with both G.1 forward lines removed the
 * test FAILS with the diagnostic message embedded in the assertion;
 * with the forwards in place it PASSES. See the commit message.
 *
 * The complementary nil-cropRect test guards against an accidental
 * "always tag with full-source-dims" refactor (the engine's own
 * Phase G test #5 guards the engine side; this file guards the job-
 * level side).
 */

import XCTest
import Foundation
import CoreGraphics
@testable import GlEnc
@testable import GlEncCore

@MainActor
final class EncodeJobForwardsCropRectToAutoNameTests: XCTestCase {

    override func setUp() {
        super.setUp()
        AppSettings.shared.resetToDefaults()
    }
    override func tearDown() {
        AppSettings.shared.resetToDefaults()
        super.tearDown()
    }

    /// Fixture source URL with a known stem ("Clip") so the expected
    /// token substring is unambiguous regardless of the rest of the
    /// auto-name format.
    private func srcURL(_ filename: String = "Clip.mov") -> URL {
        URL(fileURLWithPath: "/Users/test/Movies/\(filename)")
    }

    // MARK: - Forward path

    func testEncodeJob_WithCropRect_OutputNameContainsToken() {
        let job = EncodeJob(
            sourceURL: srcURL(),
            format: .dxt1,
            cropRect: CGRect(x: 320, y: 180, width: 1280, height: 720))
        XCTAssertTrue(
            job.outputName.contains("[1280x720]"),
            "outputName=\"\(job.outputName)\" did not contain "
            + "\"[1280x720]\". If this token is missing, EncodeJob is "
            + "not forwarding cropRect to AutoNameEngine.suggestedName "
            + "(the Phase G.1 gap).")
    }

    /// Refresh path: a job whose cropRect is set AFTER construction
    /// and then re-auto-named via setOutputNameAuto must also pick up
    /// the token. Covers the second of the two forward call sites
    /// (init covers the first).
    func testEncodeJob_SetCropRectThenRefresh_OutputNameContainsToken() {
        var job = EncodeJob(sourceURL: srcURL(), format: .dxt1)
        // Sanity: before setting cropRect, no token.
        XCTAssertFalse(job.outputName.contains("[1280x720]"),
                       "pre-condition: fresh job must not carry the token")
        job.cropRect = CGRect(x: 320, y: 180, width: 1280, height: 720)
        job.setOutputNameAuto()
        XCTAssertTrue(
            job.outputName.contains("[1280x720]"),
            "outputName=\"\(job.outputName)\" did not contain "
            + "\"[1280x720]\" after setOutputNameAuto with cropRect "
            + "set. If this token is missing, setOutputNameAuto is "
            + "not forwarding cropRect to AutoNameEngine.suggestedName "
            + "(the Phase G.1 gap, refresh path).")
    }

    // MARK: - Nil path (resize asymmetry / no-op default)

    /// Guards against an accidental "always tag with full-source-dims"
    /// refactor. The engine's own Phase G test #5 covers the
    /// engine-direct case; this file pins the EncodeJob-level
    /// behavior — a job with `cropRect == nil` must produce the
    /// pre-Phase-G no-token output exactly.
    func testEncodeJob_WithNilCropRect_OutputNameHasNoCropToken() {
        let job = EncodeJob(sourceURL: srcURL(), format: .dxt1)
        XCTAssertEqual(
            job.outputName, "Clip_DXV Normal Quality.mov",
            "a job with cropRect == nil must produce the byte-exact "
            + "pre-Phase-G output; got \"\(job.outputName)\"")
    }
}

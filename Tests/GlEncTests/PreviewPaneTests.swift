/*
 * PreviewPaneTests — Phase 8B-b unit coverage.
 *
 * Covers the data-model side: selection state in EncodeQueue (auto-
 * select on first add, preserved on remove-other, moved-to-neighbor
 * on remove-selected, cleared on remove-last), EncodeJob.previewSide
 * default, and PreviewPosterLoader's variant routing.
 *
 * The poster loader DXV3 path is exercised against the committed
 * reference/<variant>/glenc.mov fixtures. The non-DXV3 path is gated
 * behind a small AVFoundation fixture that we synthesize in the
 * test's temp dir.
 *
 * The PreviewPane SwiftUI view itself isn't unit-tested directly —
 * SwiftUI view bodies are validated at the integration / GUI smoke
 * level. The data-model + loader together cover all the non-view
 * logic that determines what the pane shows.
 */

import XCTest
import CoreGraphics
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
@testable import GlEnc
@testable import GlEncCore

@MainActor
final class PreviewPaneTests: XCTestCase {

    private func makeURL(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/glenc-preview-test-\(name).mov")
    }

    // MARK: - Selection state

    func testSelection_FirstJobSelectedOnAdd() {
        let queue = EncodeQueue()
        XCTAssertNil(queue.selectedJobID, "fresh queue starts with no selection")
        queue.addJobs(urls: [makeURL("a")])
        XCTAssertEqual(queue.selectedJobID, queue.jobs.first?.id,
                       "first add into an empty queue must auto-select the new row")
    }

    func testSelection_NotChangedOnSubsequentAdd() {
        let queue = EncodeQueue()
        queue.addJobs(urls: [makeURL("a")])
        let firstID = queue.jobs[0].id
        queue.addJobs(urls: [makeURL("b"), makeURL("c")])
        XCTAssertEqual(queue.selectedJobID, firstID,
                       "subsequent adds must not steal selection from the user's existing pick")
    }

    func testSelection_PreservedOnRemoveOther() {
        let queue = EncodeQueue()
        queue.addJobs(urls: [makeURL("a"), makeURL("b"), makeURL("c")])
        let middleID = queue.jobs[1].id
        queue.selectedJobID = middleID
        // Remove the first row (not the selected one).
        queue.removeJob(id: queue.jobs[0].id)
        XCTAssertEqual(queue.selectedJobID, middleID,
                       "removing an unselected row must preserve the current selection")
    }

    func testSelection_MovesToNeighborOnRemoveSelected_Middle() {
        let queue = EncodeQueue()
        queue.addJobs(urls: [makeURL("a"), makeURL("b"), makeURL("c")])
        let middleID = queue.jobs[1].id
        let successorID = queue.jobs[2].id
        queue.selectedJobID = middleID
        queue.removeJob(id: middleID)
        XCTAssertEqual(queue.selectedJobID, successorID,
                       "removing the selected row mid-queue moves selection to the successor")
    }

    func testSelection_MovesToPredecessorOnRemoveSelected_Tail() {
        let queue = EncodeQueue()
        queue.addJobs(urls: [makeURL("a"), makeURL("b"), makeURL("c")])
        let tailID = queue.jobs[2].id
        let predID = queue.jobs[1].id
        queue.selectedJobID = tailID
        queue.removeJob(id: tailID)
        XCTAssertEqual(queue.selectedJobID, predID,
                       "removing the selected tail row falls back to the predecessor")
    }

    func testSelection_ClearedWhenQueueEmpties() {
        let queue = EncodeQueue()
        queue.addJobs(urls: [makeURL("a")])
        queue.removeJob(id: queue.jobs[0].id)
        XCTAssertNil(queue.selectedJobID, "removing the last row clears selection")
    }

    // MARK: - PreviewSide

    func testPreviewSideDefault() {
        let job = EncodeJob(sourceURL: makeURL("a"))
        XCTAssertEqual(job.previewSide, .source,
                       "freshly-added jobs default to source-side preview")
    }

    // MARK: - PreviewPosterLoader — DXV3 route

    func testPosterLoad_DXT1Source() throws {
        let url = try referenceFixtureURL(variant: "dxt1")
        let cg = try PreviewPosterLoader.loadPoster(for: url)
        XCTAssertGreaterThan(cg.width, 0)
        XCTAssertGreaterThan(cg.height, 0)
    }

    func testPosterLoad_DXT5Source() throws {
        let url = try referenceFixtureURL(variant: "dxt5")
        let cg = try PreviewPosterLoader.loadPoster(for: url)
        XCTAssertGreaterThan(cg.width, 0)
        XCTAssertGreaterThan(cg.height, 0)
    }

    func testPosterLoad_YCG6Source() throws {
        let url = try referenceFixtureURL(variant: "ycg6")
        let cg = try PreviewPosterLoader.loadPoster(for: url)
        XCTAssertGreaterThan(cg.width, 0)
        XCTAssertGreaterThan(cg.height, 0)
    }

    func testPosterLoad_YG10Source() throws {
        let url = try referenceFixtureURL(variant: "yg10")
        let cg = try PreviewPosterLoader.loadPoster(for: url)
        XCTAssertGreaterThan(cg.width, 0)
        XCTAssertGreaterThan(cg.height, 0)
    }

    // MARK: - PreviewPosterLoader — non-DXV3 route

    /// Synthesize a tiny .mp4 on disk and confirm the loader pulls a
    /// frame back via AVAssetImageGenerator. Exercises the
    /// non-DXV3 branch of the routing.
    func testPosterLoad_NonDXV3Source() async throws {
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("glenc-preview-non-dxv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let outURL = tmpDir.appendingPathComponent("blob.mp4")
        try await writeTrivialH264(at: outURL, width: 320, height: 180, frames: 5)
        let cg = try PreviewPosterLoader.loadPoster(for: outURL)
        XCTAssertGreaterThan(cg.width, 0)
        XCTAssertGreaterThan(cg.height, 0)
    }

    // MARK: - PreviewPlayerModel — Phase 8B-c

    /// Loading a DXV3 source populates the model's published state
    /// (totalFrames, sourceWidth/Height, frameRate). Doesn't assert
    /// playback ticks; CVDisplayLink may not fire in headless
    /// XCTest. The state-machine side is what we cover here.
    func testPlayerModel_LoadsDXV3() async throws {
        let model = PreviewPlayerModel()
        let url = try referenceFixtureURL(variant: "dxt1")
        model.load(url: url)
        XCTAssertGreaterThan(model.totalFrames, 0)
        XCTAssertGreaterThan(model.sourceWidth, 0)
        XCTAssertGreaterThan(model.sourceHeight, 0)
        XCTAssertGreaterThan(model.frameRate, 0)
        // .playing on success (auto-play). Either flag can win the
        // race depending on whether the FrameClock has had a vsync
        // yet; both are valid post-load states.
        switch model.playState {
        case .playing, .paused: break
        default:
            XCTFail("expected .playing or .paused after load, got \(model.playState)")
        }
        XCTAssertEqual(model.currentURL, url)
    }

    /// Loading a HAP source (HapM) routes to the new `.hap` backend arm
    /// (HAPPlayer), not the DXV or AV backend. Covers HAP detection +
    /// backend selection without pixels; the RGBA-to-screen path is the
    /// manual visual gate. Fixture: reference/hapm/test-hapm.mov.
    func testPlayerModel_LoadsHAP() async throws {
        let url = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("reference")
            .appendingPathComponent("hapm")
            .appendingPathComponent("test-hapm.mov")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: url.path),
            "HAP fixture reference/hapm/test-hapm.mov missing")

        let model = PreviewPlayerModel()
        model.load(url: url)

        // The decisive assertion: HAP must pick the .hap arm, NOT fall
        // to DXV (can't decode HAP) or AV (no macOS HAP codec → blank).
        if case .hap = model.backendKind {
            // expected
        } else {
            XCTFail("HAP source must select .hap backend, got \(model.backendKind)")
        }
        XCTAssertGreaterThan(model.totalFrames, 0)
        XCTAssertGreaterThan(model.sourceWidth, 0)
        XCTAssertGreaterThan(model.sourceHeight, 0)
        XCTAssertGreaterThan(model.frameRate, 0)
        switch model.playState {
        case .playing, .paused: break
        default:
            XCTFail("expected .playing or .paused after HAP load, got \(model.playState)")
        }
        XCTAssertEqual(model.currentURL, url)
    }

    /// Helper: reference/<sub>/<name> URL.
    private func referenceURL(_ sub: String, _ name: String) -> URL {
        URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("reference")
            .appendingPathComponent(sub)
            .appendingPathComponent(name)
    }

    /// HAS-AUDIO: a HAP file with a decodable audio track selects the
    /// audio-master path (`audioMaster == true`). The full transport
    /// (play → pause → seek → stop/unload) runs without crashing.
    /// Fixture: reference/hap-audio/sample-with-audio.mov (HapM video +
    /// AAC tone, ffmpeg -c:v copy remux — video bytes unchanged).
    func testPlayerModel_HAP_HasAudio_AudioMaster() async throws {
        let url = referenceURL("hap-audio", "sample-with-audio.mov")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path),
                          "HAP+audio fixture missing")
        let model = PreviewPlayerModel()
        model.load(url: url)
        if case .hap = model.backendKind {} else {
            XCTFail("HAP+audio must select .hap backend, got \(model.backendKind)")
        }
        XCTAssertTrue(model.audioMaster, "HAP with an audio track must be audio-master")
        XCTAssertGreaterThan(model.totalFrames, 0)
        // Transport must not crash in audio-master mode.
        model.play()
        model.pause()
        model.seek(to: max(0, model.totalFrames / 2))
        model.unload()
        XCTAssertEqual(model.playState, .empty)
    }

    /// NO-AUDIO: a video-only HAP stays on the silent clock-master path
    /// (`audioMaster == false`), and all transport runs without crash.
    /// Fixture: reference/hapm/test-hapm.mov (no audio track).
    func testPlayerModel_HAP_NoAudio_ClockMasterSilent() async throws {
        let url = referenceURL("hapm", "test-hapm.mov")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path),
                          "video-only HAP fixture missing")
        let model = PreviewPlayerModel()
        model.load(url: url)
        if case .hap = model.backendKind {} else {
            XCTFail("video-only HAP must select .hap backend, got \(model.backendKind)")
        }
        XCTAssertFalse(model.audioMaster, "video-only HAP must NOT be audio-master")
        XCTAssertGreaterThan(model.totalFrames, 0)
        model.play()
        model.pause()
        model.seek(to: max(0, model.totalFrames / 2))
        model.step(by: 1)
        model.unload()
        XCTAssertEqual(model.playState, .empty)
    }

    func testPlayerModel_LoadInvalidURL() async throws {
        let model = PreviewPlayerModel()
        let bogus = URL(fileURLWithPath: "/nonexistent/glenc-preview-bogus.mov")
        model.load(url: bogus)
        // Phase v0.9.0-fix — non-DXV3 sources route through the
        // async AVPlaybackBackend factory; .failed lands after the
        // asset-load Task completes. Poll briefly.
        for _ in 0..<50 {
            if case .failed = model.playState { break }
            try await Task.sleep(nanoseconds: 20_000_000)  // 20 ms
        }
        if case .failed = model.playState {
            // expected
        } else {
            XCTFail("expected .failed for invalid URL, got \(model.playState)")
        }
        XCTAssertEqual(model.totalFrames, 0)
    }

    func testPlayerModel_PauseAfterLoad() async throws {
        let model = PreviewPlayerModel()
        model.load(url: try referenceFixtureURL(variant: "dxt1"))
        model.pause()
        XCTAssertEqual(model.playState, .paused)
    }

    func testPlayerModel_TogglePause() async throws {
        let model = PreviewPlayerModel()
        model.load(url: try referenceFixtureURL(variant: "dxt5"))
        let before = model.playState
        model.togglePause()
        let after = model.playState
        // States must be different after a single toggle.
        XCTAssertNotEqual(before, after,
                          "togglePause must invert the play state")
    }

    func testPlayerModel_SeekUpdatesCurrentFrame() async throws {
        let model = PreviewPlayerModel()
        model.load(url: try referenceFixtureURL(variant: "ycg6"))
        model.seek(to: 5)
        // Frame mirrors into the model's @Published on seek.
        XCTAssertEqual(model.currentFrame, 5)
    }

    func testPlayerModel_SeekClampedToTotalRange() async throws {
        let model = PreviewPlayerModel()
        model.load(url: try referenceFixtureURL(variant: "yg10"))
        // Past the end clamps to totalFrames - 1.
        model.seek(to: 100_000)
        XCTAssertEqual(model.currentFrame, model.totalFrames - 1)
        // Negative clamps to 0.
        model.seek(to: -10)
        XCTAssertEqual(model.currentFrame, 0)
    }

    func testPlayerModel_UnloadResetsState() async throws {
        let model = PreviewPlayerModel()
        model.load(url: try referenceFixtureURL(variant: "dxt1"))
        XCTAssertGreaterThan(model.totalFrames, 0)
        model.unload()
        XCTAssertEqual(model.playState, .empty)
        XCTAssertEqual(model.totalFrames, 0)
        XCTAssertEqual(model.sourceWidth, 0)
        XCTAssertEqual(model.sourceHeight, 0)
        XCTAssertNil(model.currentURL)
    }

    // MARK: - PreviewPlayerModel — Phase 8B-d transport

    func testPlayerModel_StepBy() async throws {
        let model = PreviewPlayerModel()
        model.load(url: try referenceFixtureURL(variant: "dxt1"))
        model.seek(to: 5)
        XCTAssertEqual(model.currentFrame, 5)

        model.step(by: 1)
        XCTAssertEqual(model.currentFrame, 6)
        // Step always pauses — single-frame inspection contract.
        XCTAssertEqual(model.playState, .paused)

        model.step(by: -3)
        XCTAssertEqual(model.currentFrame, 3)
        XCTAssertEqual(model.playState, .paused)
    }

    func testPlayerModel_StepClamped() async throws {
        let model = PreviewPlayerModel()
        model.load(url: try referenceFixtureURL(variant: "dxt1"))
        model.seek(to: 0)
        model.step(by: -1)
        XCTAssertEqual(model.currentFrame, 0,
                       "step backward from frame 0 must clamp to 0")

        let last = model.totalFrames - 1
        model.seek(to: last)
        model.step(by: 1)
        XCTAssertEqual(model.currentFrame, last,
                       "step forward from last frame must clamp to last")
    }

    func testPlayerModel_StepNoOpWhenNoPlayer() async throws {
        let model = PreviewPlayerModel()
        // Never loaded — step should be a no-op, not crash.
        model.step(by: 1)
        XCTAssertEqual(model.currentFrame, 0)
        XCTAssertEqual(model.playState, .empty)
    }

    func testPlayerModel_LoopToggleDefault() {
        let model = PreviewPlayerModel()
        XCTAssertTrue(model.loopEnabled,
                      "loop defaults to true for VJ-style preview")
    }

    func testPlayerModel_LoopToggleMutates() {
        let model = PreviewPlayerModel()
        model.loopEnabled = false
        XCTAssertFalse(model.loopEnabled)
        model.loopEnabled = true
        XCTAssertTrue(model.loopEnabled)
    }

    /// Toggling loopEnabled after a load must reach the underlying
    /// FrameClock — the player otherwise wouldn't notice the change.
    /// We can't directly inspect the clock from the model's external
    /// API; instead, verify the model's published state stays in sync
    /// and that setting it before load takes effect on the next load
    /// (via the wirePlayer pass-through).
    func testPlayerModel_LoopPersistsAcrossLoads() throws {
        let model = PreviewPlayerModel()
        model.loopEnabled = false
        model.load(url: try referenceFixtureURL(variant: "dxt1"))
        XCTAssertFalse(model.loopEnabled,
                       "loop preference must survive across load")
        model.unload()
        XCTAssertFalse(model.loopEnabled,
                       "loop preference must survive across unload")
    }

    // MARK: - EncodeJob trim helpers (Phase 8C-a)

    func testEncodeJob_DefaultsNoTrim() {
        let job = EncodeJob(sourceURL: makeURL("a"))
        XCTAssertNil(job.inFrame)
        XCTAssertNil(job.outFrame)
        XCTAssertFalse(job.isTrimmed)
    }

    func testEncodeJob_IsTrimmedWhenEitherSet() {
        var job = EncodeJob(sourceURL: makeURL("a"))
        XCTAssertFalse(job.isTrimmed)
        job.inFrame = 10
        XCTAssertTrue(job.isTrimmed)
        job.inFrame = nil
        job.outFrame = 50
        XCTAssertTrue(job.isTrimmed)
        job.outFrame = nil
        XCTAssertFalse(job.isTrimmed)
    }

    func testResolvedTrimRange_NoTrim() {
        let job = EncodeJob(sourceURL: makeURL("a"))
        let (lo, hi) = job.resolvedTrimRange(totalFrames: 100)
        XCTAssertEqual(lo, 0)
        XCTAssertEqual(hi, 99)
    }

    func testResolvedTrimRange_OnlyIn() {
        var job = EncodeJob(sourceURL: makeURL("a"))
        job.inFrame = 20
        let (lo, hi) = job.resolvedTrimRange(totalFrames: 100)
        XCTAssertEqual(lo, 20)
        XCTAssertEqual(hi, 99)
    }

    func testResolvedTrimRange_OnlyOut() {
        var job = EncodeJob(sourceURL: makeURL("a"))
        job.outFrame = 50
        let (lo, hi) = job.resolvedTrimRange(totalFrames: 100)
        XCTAssertEqual(lo, 0)
        XCTAssertEqual(hi, 50)
    }

    func testResolvedTrimRange_BothInsideRange() {
        var job = EncodeJob(sourceURL: makeURL("a"))
        job.inFrame = 20
        job.outFrame = 50
        let (lo, hi) = job.resolvedTrimRange(totalFrames: 100)
        XCTAssertEqual(lo, 20)
        XCTAssertEqual(hi, 50)
    }

    func testResolvedTrimRange_ClampedToBounds() {
        var job = EncodeJob(sourceURL: makeURL("a"))
        job.inFrame = -5
        job.outFrame = 200
        let (lo, hi) = job.resolvedTrimRange(totalFrames: 100)
        XCTAssertEqual(lo, 0)
        XCTAssertEqual(hi, 99)
    }

    func testResolvedTrimRange_SwappedNormalized() {
        var job = EncodeJob(sourceURL: makeURL("a"))
        job.inFrame = 50
        job.outFrame = 20
        let (lo, hi) = job.resolvedTrimRange(totalFrames: 100)
        XCTAssertEqual(lo, 20)
        XCTAssertEqual(hi, 50)
    }

    func testResolvedTrimRange_EmptyClip() {
        let job = EncodeJob(sourceURL: makeURL("a"))
        let (lo, hi) = job.resolvedTrimRange(totalFrames: 0)
        XCTAssertEqual(lo, 0)
        XCTAssertEqual(hi, 0)
    }

    // MARK: - PreviewPlayerModel trim — Phase 8C-a

    func testPlayerModel_TrimDefaultsNil() {
        let model = PreviewPlayerModel()
        XCTAssertNil(model.inFrame)
        XCTAssertNil(model.outFrame)
    }

    func testPlayerModel_SetInAtCurrentFrame() async throws {
        let model = PreviewPlayerModel()
        model.load(url: try referenceFixtureURL(variant: "dxt1"))
        model.seek(to: 10)
        model.setInAtCurrentFrame()
        XCTAssertEqual(model.inFrame, 10)
        XCTAssertNil(model.outFrame)
    }

    func testPlayerModel_SetOutAtCurrentFrame() async throws {
        let model = PreviewPlayerModel()
        model.load(url: try referenceFixtureURL(variant: "dxt1"))
        model.seek(to: 20)
        model.setOutAtCurrentFrame()
        XCTAssertEqual(model.outFrame, 20)
        XCTAssertNil(model.inFrame)
    }

    /// Setting in past existing out must snap out forward to match
    /// (preserves in ≤ out invariant without losing user intent).
    func testPlayerModel_SetInSnapsOutForward() async throws {
        let model = PreviewPlayerModel()
        model.load(url: try referenceFixtureURL(variant: "dxt1"))
        model.seek(to: 5)
        model.setOutAtCurrentFrame()
        XCTAssertEqual(model.outFrame, 5)
        // Now move playhead past out and set in there.
        model.seek(to: 20)
        model.setInAtCurrentFrame()
        XCTAssertEqual(model.inFrame, 20)
        XCTAssertEqual(model.outFrame, 20,
                       "out must snap forward to match new in when in > out")
    }

    /// Symmetric: setting out before existing in must snap in backward.
    func testPlayerModel_SetOutSnapsInBackward() async throws {
        let model = PreviewPlayerModel()
        model.load(url: try referenceFixtureURL(variant: "dxt1"))
        model.seek(to: 20)
        model.setInAtCurrentFrame()
        model.seek(to: 5)
        model.setOutAtCurrentFrame()
        XCTAssertEqual(model.outFrame, 5)
        XCTAssertEqual(model.inFrame, 5,
                       "in must snap backward to match new out when out < in")
    }

    func testPlayerModel_ClearTrim() async throws {
        let model = PreviewPlayerModel()
        model.load(url: try referenceFixtureURL(variant: "dxt1"))
        model.seek(to: 10); model.setInAtCurrentFrame()
        model.seek(to: 20); model.setOutAtCurrentFrame()
        XCTAssertNotNil(model.inFrame)
        XCTAssertNotNil(model.outFrame)
        model.clearTrim()
        XCTAssertNil(model.inFrame)
        XCTAssertNil(model.outFrame)
    }

    func testPlayerModel_SetTrimNoOpWhenNoPlayer() {
        let model = PreviewPlayerModel()
        // Never loaded — setIn/setOut should silently no-op rather
        // than write trim against a phantom currentFrame=0.
        model.setInAtCurrentFrame()
        XCTAssertNil(model.inFrame)
        model.setOutAtCurrentFrame()
        XCTAssertNil(model.outFrame)
    }

    /// Phase 4.1c — `unload()` PRESERVES trim (was: reset it). The reset
    /// propagated back to the selected job on re-selection and wiped the
    /// saved trim. Trim is per-clip state owned by the EncodeJob; the
    /// explicit `clearTrim()` user action is the only thing that drops it.
    func testPlayerModel_UnloadPreservesTrim() async throws {
        let model = PreviewPlayerModel()
        model.load(url: try referenceFixtureURL(variant: "dxt1"))
        model.seek(to: 5); model.setInAtCurrentFrame()
        model.seek(to: 10); model.setOutAtCurrentFrame()
        model.unload()
        XCTAssertEqual(model.inFrame, 5, "unload must preserve the in-point (job is source of truth)")
        XCTAssertEqual(model.outFrame, 10, "unload must preserve the out-point")
        model.clearTrim()
        XCTAssertNil(model.inFrame)
        XCTAssertNil(model.outFrame)
    }

    // MARK: - Trim playback semantics — Phase 8C-a-fix

    /// Pressing play with playhead past outFrame snaps to inFrame.
    func testPlayerModel_PlayOutsideTrim_SnapsToInFrame() async throws {
        let model = PreviewPlayerModel()
        model.load(url: try referenceFixtureURL(variant: "dxt1"))
        model.inFrame = 5
        model.outFrame = 15
        model.pause()
        model.seek(to: 25)
        XCTAssertEqual(model.currentFrame, 25)
        model.play()
        // play() runs the snap synchronously before starting the
        // underlying clock, so the published currentFrame must now
        // be at inFrame.
        XCTAssertEqual(model.currentFrame, 5,
                       "play with playhead > out must snap to in")
    }

    /// Pressing play with playhead before inFrame snaps to inFrame.
    func testPlayerModel_PlayBeforeInFrame_SnapsToInFrame() async throws {
        let model = PreviewPlayerModel()
        model.load(url: try referenceFixtureURL(variant: "dxt1"))
        model.inFrame = 10
        model.outFrame = 20
        model.pause()
        model.seek(to: 2)
        model.play()
        XCTAssertEqual(model.currentFrame, 10,
                       "play with playhead < in must snap to in")
    }

    /// Pressing play with playhead inside trim does NOT snap.
    func testPlayerModel_PlayInsideTrim_NoSnap() async throws {
        let model = PreviewPlayerModel()
        model.load(url: try referenceFixtureURL(variant: "dxt1"))
        model.inFrame = 5
        model.outFrame = 25
        model.pause()
        model.seek(to: 15)
        model.play()
        XCTAssertEqual(model.currentFrame, 15,
                       "play inside trim must not snap the playhead")
    }

    /// togglePause from paused→playing also snaps. Mirrors play()'s
    /// contract since Space triggers togglePause.
    func testPlayerModel_TogglePauseFromPaused_SnapsToInFrame() async throws {
        let model = PreviewPlayerModel()
        model.load(url: try referenceFixtureURL(variant: "dxt1"))
        model.inFrame = 7
        model.outFrame = 12
        model.pause()
        model.seek(to: 28)
        model.togglePause()
        XCTAssertEqual(model.currentFrame, 7,
                       "togglePause from paused outside trim must snap to in")
    }

    /// togglePause from playing→paused does NOT snap (no use of the
    /// snap; the user is intentionally pausing where they're at).
    func testPlayerModel_TogglePauseFromPlaying_DoesNotSnap() async throws {
        let model = PreviewPlayerModel()
        model.load(url: try referenceFixtureURL(variant: "dxt1"))
        // No trim — toggling pause anywhere should leave playhead alone.
        model.pause()
        model.seek(to: 10)
        model.play()
        XCTAssertEqual(model.currentFrame, 10)
        model.togglePause()  // playing → paused
        XCTAssertEqual(model.currentFrame, 10,
                       "pausing must not move the playhead")
    }

    /// No trim → no snap on play, ever.
    func testPlayerModel_NoTrim_PlayUnchanged() async throws {
        let model = PreviewPlayerModel()
        model.load(url: try referenceFixtureURL(variant: "dxt1"))
        XCTAssertNil(model.inFrame)
        XCTAssertNil(model.outFrame)
        model.pause()
        model.seek(to: 20)
        model.play()
        XCTAssertEqual(model.currentFrame, 20,
                       "no trim must not snap the playhead")
    }

    /// Trim with only outFrame set — playhead at 0 (before implicit
    /// lo=0) needs no snap; playhead past out → snap to lo=0.
    func testPlayerModel_PlayOnlyOutTrim() async throws {
        let model = PreviewPlayerModel()
        model.load(url: try referenceFixtureURL(variant: "dxt1"))
        model.outFrame = 10
        // inFrame implicit 0; playhead at 0 is inside [0, 10].
        model.pause()
        model.seek(to: 0)
        model.play()
        XCTAssertEqual(model.currentFrame, 0,
                       "play at 0 inside implicit [0, outFrame] must not snap")
        // Now scrub past out and play.
        model.pause()
        model.seek(to: 20)
        model.play()
        XCTAssertEqual(model.currentFrame, 0,
                       "play past out with only-out trim must snap to lo=0")
    }

    func testPlayerModel_LoadReplacesPreviousPlayer() async throws {
        let model = PreviewPlayerModel()
        model.load(url: try referenceFixtureURL(variant: "dxt1"))
        let firstTotal = model.totalFrames
        XCTAssertGreaterThan(firstTotal, 0)
        // Loading a second file tears down the first.
        model.load(url: try referenceFixtureURL(variant: "ycg6"))
        XCTAssertGreaterThan(model.totalFrames, 0)
        XCTAssertEqual(model.currentURL,
                       try referenceFixtureURL(variant: "ycg6"))
    }

    // MARK: - Helpers

    private func referenceFixtureURL(variant: String) throws -> URL {
        let url = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("reference")
            .appendingPathComponent(variant)
            .appendingPathComponent("glenc.mov")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path),
            "reference/\(variant)/glenc.mov missing (GlEnc-produced artifact, stripped from the public seed) — regenerate via the \(variant) encoder test's …AndSaveReference, or scripts/make-corpus.sh")
        return url
    }

    /// Writes a tiny H.264 .mp4 to `url` using AVAssetWriter. Solid
    /// gray frames; minimum viable test fixture for the AVFoundation
    /// poster path.
    private func writeTrivialH264(at url: URL, width: Int, height: Int, frames: Int) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        XCTAssertTrue(writer.canAdd(input))
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        for i in 0..<frames {
            // Spin until input is ready (it should be, for trivial sizes).
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            var pb: CVPixelBuffer?
            _ = CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
            if let buf = pb {
                CVPixelBufferLockBaseAddress(buf, [])
                if let ptr = CVPixelBufferGetBaseAddress(buf) {
                    let rowBytes = CVPixelBufferGetBytesPerRow(buf)
                    let gray: UInt8 = UInt8(80 + i * 20)
                    for row in 0..<height {
                        let base = ptr.advanced(by: row * rowBytes).assumingMemoryBound(to: UInt8.self)
                        for col in 0..<width {
                            base[col*4+0] = gray  // B
                            base[col*4+1] = gray  // G
                            base[col*4+2] = gray  // R
                            base[col*4+3] = 255   // A
                        }
                    }
                }
                CVPixelBufferUnlockBaseAddress(buf, [])
                let pts = CMTime(value: CMTimeValue(i), timescale: 30)
                XCTAssertTrue(adaptor.append(buf, withPresentationTime: pts))
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed,
                       "AVAssetWriter test fixture failed: \(String(describing: writer.error))")
    }
}

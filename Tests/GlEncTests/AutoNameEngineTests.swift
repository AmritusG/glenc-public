/*
 * AutoNameEngineTests — Phase 8C-b + 8C-b-fix.
 *
 * Pure-function engine + EncodeJob integration + EncodeQueue
 * refresh helper. The TextField + reset-button UI is exercised via
 * the manual GUI smoke (no direct SwiftUI rendering tests).
 *
 * Phase 8C-b-fix: trim brackets now use MM.SS.CC time format instead
 * of frame indices. Tests updated accordingly.
 */

import XCTest
import Foundation
import CoreGraphics
@testable import GlEnc
@testable import GlEncCore

@MainActor
final class AutoNameEngineTests: XCTestCase {

    // Phase 7B-a — reset AppSettings.shared between tests so
    // EncodeQueue's `defaultAlpha`/`defaultTier` didSet mirrors
    // (which write through to UserDefaults.standard) don't leak
    // across test runs.
    override func setUp() {
        super.setUp()
        AppSettings.shared.resetToDefaults()
    }
    override func tearDown() {
        AppSettings.shared.resetToDefaults()
        super.tearDown()
    }

    private func srcURL(_ filename: String) -> URL {
        URL(fileURLWithPath: "/Users/test/Movies/\(filename)")
    }

    // MARK: - Engine: per-codec base names (no trim, fps irrelevant)

    func testAutoName_DXT1_NoTrim() {
        let name = AutoNameEngine.suggestedName(
            sourceURL: srcURL("My Clip.mov"), format: .dxt1,
            inFrame: nil, outFrame: nil, fps: 24.0)
        XCTAssertEqual(name, "My Clip_DXV Normal Quality.mov")
    }

    func testAutoName_DXT5_NoTrim() {
        let name = AutoNameEngine.suggestedName(
            sourceURL: srcURL("Loop.mov"), format: .dxt5,
            inFrame: nil, outFrame: nil, fps: 24.0)
        XCTAssertEqual(name, "Loop_DXV Normal Quality With Alpha.mov")
    }

    func testAutoName_YCG6_NoTrim() {
        let name = AutoNameEngine.suggestedName(
            sourceURL: srcURL("HQ Source.mov"), format: .ycg6,
            inFrame: nil, outFrame: nil, fps: 24.0)
        XCTAssertEqual(name, "HQ Source_DXV High Quality.mov")
    }

    func testAutoName_YG10_NoTrim() {
        let name = AutoNameEngine.suggestedName(
            sourceURL: srcURL("Alpha Source.mov"), format: .yg10,
            inFrame: nil, outFrame: nil, fps: 24.0)
        XCTAssertEqual(name, "Alpha Source_DXV High Quality With Alpha.mov")
    }

    // v0.9.1 Phase G — HAP variants use the FourCC stem directly,
    // not the DXV verbose suffix.

    func testAutoName_Hap1_NoTrim() {
        let name = AutoNameEngine.suggestedName(
            sourceURL: srcURL("My Clip.mov"), format: .hap1,
            inFrame: nil, outFrame: nil, fps: 24.0)
        XCTAssertEqual(name, "My Clip_Hap1.mov")
    }

    func testAutoName_Hap5_NoTrim() {
        let name = AutoNameEngine.suggestedName(
            sourceURL: srcURL("Loop.mov"), format: .hap5,
            inFrame: nil, outFrame: nil, fps: 24.0)
        XCTAssertEqual(name, "Loop_Hap5.mov")
    }

    func testAutoName_HapY_NoTrim() {
        let name = AutoNameEngine.suggestedName(
            sourceURL: srcURL("HQ Source.mov"), format: .hapY,
            inFrame: nil, outFrame: nil, fps: 24.0)
        XCTAssertEqual(name, "HQ Source_HapY.mov")
    }

    // v0.9.2 — HapA follows the same _Hap{FourCC} pattern.

    func testAutoName_HapA_NoTrim() {
        let name = AutoNameEngine.suggestedName(
            sourceURL: srcURL("Alpha Matte.mov"), format: .hapA,
            inFrame: nil, outFrame: nil, fps: 24.0)
        XCTAssertEqual(name, "Alpha Matte_HapA.mov")
    }

    func testAutoName_HapA_WithBothTrim_24fps() {
        let name = AutoNameEngine.suggestedName(
            sourceURL: srcURL("Source.mov"), format: .hapA,
            inFrame: 24, outFrame: 180, fps: 24.0)
        XCTAssertEqual(name, "Source_HapA [00.01.00-00.07.50].mov")
    }

    /// HAP filenames keep the trim bracket exactly like DXV3 — only
    /// the codec prefix differs.
    func testAutoName_Hap5_WithBothTrim_24fps() {
        let name = AutoNameEngine.suggestedName(
            sourceURL: srcURL("Source.mov"), format: .hap5,
            inFrame: 24, outFrame: 180, fps: 24.0)
        XCTAssertEqual(name, "Source_Hap5 [00.01.00-00.07.50].mov")
    }

    // MARK: - Engine: trim bracket suffix (MM.SS.CC time format)

    /// 24 frames @ 24fps = 1.00s, 180 frames @ 24fps = 7.50s.
    func testAutoName_DXT1_WithBothTrim_24fps() {
        let name = AutoNameEngine.suggestedName(
            sourceURL: srcURL("Source.mov"), format: .dxt1,
            inFrame: 24, outFrame: 180, fps: 24.0)
        XCTAssertEqual(name, "Source_DXV Normal Quality [00.01.00-00.07.50].mov")
    }

    /// 47 frames @ 30fps = 1.5666...s → 00.01.56 (truncated).
    /// 86 frames @ 30fps = 2.8666...s → 00.02.86.
    func testAutoName_YG10_WithBothTrim_30fps() {
        let name = AutoNameEngine.suggestedName(
            sourceURL: srcURL("Source.mov"), format: .yg10,
            inFrame: 47, outFrame: 86, fps: 30.0)
        XCTAssertEqual(name, "Source_DXV High Quality With Alpha [00.01.56-00.02.86].mov")
    }

    /// Only inFrame set, totalFrames provided → out resolves to last.
    /// 10/24 = 0.4166... → 00.00.41; 99/24 = 4.125 → 00.04.12.
    func testAutoName_OnlyInFrame_WithTotal() {
        let name = AutoNameEngine.suggestedName(
            sourceURL: srcURL("Source.mov"), format: .dxt1,
            inFrame: 10, outFrame: nil, fps: 24.0, totalFrames: 100)
        XCTAssertEqual(name, "Source_DXV Normal Quality [00.00.41-00.04.12].mov")
    }

    /// Only inFrame set, totalFrames nil → out defaults to in.
    /// Both endpoints render identically.
    func testAutoName_OnlyInFrame_NoTotal() {
        let name = AutoNameEngine.suggestedName(
            sourceURL: srcURL("Source.mov"), format: .dxt1,
            inFrame: 10, outFrame: nil, fps: 24.0)
        XCTAssertEqual(name, "Source_DXV Normal Quality [00.00.41-00.00.41].mov")
    }

    /// Only outFrame set → in defaults to 0 → time 00.00.00.
    /// 50/24 = 2.0833... → 00.02.08.
    func testAutoName_OnlyOutFrame() {
        let name = AutoNameEngine.suggestedName(
            sourceURL: srcURL("Source.mov"), format: .dxt1,
            inFrame: nil, outFrame: 50, fps: 24.0)
        XCTAssertEqual(name, "Source_DXV Normal Quality [00.00.00-00.02.08].mov")
    }

    /// Swapped in/out are normalized in the suffix.
    /// 30/24 = 1.25 → 00.01.25; 80/24 = 3.333... → 00.03.33.
    func testAutoName_SwappedSorted() {
        let name = AutoNameEngine.suggestedName(
            sourceURL: srcURL("Source.mov"), format: .dxt1,
            inFrame: 80, outFrame: 30, fps: 24.0)
        XCTAssertEqual(name, "Source_DXV Normal Quality [00.01.25-00.03.33].mov")
    }

    /// Source filename containing dots / multiple extensions: stem
    /// drops only the last extension (`.mov`).
    func testAutoName_PreservesDottedStem() {
        let name = AutoNameEngine.suggestedName(
            sourceURL: srcURL("My.Clip.v2.mov"), format: .dxt1,
            inFrame: nil, outFrame: nil, fps: 24.0)
        XCTAssertEqual(name, "My.Clip.v2_DXV Normal Quality.mov")
    }

    // MARK: - Engine: fps edge cases (Phase 8C-b-fix)

    /// fps=0 → "00.00.00" placeholder for both endpoints. Surfaces
    /// the "fps not loaded yet" condition to the user before the
    /// preview pane populates EncodeJob.sourceFPS.
    func testAutoName_TimeFormat_FpsZero() {
        let name = AutoNameEngine.suggestedName(
            sourceURL: srcURL("Source.mov"), format: .dxt1,
            inFrame: 24, outFrame: 180, fps: 0)
        XCTAssertEqual(name, "Source_DXV Normal Quality [00.00.00-00.00.00].mov")
    }

    /// Negative fps treated as fps=0 fallback.
    func testAutoName_TimeFormat_NegativeFps() {
        let name = AutoNameEngine.suggestedName(
            sourceURL: srcURL("Source.mov"), format: .dxt1,
            inFrame: 24, outFrame: 180, fps: -30.0)
        XCTAssertEqual(name, "Source_DXV Normal Quality [00.00.00-00.00.00].mov")
    }

    /// Long duration crosses minute boundary: 1500/24 = 62.5s = 01:02.50.
    func testAutoName_TimeFormat_LongDuration() {
        let name = AutoNameEngine.suggestedName(
            sourceURL: srcURL("Source.mov"), format: .dxt1,
            inFrame: 0, outFrame: 1500, fps: 24.0)
        XCTAssertEqual(name, "Source_DXV Normal Quality [00.00.00-01.02.50].mov")
    }

    /// 29.97 fps (NTSC): 30 frames = 1.00099...s → 00.01.00 (truncated).
    /// 60 frames = 2.002...s → 00.02.00 (truncated).
    func testAutoName_TimeFormat_NTSC() {
        let name = AutoNameEngine.suggestedName(
            sourceURL: srcURL("Source.mov"), format: .dxt1,
            inFrame: 30, outFrame: 60, fps: 29.97)
        XCTAssertEqual(name, "Source_DXV Normal Quality [00.01.00-00.02.00].mov")
    }

    /// Filename safety: the produced name must not contain `:` (which
    /// Finder substitutes for `/` on display, garbling the name).
    func testAutoName_TimeFormat_NoColonInFilename() {
        let name = AutoNameEngine.suggestedName(
            sourceURL: srcURL("Source.mov"), format: .yg10,
            inFrame: 47, outFrame: 86, fps: 30.0)
        XCTAssertFalse(name.contains(":"),
                       "filename must not contain ':' — macOS-display unsafe")
    }

    // MARK: - Phase 7B-a: TrimFilenameFormat dispatch

    /// `.frameIndices` format emits raw integer bracket [N-M], no fps
    /// conversion. Mirrors the legacy pre-Phase-8C-b-fix behavior.
    func testAutoName_FrameIndicesFormat() {
        let name = AutoNameEngine.suggestedName(
            sourceURL: srcURL("Source.mov"), format: .dxt1,
            inFrame: 20, outFrame: 80, fps: 24.0,
            trimFormat: .frameIndices)
        XCTAssertEqual(name, "Source_DXV Normal Quality [20-80].mov")
    }

    /// `.frameIndices` ignores fps — frame indices don't depend on it.
    func testAutoName_FrameIndicesFormat_IgnoresFps() {
        let nameAt24 = AutoNameEngine.suggestedName(
            sourceURL: srcURL("Source.mov"), format: .yg10,
            inFrame: 47, outFrame: 86, fps: 24.0,
            trimFormat: .frameIndices)
        let nameAt30 = AutoNameEngine.suggestedName(
            sourceURL: srcURL("Source.mov"), format: .yg10,
            inFrame: 47, outFrame: 86, fps: 30.0,
            trimFormat: .frameIndices)
        XCTAssertEqual(nameAt24, nameAt30,
                       "frame-indices format must be fps-independent")
        XCTAssertEqual(nameAt24,
                       "Source_DXV High Quality With Alpha [47-86].mov")
    }

    /// Default `trimFormat` (`.time`) preserves Phase 8C-b-fix2 behavior.
    func testAutoName_DefaultTrimFormatIsTime() {
        let withDefault = AutoNameEngine.suggestedName(
            sourceURL: srcURL("Source.mov"), format: .dxt1,
            inFrame: 24, outFrame: 180, fps: 24.0)
        let withExplicit = AutoNameEngine.suggestedName(
            sourceURL: srcURL("Source.mov"), format: .dxt1,
            inFrame: 24, outFrame: 180, fps: 24.0,
            trimFormat: .time)
        XCTAssertEqual(withDefault, withExplicit)
    }

    /// `.frameIndices` honors swap-tolerance.
    func testAutoName_FrameIndicesFormat_SwappedSorted() {
        let name = AutoNameEngine.suggestedName(
            sourceURL: srcURL("Source.mov"), format: .dxt1,
            inFrame: 80, outFrame: 30, fps: 24.0,
            trimFormat: .frameIndices)
        XCTAssertEqual(name, "Source_DXV Normal Quality [30-80].mov")
    }

    // MARK: - EncodeJob: init + setters

    func testEncodeJob_AutoNameOnInit() {
        let job = EncodeJob(sourceURL: srcURL("Clip.mov"), format: .dxt1)
        XCTAssertEqual(job.outputName, "Clip_DXV Normal Quality.mov")
        XCTAssertFalse(job.outputNameOverridden)
        XCTAssertNil(job.sourceFPS,
                     "sourceFPS is nil at init; populated when preview loads")
    }

    /// With nil sourceFPS, trim-set + setOutputNameAuto produces the
    /// fps=0 placeholder. PreviewPane's onChange(of: model.frameRate)
    /// later populates fps and triggers a re-refresh.
    func testEncodeJob_SetOutputNameAuto_TrimWithoutFPS() {
        var job = EncodeJob(sourceURL: srcURL("Clip.mov"), format: .dxt1)
        job.inFrame = 5
        job.outFrame = 15
        job.setOutputNameAuto()
        XCTAssertEqual(job.outputName,
                       "Clip_DXV Normal Quality [00.00.00-00.00.00].mov")
    }

    /// Once sourceFPS is known, refresh produces real time brackets.
    func testEncodeJob_SetOutputNameAuto_TrimWithFPS() {
        var job = EncodeJob(sourceURL: srcURL("Clip.mov"), format: .dxt1)
        job.inFrame = 5
        job.outFrame = 15
        job.sourceFPS = 24.0
        job.setOutputNameAuto()
        // 5/24 = 0.208... → 00.00.20; 15/24 = 0.625 → 00.00.62.
        XCTAssertEqual(job.outputName,
                       "Clip_DXV Normal Quality [00.00.20-00.00.62].mov")
    }

    func testEncodeJob_SetOutputNameAuto_PicksUpFormat() {
        var job = EncodeJob(sourceURL: srcURL("Clip.mov"), format: .dxt1)
        job.format = .yg10
        job.setOutputNameAuto()
        XCTAssertEqual(job.outputName, "Clip_DXV High Quality With Alpha.mov")
    }

    func testEncodeJob_ResetToAuto_ClearsOverride() {
        var job = EncodeJob(sourceURL: srcURL("Clip.mov"), format: .dxt1)
        job.outputName = "Custom Name.mov"
        job.outputNameOverridden = true
        job.resetOutputNameToAuto()
        XCTAssertEqual(job.outputName, "Clip_DXV Normal Quality.mov")
        XCTAssertFalse(job.outputNameOverridden)
    }

    /// defaultOutputURL composes the source directory + outputName.
    /// Trim suffix flows through with time format.
    func testEncodeJob_DefaultOutputURL_PicksUpOutputName() {
        var job = EncodeJob(sourceURL: srcURL("Clip.mov"), format: .yg10)
        job.inFrame = 10
        job.outFrame = 20
        job.sourceFPS = 24.0
        job.setOutputNameAuto()
        // 10/24=0.4166... → 00.00.41; 20/24=0.8333... → 00.00.83.
        XCTAssertEqual(job.defaultOutputURL.path,
                       "/Users/test/Movies/Clip_DXV High Quality With Alpha [00.00.41-00.00.83].mov")
    }

    /// defaultOutputURL respects manual overrides.
    func testEncodeJob_DefaultOutputURL_PicksUpOverride() {
        var job = EncodeJob(sourceURL: srcURL("Clip.mov"), format: .dxt1)
        job.outputName = "totally custom.mov"
        job.outputNameOverridden = true
        XCTAssertEqual(job.defaultOutputURL.path,
                       "/Users/test/Movies/totally custom.mov")
    }

    // MARK: - EncodeQueue: refreshAutoNameIfNeeded

    func testEncodeQueue_RefreshAutoName_NotOverridden() {
        let queue = EncodeQueue()
        queue.addJobs(urls: [srcURL("Clip.mov")])
        let id = queue.jobs[0].id
        XCTAssertEqual(queue.jobs[0].outputName, "Clip_DXV Normal Quality.mov")
        queue.jobs[0].format = .yg10
        queue.refreshAutoNameIfNeeded(jobID: id)
        XCTAssertEqual(queue.jobs[0].outputName,
                       "Clip_DXV High Quality With Alpha.mov")
    }

    func testEncodeQueue_RefreshAutoName_OverriddenPreserved() {
        let queue = EncodeQueue()
        queue.addJobs(urls: [srcURL("Clip.mov")])
        let id = queue.jobs[0].id
        queue.jobs[0].outputName = "User Edit.mov"
        queue.jobs[0].outputNameOverridden = true
        queue.jobs[0].format = .yg10
        queue.refreshAutoNameIfNeeded(jobID: id)
        XCTAssertEqual(queue.jobs[0].outputName, "User Edit.mov",
                       "override must survive format change + refresh")
    }

    /// Refresh on trim change uses fps from the job's sourceFPS field.
    func testEncodeQueue_RefreshAutoName_TrimChangeWithFPS() {
        let queue = EncodeQueue()
        queue.addJobs(urls: [srcURL("Clip.mov")])
        let id = queue.jobs[0].id
        queue.jobs[0].sourceFPS = 24.0
        queue.jobs[0].inFrame = 20
        queue.jobs[0].outFrame = 50
        queue.refreshAutoNameIfNeeded(jobID: id)
        // 20/24=0.8333... → 00.00.83; 50/24=2.0833... → 00.02.08.
        XCTAssertEqual(queue.jobs[0].outputName,
                       "Clip_DXV Normal Quality [00.00.83-00.02.08].mov")
    }

    /// Trim set BEFORE fps is known → placeholder. Then fps arrives,
    /// refresh produces real times. Phase 8C-b-fix race-handling path.
    func testEncodeQueue_RefreshAutoName_FpsArrivesAfterTrim() {
        let queue = EncodeQueue()
        queue.addJobs(urls: [srcURL("Clip.mov")])
        let id = queue.jobs[0].id
        // Set trim first; fps still nil.
        queue.jobs[0].inFrame = 12
        queue.jobs[0].outFrame = 48
        queue.refreshAutoNameIfNeeded(jobID: id)
        XCTAssertEqual(queue.jobs[0].outputName,
                       "Clip_DXV Normal Quality [00.00.00-00.00.00].mov",
                       "trim without fps → placeholder")
        // Now fps arrives. Refresh fires again.
        queue.jobs[0].sourceFPS = 24.0
        queue.refreshAutoNameIfNeeded(jobID: id)
        XCTAssertEqual(queue.jobs[0].outputName,
                       "Clip_DXV Normal Quality [00.00.50-00.02.00].mov",
                       "trim with fps → real time brackets")
    }

    func testEncodeQueue_RefreshAutoName_ResetClearsOverride() {
        let queue = EncodeQueue()
        queue.addJobs(urls: [srcURL("Clip.mov")])
        let id = queue.jobs[0].id
        queue.jobs[0].outputName = "Manual.mov"
        queue.jobs[0].outputNameOverridden = true
        queue.jobs[0].resetOutputNameToAuto()
        XCTAssertFalse(queue.jobs[0].outputNameOverridden)
        XCTAssertEqual(queue.jobs[0].outputName, "Clip_DXV Normal Quality.mov")
        queue.jobs[0].format = .yg10
        queue.refreshAutoNameIfNeeded(jobID: id)
        XCTAssertEqual(queue.jobs[0].outputName,
                       "Clip_DXV High Quality With Alpha.mov")
    }

    func testEncodeQueue_RefreshAutoName_NonexistentIdIsNoOp() {
        let queue = EncodeQueue()
        queue.refreshAutoNameIfNeeded(jobID: UUID())
        XCTAssertEqual(queue.jobs.count, 0)
    }

    // MARK: - Crop tag (Crop Release Phase G — Q10)
    //
    // Locked format: `[WxH]` (lowercase x, matches the rowCrop UI
    // badge), inserted between the codec suffix and the trim bracket
    // when cropRect is set. Spatial-first / temporal-second mirrors
    // the conceptual model — crop identifies which content, trim
    // selects a range from that content.

    /// (1) Crop set, nothing else: token present after codec suffix,
    /// no trim bracket.
    func testAutoName_CropOnly_DXT1() {
        let name = AutoNameEngine.suggestedName(
            sourceURL: srcURL("Clip.mov"), format: .dxt1,
            inFrame: nil, outFrame: nil, fps: 24.0,
            cropRect: CGRect(x: 320, y: 180, width: 1280, height: 720))
        XCTAssertEqual(name, "Clip_DXV Normal Quality [1280x720].mov")
    }

    /// (2) Crop nil, nothing else: no crop token. Byte-identical to
    /// the pre-Phase-G output for non-cropped jobs — guards the
    /// no-op default.
    func testAutoName_CropNil_BytewiseIdenticalToPreG() {
        let withExplicitNil = AutoNameEngine.suggestedName(
            sourceURL: srcURL("Clip.mov"), format: .dxt1,
            inFrame: nil, outFrame: nil, fps: 24.0,
            cropRect: nil)
        let withoutParam = AutoNameEngine.suggestedName(
            sourceURL: srcURL("Clip.mov"), format: .dxt1,
            inFrame: nil, outFrame: nil, fps: 24.0)
        XCTAssertEqual(withExplicitNil, "Clip_DXV Normal Quality.mov")
        XCTAssertEqual(withExplicitNil, withoutParam,
                       "default cropRect param value must produce a "
                       + "byte-identical string to omitting it")
    }

    /// (3) Crop nil + resize set: NO crop token. The resize-asymmetry
    /// principle — resize is invisible to auto-name; this guards
    /// against accidentally tagging resize-only jobs. (Resize doesn't
    /// affect the engine surface at all today; this test pins the
    /// expected behavior so a future "tag resize too" refactor can't
    /// silently change the no-crop, resize-only output.)
    func testAutoName_CropNil_ResizeSet_NoToken() {
        // suggestedName has no outputSize parameter — resize is
        // invisible to the engine. The output must equal the bare
        // no-crop / no-trim form regardless of any resize the job
        // might carry elsewhere.
        let name = AutoNameEngine.suggestedName(
            sourceURL: srcURL("Clip.mov"), format: .dxt1,
            inFrame: nil, outFrame: nil, fps: 24.0,
            cropRect: nil)
        XCTAssertEqual(name, "Clip_DXV Normal Quality.mov",
                       "resize-only jobs must NOT get a crop token "
                       + "(resize asymmetry: resize is invisible, "
                       + "crop is visible)")
    }

    /// (4) Crop + trim, both set: both tokens present in the locked
    /// order — crop first, trim second, separated by a single space
    /// (matching trim's existing leading-space pattern).
    func testAutoName_CropAndTrim_DXT1_24fps() {
        let name = AutoNameEngine.suggestedName(
            sourceURL: srcURL("Clip.mov"), format: .dxt1,
            inFrame: 24, outFrame: 180, fps: 24.0,
            cropRect: CGRect(x: 320, y: 180, width: 1280, height: 720))
        XCTAssertEqual(name,
            "Clip_DXV Normal Quality [1280x720] [00.01.00-00.07.50].mov")
    }

    /// (5) Crop equals full source dims: token still present. Locked
    /// principle — the user did Apply with a rect, the gesture is
    /// honored; do NOT optimize "no-op crop" away in a future
    /// refactor (this test would catch that change).
    func testAutoName_CropFullSourceDims_TokenStillPresent() {
        let name = AutoNameEngine.suggestedName(
            sourceURL: srcURL("Clip.mov"), format: .dxt1,
            inFrame: nil, outFrame: nil, fps: 24.0,
            cropRect: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        XCTAssertEqual(name, "Clip_DXV Normal Quality [1920x1080].mov",
                       "a crop rect equal to full source dims must "
                       + "still produce the token — user applied a "
                       + "rect, we honor the gesture")
    }
}

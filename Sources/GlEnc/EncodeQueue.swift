// SPDX-License-Identifier: MIT
import Foundation
import SwiftUI
import CoreGraphics
import AVFoundation
import GlEncCore

/// The encode queue's view model. Phase 7A landed:
///
///   - Global defaults expressed as `defaultTier` × `defaultAlpha`
///     (the two-dropdown UI), composed into a `DXVFormat` at job-add
///     time. Changing the defaults does NOT update existing rows.
///   - Per-row override: mutate `jobs[i].format` directly (the UI's
///     row pickers do this via custom `Binding`s).
///   - Loose Task-based cancellation. `encodeAll()` spawns one Task
///     per queued job in series; `cancel(id:)` cancels the active
///     Task or marks a queued job `.failed`. `cancelAll()` cancels
///     the active Task and marks remaining `.queued` jobs `.failed`.
///     `EncodePipeline` checks `Task.isCancelled` per frame and
///     throws `CancellationError`; the queue catches it and writes
///     the job as `.failed` with reason "Cancelled".
///   - Queue management: `removeJob(id:)` and `clearCompleted()`.
///   - Test hook: `_testEncodeJobHook` replaces the real
///     `EncodePipeline.run` for unit tests that need controllable
///     cancellation timing without a real encode.
///
/// Serial encoding is the right default — DXV encoding is CPU/GPU-
/// heavy and parallel jobs would thrash. Phase 7B may add an opt-in
/// "concurrent jobs" preference for users on big machines.
@MainActor
final class EncodeQueue: ObservableObject {

    /// Phase 3 — Motion JPEG ships at a fixed high-quality JPEG target
    /// (AVVideoQualityKey). The value now lives in `CoreEncoder` (the
    /// shared dispatch); this alias keeps the historical GUI reference
    /// pointing at the single source of truth.
    static let mjpegDefaultQuality = CoreEncoder.mjpegDefaultQuality

    // MARK: - Published state

    @Published var jobs: [EncodeJob] = []

    /// Global codec defaults. New rows added via `addJobs(urls:)`
    /// inherit `DXVFormat(tier: defaultTier, alpha: defaultAlpha)`.
    /// Changing these does NOT propagate to existing rows.
    ///
    /// Phase 7B-a — initial values come from `AppSettings.shared` so the
    /// user's persisted defaults are honored at app launch. The
    /// toolbar pickers write through these `@Published` properties;
    /// the `didSet` mirrors back to `AppSettings.shared` so changes
    /// during the session persist for the next launch.
    @Published var defaultTier: QualityTier {
        didSet { AppSettings.shared.defaultQuality = defaultTier }
    }
    @Published var defaultAlpha: AlphaMode {
        didSet { AppSettings.shared.defaultAlpha = defaultAlpha }
    }

    /// Resize Release Phase F — queue-side mirrors for the resize
    /// defaults, matching the defaultTier/defaultAlpha pattern.
    /// SwiftUI bindings in ContentView's defaults row write through
    /// these `@Published` properties; the `didSet` keeps
    /// `AppSettings.shared` in sync for persistence across launches.
    @Published var defaultOutputSize: OutputSize {
        didSet { AppSettings.shared.defaultOutputSize = defaultOutputSize }
    }
    @Published var defaultResizeQuality: ResizeQuality {
        didSet { AppSettings.shared.defaultResizeQuality = defaultResizeQuality }
    }
    /// Resize Release Phase G — queue-side mirror for defaultAspectMode.
    @Published var defaultAspectMode: AspectMode {
        didSet { AppSettings.shared.defaultAspectMode = defaultAspectMode }
    }

    /// Phase 7B-a — seed `defaultTier` / `defaultAlpha` from
    /// `AppSettings.shared` so persisted preferences are applied on app
    /// launch. Tests construct `EncodeQueue()` and get whatever values
    /// the shared singleton currently holds (which itself defaults
    /// to `.normal` / `.withoutAlpha` for a fresh launch).
    /// Resize Release Phase F — seeds the resize mirrors the same way.
    init() {
        let s = AppSettings.shared
        self.defaultTier = s.defaultQuality
        self.defaultAlpha = s.defaultAlpha
        self.defaultOutputSize = s.defaultOutputSize
        self.defaultResizeQuality = s.defaultResizeQuality
        self.defaultAspectMode = s.defaultAspectMode
    }

    /// True while a serial encode-all run is in flight. Drives the
    /// "Encode Queue" / "Cancel All" button enabled states.
    @Published var isEncoding: Bool = false

    /// v0.9.2 Phase G — currently-shown collision prompt, or nil
    /// when no prompt is active. ContentView observes this and
    /// renders a SwiftUI alert; the alert's button actions call
    /// `prompt.resolve(_:applyToAll:)` which resumes the queue's
    /// awaiting CheckedContinuation.
    @Published var pendingCollisionPrompt: CollisionPrompt?

    /// Apply-to-all override for the current encodeAll session.
    /// Set when the user ticks the alert's "Apply to all remaining"
    /// checkbox and picks an action. Reset at the start of each
    /// encodeAll run. nil = no override; prompt each collision.
    private var sessionCollisionOverride: CollisionDecisionBase?

    /// The decision portion of CollisionDecision, minus the bound
    /// URL — the URL has to be re-resolved per-job because each
    /// job's collision-free name depends on the specific colliding
    /// path. apply-to-all-rename means "rename every subsequent
    /// collision, recomputing the next-N for each."
    enum CollisionDecisionBase {
        case overwrite, autoRename, skip
        // `.cancel` doesn't apply-to-all — it cancels the session
        // outright, not "always cancel future jobs."
    }

    /// Phase 8B: which queue row is currently selected. Drives the
    /// preview pane on the right side of the window. Mutated by the
    /// queue table's row selection and (programmatically) by
    /// `addJobs` (auto-select first row when nothing was selected)
    /// and `removeJob` (move to neighbor or clear).
    ///
    /// Batch-edit — this is now the PRIMARY (focused) row of a possibly
    /// multi-row selection (`selectedJobIDs`). The preview pane, trim and
    /// crop keep following this single row. Setting it to a row outside
    /// the current selection collapses the selection to that row.
    @Published var selectedJobID: EncodeJob.ID? {
        didSet {
            guard selectedJobID != oldValue else { return }
            if let id = selectedJobID {
                if !selectedJobIDs.contains(id) { selectedJobIDs = [id] }
            } else if !selectedJobIDs.isEmpty {
                selectedJobIDs = []
            }
        }
    }

    /// Batch-edit — the full List selection (Cmd/Shift-click, Cmd-A).
    /// Bound to `List(selection:)`. Keeps `selectedJobID` pointing at a
    /// member: a newly-added member becomes primary, and if the primary
    /// left the set, the first remaining row (queue order) takes over.
    @Published var selectedJobIDs: Set<EncodeJob.ID> = [] {
        didSet {
            guard selectedJobIDs != oldValue else { return }
            if selectedJobIDs.isEmpty {
                if selectedJobID != nil { selectedJobID = nil }
                return
            }
            if let p = selectedJobID, selectedJobIDs.contains(p) { return }
            let added = selectedJobIDs.subtracting(oldValue)
            let pool = added.isEmpty ? selectedJobIDs : added
            selectedJobID = jobs.first(where: { pool.contains($0.id) })?.id
                ?? pool.first
        }
    }

    /// Batch-edit — true when ≥2 rows are selected: the top settings bar
    /// then edits those rows instead of the defaults for new files.
    var isBatchSelection: Bool { selectedJobIDs.count >= 2 }

    /// Batch-edit — select every row (header button + Edit ▸ Select All
    /// Clips). The primary row is kept if there was one.
    func selectAllJobs() {
        selectedJobIDs = Set(jobs.map(\.id))
    }

    /// Batch-edit — drop back to just the primary row.
    func collapseSelectionToPrimary() {
        if let p = selectedJobID { selectedJobIDs = [p] } else { selectedJobIDs = [] }
    }

    /// The selected jobs in queue order (batch targets + bar display).
    var selectedJobs: [EncodeJob] {
        jobs.filter { selectedJobIDs.contains($0.id) }
    }

    /// Convenience accessor for the currently-selected job.
    var selectedJob: EncodeJob? {
        guard let id = selectedJobID else { return nil }
        return jobs.first { $0.id == id }
    }

    // MARK: - Crop edit (Crop Release Phase E)

    /// The queue row currently in crop-edit mode, or nil. Only one
    /// row edits at a time (CROP_PLAN.md Q3 — serialized edit). Drives
    /// `CropOverlayView`'s active/passive state on the preview pane
    /// and `JobCardView`'s rowCrop Edit / Apply / Cancel controls.
    @Published var cropEditingJobID: EncodeJob.ID?

    /// The in-flight crop rect during an edit, in source-pixel space.
    /// `CropOverlayView`'s drag and keyboard-nudge mutations write
    /// here; the committed `EncodeJob.cropRect` is left untouched
    /// until `applyCropEdit()`. Seeded from the target job's
    /// `cropRect` on `beginCropEdit` — may be nil, in which case the
    /// overlay seeds a full-frame rect on the first drag (Phase D).
    @Published var pendingCropRect: CGRect?

    /// Preview-pane visibility captured at `beginCropEdit` so that
    /// `applyCropEdit` / `cancelCropEdit` can restore it (CROP_PLAN.md
    /// Q9 — entering crop edit force-expands a collapsed pane, exiting
    /// restores the prior state). nil when no edit is active.
    private var cropEditPriorPaneState: Bool?

    // Fix-Brief B — the crop editor's numeric clamp now reads the
    // authoritative probe-time dims on `EncodeJob` (`job.sourceWidth/
    // Height`) directly, so the old live-preview-published
    // `cropEditingSourceWidth/Height` channel is retired. The DRAG
    // overlay still uses the live preview's dims (it operates on the
    // decoded frame); only the numeric field clamp moved to probe-time.

    /// Crop Release Phase E.10 — currently-focused corner handle
    /// during an active crop edit, or `nil` when no corner is
    /// focused. When non-nil, PreviewArea's arrow-key handler
    /// dispatches to corner-resize (focused corner moves, opposite
    /// stays pinned); when nil, arrows drive Phase E's whole-rect
    /// translate. Set by `CropOverlayView`'s handle drag onChanged
    /// (every tap-or-drag on a handle focuses it); cleared by
    /// background-tap on the overlay, by Escape (when focused), and
    /// by `endCropEdit`'s teardown. Reuses the existing `Corner`
    /// enum from `CropDragMath` — same four-corner identity used by
    /// Phase D's drag gestures.
    @Published var focusedCropCorner: Corner?

    /// Enter crop-edit mode for `jobID`. Serializes: any in-flight
    /// edit on another row is cancelled first (Q3). `pendingCropRect`
    /// is seeded from the job's current `cropRect`; the preview pane
    /// is force-expanded with its prior state saved for restore.
    func beginCropEdit(jobID: EncodeJob.ID) {
        if cropEditingJobID != nil { cancelCropEdit() }
        guard let job = jobs.first(where: { $0.id == jobID }) else { return }
        cropEditingJobID = jobID
        pendingCropRect = job.cropRect
        cropEditPriorPaneState = AppSettings.shared.previewPaneVisibleByDefault
        AppSettings.shared.previewPaneVisibleByDefault = true
        // Fix-Brief B — guarantee the authoritative source dims are present
        // for the numeric clamp. They're normally captured by the add-time
        // probe; if a row is edited before that resolved (drop → instant
        // Edit), re-run the probe now. The clamp refuses commits while dims
        // are nil (Brief A), so this only narrows the window — it never
        // hands the clamp a wrong value.
        if job.sourceWidth == nil || job.sourceHeight == nil {
            let url = job.sourceURL
            Task { [weak self] in await self?.probeAndStoreTiming(jobID: jobID, url: url) }
        }
    }

    /// Commit the in-flight `pendingCropRect` onto the editing job's
    /// `cropRect`, then exit edit mode and restore the preview pane.
    func applyCropEdit() {
        if let id = cropEditingJobID,
           let i = jobs.firstIndex(where: { $0.id == id }) {
            jobs[i].cropRect = pendingCropRect
            // Phase G.2 — refresh the auto-name so the [WxH] token
            // reflects the just-committed cropRect (gated by
            // !outputNameOverridden inside the helper).
            refreshAutoNameIfNeeded(jobID: id)
        }
        endCropEdit()
    }

    /// Discard the in-flight edit, exit edit mode, restore the preview
    /// pane. The editing job's committed `cropRect` is untouched.
    func cancelCropEdit() {
        endCropEdit()
    }

    /// Crop Release Phase E.8 — unconditionally remove the editing
    /// job's committed `cropRect` and exit edit mode. Distinct from
    /// `cancelCropEdit` (which preserves the prior committed value) —
    /// Clear is the "no, take it out" action regardless of in-flight
    /// edit state. The auto-name `[WxH]` token (Phase G) disappears
    /// automatically as `cropRect` goes nil.
    func clearCropEdit() {
        if let id = cropEditingJobID,
           let i = jobs.firstIndex(where: { $0.id == id }) {
            jobs[i].cropRect = nil
            // Phase G.2 — refresh the auto-name so the [WxH] token
            // disappears now that cropRect is nil (gated by
            // !outputNameOverridden inside the helper).
            refreshAutoNameIfNeeded(jobID: id)
        }
        endCropEdit()
    }

    /// Shared teardown for apply / cancel / clear — clears the edit
    /// fields and restores the preview pane to its pre-edit
    /// visibility.
    private func endCropEdit() {
        cropEditingJobID = nil
        pendingCropRect = nil
        // Phase E.10 — focused corner is scoped to the active edit
        // too; the next edit should start with no corner focused so
        // arrow keys default to whole-rect translate.
        focusedCropCorner = nil
        if let prior = cropEditPriorPaneState {
            AppSettings.shared.previewPaneVisibleByDefault = prior
            cropEditPriorPaneState = nil
        }
    }

    // MARK: - Test hook

    /// Test-only override. When non-nil, `encodeOne` calls this
    /// closure instead of constructing a real `EncodePipeline`.
    /// Tests inject a slow stub that respects `Task.isCancelled`
    /// so the cancel scenarios are observable without running the
    /// real encoder. Returns the simulated output URL on success;
    /// throws on cancellation or simulated failure. Not part of the
    /// app's runtime path.
    var _testEncodeJobHook: ((EncodeJob) async throws -> URL)?

    // MARK: - Internal state

    /// The Task running the currently-encoding job, or `nil` when
    /// `isEncoding == false`. Used by `cancel(id:)` and
    /// `cancelAll()` to trip cancellation on the in-flight Task.
    private var currentTask: Task<Void, Never>?
    private var currentJobID: UUID?

    /// The Task running the overall `encodeAll` loop. Held so
    /// `cancelAll()` can stop the iteration after the in-flight
    /// job exits.
    private var outerTask: Task<Void, Never>?

    // MARK: - Queue management

    var defaultFormat: DXVFormat {
        DXVFormat(tier: defaultTier, alpha: defaultAlpha)
    }

    func addJobs(urls: [URL]) {
        let format = defaultFormat
        // Resize Release Phase F — read from the queue-side @Published
        // mirrors (defaultOutputSize / defaultResizeQuality) so the
        // defaults row's SwiftUI bindings drive newly-dropped-job
        // inheritance the same way defaultTier/defaultAlpha do.
        // (Phase C originally read from AppSettings.shared directly;
        // the mirrors keep AppSettings in sync via didSet so the
        // observed behavior is identical.)
        let outputSize = self.defaultOutputSize
        let resizeQuality = self.defaultResizeQuality
        let aspectMode = self.defaultAspectMode
        // Phase 4 — audio defaults for new jobs.
        let audioEnabled = AppSettings.shared.defaultAudioEnabled
        let audioRate = AppSettings.shared.defaultAudioRate
        // Slice 4 — seed the per-job HAP chunk count from the persisted
        // default (read directly, mirroring the audio defaults above).
        let hapChunks = AppSettings.shared.defaultHapChunks
        // Batch-edit / defaults parity — the non-DXV codec defaults
        // (ProRes / H.264 / HEVC / MJPEG), container and H.264/HEVC knobs.
        let defaults = defaultSettings
        let firstAddedIdx = jobs.count
        for url in urls {
            var job = EncodeJob(sourceURL: url, format: format,
                                outputSize: outputSize,
                                resizeQuality: resizeQuality,
                                aspectMode: aspectMode,
                                audioEnabled: audioEnabled,
                                audioRate: audioRate,
                                hapChunks: hapChunks)
            let seeded = job.settings
            if defaults != seeded {
                job.settings = defaults
                // Only codec/container feed the filename; with the DXV
                // default the init-derived name is left byte-identical.
                if defaults.affectsAutoName(comparedTo: seeded) {
                    job.setOutputNameAuto(trimFormat: AppSettings.shared.trimFilenameFormat)
                }
            }
            jobs.append(job)
            print("[GlEnc] queued #\(jobs.count - 1): \(url.path) → \(job.format.label)")
            // Multi-Format Phase 1 — probe source alpha asynchronously
            // so ProRes alpha-steering (default 4444 on an alpha source,
            // flatten note on a non-4444 choice) has a real signal. nil
            // until this resolves; the picker falls back to alpha intent.
            // Phase 4 — probe sourceHasAudio in the same pass (drives the
            // audio controls' inert state).
            let jobID = job.id
            let probeURL = url
            Task { [weak self] in
                let alpha = await EncodeJob.probeSourceAlpha(probeURL)
                let hasAudio = await SourceAudioReader.hasAudio(probeURL)
                // v1.6.0 — Alpha Type: DXV alpha is the user's choice (+ the
                // spec 8.5 hint); HAP / ProRes / HEVC alpha is stated.
                let alphaReport = await SourceAlpha.probe(probeURL)
                guard let self else { return }
                if let i = self.jobs.firstIndex(where: { $0.id == jobID }) {
                    // DXV sources: EncodeJob.probeSourceAlpha can't read them
                    // (AVFoundation sees only the FourCC); the report can.
                    self.jobs[i].sourceHasAlpha = alpha ?? (alphaReport.kind == .choosable ? true : nil)
                    self.jobs[i].sourceHasAudio = hasAudio
                    self.jobs[i].sourceAlphaReport = alphaReport
                }
                // Fix-Brief B — capture authoritative source dims + fps +
                // frame count via the validated encode reader, and surface
                // a malformed-source failure (no longer try?-swallowed).
                await self.probeAndStoreTiming(jobID: jobID, url: probeURL)
            }
        }
        // Phase 8B: auto-select the first new row if nothing was
        // selected before (e.g. drop-on-empty-queue). Existing
        // selection is preserved across subsequent adds.
        if selectedJobID == nil, firstAddedIdx < jobs.count {
            selectedJobID = jobs[firstAddedIdx].id
        }
    }

    /// Fix-Brief B — probe authoritative source dims (+ fps + frame count)
    /// via the validated encode reader and store them on the job. Shared by
    /// the add-time probe and `beginCropEdit` (which re-runs it if a row is
    /// edited before the add-time probe resolved). On a malformed source the
    /// reader throws (validated geometry / no-video-track / etc.); we mark
    /// the job `.failed` with the reason rather than leaving it a usable row
    /// that renders garbage. Existing values are not clobbered (a
    /// preview-discovered fps stays).
    func probeAndStoreTiming(jobID: EncodeJob.ID, url: URL) async {
        do {
            let t = try await EncodeJob.probeSourceTiming(url)
            guard let i = jobs.firstIndex(where: { $0.id == jobID }) else { return }
            var changed = false
            if jobs[i].sourceWidth == nil { jobs[i].sourceWidth = t.width }
            if jobs[i].sourceHeight == nil { jobs[i].sourceHeight = t.height }
            if jobs[i].sourceFPS == nil { jobs[i].sourceFPS = t.fps; changed = true }
            if jobs[i].sourceFrameCount == nil { jobs[i].sourceFrameCount = t.frameCount; changed = true }
            if changed { refreshAutoNameIfNeeded(jobID: jobID) }
        } catch let e as SourceReaderError {
            // DEFINITIVE malformed-source signal from the validated reader
            // (zero/oversized dims, no video track, …) — surface as failed-
            // with-reason instead of silently adding a garbage-rendering row.
            guard let i = jobs.firstIndex(where: { $0.id == jobID }) else { return }
            jobs[i].status = .failed
            jobs[i].errorMessage = "Unusable source: \(e)"
        } catch {
            // The source couldn't be opened for some OTHER reason (e.g. an
            // AVFoundation "cannot open" / transient / not-yet-available
            // error). Don't fail the job at probe time — leave it queued and
            // let the encode surface a precise error if it truly can't
            // proceed. Preserves pre-Fix-B behavior for non-validation
            // failures (the probe is best-effort for those).
        }
    }

    /// Phase 8C-b — refresh a row's outputName from the AutoNameEngine
    /// IF the user hasn't manually edited it. Called from:
    ///   - ContentView's Quality/Alpha row bindings after writing `format`
    ///   - PreviewPane's trim-sync `.onChange` after writing inFrame/outFrame
    /// Idempotent + safe to call on missing IDs.
    func refreshAutoNameIfNeeded(jobID: EncodeJob.ID) {
        guard let i = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        guard !jobs[i].outputNameOverridden else { return }
        // Phase 7B-a — pass the user's currently-selected trim filename
        // format to the engine. AppSettings.shared is @MainActor-isolated;
        // the queue is also @MainActor, so this read is in-context.
        jobs[i].setOutputNameAuto(trimFormat: AppSettings.shared.trimFilenameFormat)
    }

    func removeJob(id: UUID) {
        // Only remove if not actively encoding — caller should
        // cancel first if mid-encode.
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        guard jobs[i].status != .encoding else { return }
        let wasSelected = (selectedJobID == id)
        jobs.remove(at: i)
        selectedJobIDs.remove(id)
        // Phase 8B: keep selection consistent — when the removed
        // row was selected, move to the row that now occupies index
        // `i` (the successor), or to the new last row if removing the
        // tail, or clear if the queue is empty.
        if wasSelected {
            if jobs.isEmpty {
                selectedJobID = nil
            } else if i < jobs.count {
                selectedJobID = jobs[i].id
            } else {
                selectedJobID = jobs.last?.id
            }
        }
    }

    // MARK: - v1.5.0 (G1) — reset finished jobs for a re-run

    /// Where `job` will be written, before collision handling: the fixed
    /// output folder when that preference is set (and exists), else the
    /// source's folder.
    func plannedOutputURL(for job: EncodeJob) -> URL {
        let location = AppSettings.shared.outputLocation
        let fixedPath = AppSettings.shared.fixedOutputPath
        if location == .fixed, !fixedPath.isEmpty,
           FileManager.default.fileExists(atPath: fixedPath) {
            return URL(fileURLWithPath: fixedPath).appendingPathComponent(job.outputName)
        }
        return job.defaultOutputURL
    }

    /// Output paths other queued / encoding jobs will write (standardized).
    func claimedOutputPaths(excluding id: EncodeJob.ID) -> Set<String> {
        Set(jobs.filter { $0.id != id && ($0.status == .queued || $0.status == .encoding) }
                .map { plannedOutputURL(for: $0).standardizedFileURL.path })
    }

    /// Reset finished jobs (done / failed — failed includes cancelled and
    /// skipped) among `ids` to queued, keeping their current settings, so
    /// the next Encode runs them again. A collision-renamed output name
    /// goes back to its base name (the re-run numbers it again); a manual
    /// rename is kept; an auto name is refreshed. Queued and encoding jobs
    /// are untouched. Returns how many were reset.
    @discardableResult
    func resetJobs<S: Sequence>(_ ids: S) -> Int where S.Element == EncodeJob.ID {
        let targets = Set(ids)
        var count = 0
        var refresh: [EncodeJob.ID] = []
        for i in jobs.indices where targets.contains(jobs[i].id) && jobs[i].isFinished {
            jobs[i].status = .queued
            jobs[i].progress = 0
            jobs[i].errorMessage = nil
            jobs[i].audioWarning = nil
            jobs[i].outputURL = nil
            jobs[i].previewSide = .source
            jobs[i].isRerun = true
            if let base = jobs[i].preCollisionName {
                jobs[i].outputName = base
                jobs[i].preCollisionName = nil
                jobs[i].outputNameOverridden = false
            }
            if !jobs[i].outputNameOverridden { refresh.append(jobs[i].id) }
            count += 1
        }
        for id in refresh { refreshAutoNameIfNeeded(jobID: id) }
        return count
    }

    /// Reset the selected finished jobs (Queue ▸ Reset Selected).
    @discardableResult
    func resetSelected() -> Int { resetJobs(selectedJobIDs) }

    /// Reset every finished job (Queue ▸ Reset All Finished).
    @discardableResult
    func resetAllFinished() -> Int { resetJobs(jobs.map(\.id)) }

    var selectionHasFinished: Bool { selectedJobs.contains(where: \.isFinished) }
    var hasFinished: Bool { jobs.contains(where: \.isFinished) }

    func clearCompleted() {
        jobs.removeAll { $0.status == .done || $0.status == .failed }
        // Batch-edit — drop removed rows from the selection.
        let live = Set(jobs.map(\.id))
        let pruned = selectedJobIDs.intersection(live)
        if pruned != selectedJobIDs { selectedJobIDs = pruned }
    }

    // MARK: - Settings edits (single job, batch, defaults)

    /// One settings edit. `sourceHasAlpha` is the target job's probed
    /// source alpha (nil for the defaults, or while the probe is pending)
    /// — only ProRes alpha-steering reads it.
    typealias SettingsEdit = (_ settings: inout JobSettings, _ sourceHasAlpha: Bool?) -> Void

    /// Apply `edit` to each of `ids` through the shared `JobSettings`
    /// rules. Locked rows (encoding / done) are skipped, and every rule
    /// is apply-where-applicable, so a mixed-codec batch only touches the
    /// rows a setting applies to. Refreshes the auto-name when codec /
    /// container changed (the helper still honours a manual rename).
    func applySettings<S: Sequence>(to ids: S, _ edit: SettingsEdit)
    where S.Element == EncodeJob.ID {
        let targets = Set(ids)
        var updated = jobs
        var renamed: [EncodeJob.ID] = []
        for i in updated.indices where targets.contains(updated[i].id) {
            guard updated[i].status == .queued || updated[i].status == .failed else { continue }
            let before = updated[i].settings
            var after = before
            edit(&after, updated[i].sourceHasAlpha)
            guard after != before else { continue }
            updated[i].settings = after
            if after.affectsAutoName(comparedTo: before) { renamed.append(updated[i].id) }
        }
        guard updated != jobs else { return }
        jobs = updated
        for id in renamed { refreshAutoNameIfNeeded(jobID: id) }
    }

    /// Single-job convenience for the job card.
    func applySettings(to id: EncodeJob.ID, _ edit: SettingsEdit) {
        applySettings(to: [id], edit)
    }

    /// The top settings bar's target: the selection when ≥2 rows are
    /// selected, otherwise the defaults for new files.
    func applyFromSettingsBar(_ edit: SettingsEdit) {
        if isBatchSelection {
            applySettings(to: selectedJobIDs, edit)
        } else {
            var s = defaultSettings
            edit(&s, nil)
            defaultSettings = s
        }
    }

    /// Batch-edit / defaults parity — the full default settings for new
    /// files, as one value. DXV/HAP format is owned by `defaultTier` ×
    /// `defaultAlpha`; the rest persists through `AppSettings`.
    var defaultSettings: JobSettings {
        get {
            let s = AppSettings.shared
            let format = DXVFormat(tier: defaultTier, alpha: defaultAlpha)
            var codec = s.defaultOutputCodec
            if case .dxv = codec { codec = .dxv(format) }
            let container = codec.allowedContainers.contains(s.defaultOutputContainer)
                ? s.defaultOutputContainer : .mov
            var r = JobSettings(format: format,
                                outputCodec: codec,
                                outputContainer: container,
                                videoSettings: s.defaultVideoSettings,
                                hapChunks: s.defaultHapChunks,
                                audioEnabled: s.defaultAudioEnabled,
                                audioRate: s.defaultAudioRate,
                                outputSize: defaultOutputSize,
                                resizeQuality: defaultResizeQuality,
                                aspectMode: defaultAspectMode,
                                sourceAlphaType: s.defaultSourceAlphaType)
            r.clampAudioRateToContainer()
            return r
        }
        set {
            let s = AppSettings.shared
            if defaultTier != newValue.format.qualityTier { defaultTier = newValue.format.qualityTier }
            if defaultAlpha != newValue.format.alphaMode { defaultAlpha = newValue.format.alphaMode }
            if s.defaultOutputCodec != newValue.outputCodec { s.defaultOutputCodec = newValue.outputCodec }
            if s.defaultOutputContainer != newValue.outputContainer { s.defaultOutputContainer = newValue.outputContainer }
            if s.defaultVideoSettings != newValue.videoSettings { s.defaultVideoSettings = newValue.videoSettings }
            if s.defaultHapChunks != newValue.hapChunks { s.defaultHapChunks = newValue.hapChunks }
            if s.defaultAudioEnabled != newValue.audioEnabled { s.defaultAudioEnabled = newValue.audioEnabled }
            if s.defaultAudioRate != newValue.audioRate { s.defaultAudioRate = newValue.audioRate }
            if defaultOutputSize != newValue.outputSize { defaultOutputSize = newValue.outputSize }
            if defaultResizeQuality != newValue.resizeQuality { defaultResizeQuality = newValue.resizeQuality }
            if defaultAspectMode != newValue.aspectMode { defaultAspectMode = newValue.aspectMode }
            if s.defaultSourceAlphaType != newValue.sourceAlphaType { s.defaultSourceAlphaType = newValue.sourceAlphaType }
            objectWillChange.send()
        }
    }

    // MARK: - Encode dispatch

    /// Encode every queued job in serial order. Spawns one
    /// detached Task and tracks it on `outerTask`; per-job Tasks
    /// are tracked on `currentTask` for fine-grained cancel.
    ///
    /// Both `outerTask` and `currentTask` are `Task.detached` —
    /// not bare `Task { … }` — because this class is `@MainActor`,
    /// so a bare `Task` would inherit MainActor isolation and run
    /// the synchronous BC1/BC4 encode work on the main thread.
    /// At 4K × 150 frames that's 10–20 minutes of blocked UI
    /// (Cancel button unresponsive, no redraw). `Task.detached`
    /// opts out of inheritance and runs the encode on the
    /// cooperative thread pool; the per-frame progress callback
    /// hops back to `MainActor` for the UI update only.
    func encodeAll() {
        guard !isEncoding else { return }
        let queuedIDs = jobs.filter { $0.status == .queued }.map { $0.id }
        guard !queuedIDs.isEmpty else { return }

        // v0.9.2 Phase G — fresh session, no apply-to-all carried
        // over from a previous batch.
        sessionCollisionOverride = nil

        isEncoding = true
        outerTask = Task.detached { [weak self] in
            for id in queuedIDs {
                guard let self = self else { break }
                // Guard against the queue being cancelled between
                // jobs — `cancelAll()` flips this via `outerTask`'s
                // cancellation propagating here.
                if Task.isCancelled {
                    await MainActor.run {
                        if let i = self.jobs.firstIndex(where: { $0.id == id }),
                           self.jobs[i].status == .queued {
                            self.jobs[i].status = .failed
                            self.jobs[i].errorMessage = "Cancelled"
                        }
                    }
                    continue
                }
                // Skip jobs that were already cancelled while
                // queued (e.g. user clicked the row's cancel).
                let stillQueued = await MainActor.run {
                    self.jobs.first(where: { $0.id == id })?.status == .queued
                }
                guard stillQueued else { continue }
                await self.runOneJob(id: id)
            }
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                self.isEncoding = false
                self.currentTask = nil
                self.currentJobID = nil
                self.outerTask = nil
            }
        }
    }

    /// Cancel one job. If the job is currently encoding, cancels
    /// the in-flight Task (loose cancel — finishes current frame,
    /// then exits). If `.queued`, marks `.failed` immediately so
    /// the encode loop skips it.
    func cancel(id: UUID) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        switch jobs[i].status {
        case .queued:
            jobs[i].status = .failed
            jobs[i].errorMessage = "Cancelled"
        case .encoding:
            currentTask?.cancel()
        case .done, .failed:
            // No-op — already terminal.
            break
        }
    }

    /// Cancel everything. The in-flight Task is cancelled (finishes
    /// current frame, exits as `.failed`). All remaining `.queued`
    /// jobs are marked `.failed` immediately. The outer encode loop
    /// notices and unwinds via its `Task.isCancelled` check.
    func cancelAll() {
        outerTask?.cancel()
        currentTask?.cancel()
        for i in jobs.indices where jobs[i].status == .queued {
            jobs[i].status = .failed
            jobs[i].errorMessage = "Cancelled"
        }
    }

    // MARK: - Per-job encode

    /// Run one job to completion (or cancellation). Spawns the
    /// per-job Task so `cancel(id:)` has something to cancel.
    /// `Task.detached` (not bare `Task { … }`) because this class
    /// is `@MainActor`; see the comment on `encodeAll`.
    private func runOneJob(id: UUID) async {
        let task = Task.detached { [weak self] in
            await self?.encodeOne(id: id)
            return ()
        }
        currentTask = task
        currentJobID = id
        await task.value
        currentTask = nil
        currentJobID = nil
    }

    private func encodeOne(id: UUID) async {
        guard let snapshot = await MainActor.run(body: {
            self.jobs.first(where: { $0.id == id })
        }) else { return }

        // Phase 7B-a — respect the user's persisted output-location
        // preference. `.fixed` with a valid, writable directory uses
        // that path; everything else falls back to the source's
        // folder (same-as-source — pre-Phase-7B-a behavior).
        // EncodeQueue is @MainActor, so AppSettings.shared reads are
        // in-context (no MainActor.run wrappers needed).
        let initialOutURL = await MainActor.run { self.plannedOutputURL(for: snapshot) }

        // v0.9.2 Phase G — collision resolution at write-start.
        // TOCTOU-safe: each job in the sequential batch resolves
        // AFTER prior jobs have written, so same-named jobs end up
        // as (.mov, _2.mov, _3.mov, …) rather than racing for _2.
        let collisionPolicy = AppSettings.shared.collisionPolicy
        // v1.5.0 (G1) — a re-run never prompts: first free `_N` against
        // the disk AND the names other queued / encoding jobs will write.
        let resolved: CollisionResolution
        if snapshot.isRerun {
            let claimed = await MainActor.run { self.claimedOutputPaths(excluding: id) }
            resolved = .proceed(AutoNameEngine.firstFreeNumberedURL(initialOutURL) { url in
                claimed.contains(url.standardizedFileURL.path)
                    || FileManager.default.fileExists(atPath: url.path)
            })
        } else {
            resolved = await resolveCollision(
                initialOutURL: initialOutURL,
                policy: collisionPolicy,
                jobID: id)
        }
        let outURL: URL
        switch resolved {
        case .proceed(let url):
            outURL = url
        case .skipJob:
            await MainActor.run {
                if let i = self.jobs.firstIndex(where: { $0.id == id }) {
                    self.jobs[i].status = .failed
                    self.jobs[i].errorMessage = "Skipped — output exists"
                }
            }
            print("[GlEnc] skipped (collision): \(initialOutURL.lastPathComponent)")
            return
        case .cancelSession:
            // User chose Cancel from the collision prompt — bail this
            // job AND trip the outer encodeAll Task so remaining
            // queued jobs don't run.
            await MainActor.run {
                if let i = self.jobs.firstIndex(where: { $0.id == id }) {
                    self.jobs[i].status = .failed
                    self.jobs[i].errorMessage = "Cancelled"
                }
                self.outerTask?.cancel()
            }
            print("[GlEnc] cancelled (collision): \(initialOutURL.lastPathComponent)")
            return
        }

        // If the resolved URL differs from what the job is currently
        // showing, update the row so the user sees the actual filename.
        if outURL != initialOutURL {
            await MainActor.run {
                if let i = self.jobs.firstIndex(where: { $0.id == id }) {
                    if self.jobs[i].preCollisionName == nil {
                        self.jobs[i].preCollisionName = self.jobs[i].outputName
                    }
                    self.jobs[i].outputName = outURL.lastPathComponent
                    self.jobs[i].outputNameOverridden = true
                }
            }
        }

        await MainActor.run {
            if let i = self.jobs.firstIndex(where: { $0.id == id }) {
                self.jobs[i].status = .encoding
                self.jobs[i].progress = 0
                self.jobs[i].errorMessage = nil
                self.jobs[i].isRerun = false
            }
        }
        print("[GlEnc] encoding: \(snapshot.sourceURL.path) → \(outURL.path)")

        // Test-hook short-circuit. When the hook is set, replace
        // the real pipeline with the test closure. Same result-
        // marking logic on either side.
        if let hook = _testEncodeJobHook {
            do {
                let resultURL = try await hook(snapshot)
                await MainActor.run {
                    if let i = self.jobs.firstIndex(where: { $0.id == id }) {
                        self.jobs[i].status = .done
                        self.jobs[i].progress = 1.0
                        self.jobs[i].outputURL = resultURL
                    }
                }
            } catch is CancellationError {
                // Phase 7A Finding 5: same cleanup as the real-pipeline
                // path. Test hooks can write partial outputs too; tests
                // assert no leftover file on disk.
                try? FileManager.default.removeItem(at: outURL)
                await MainActor.run {
                    if let i = self.jobs.firstIndex(where: { $0.id == id }) {
                        self.jobs[i].status = .failed
                        self.jobs[i].errorMessage = "Cancelled"
                    }
                }
            } catch {
                try? FileManager.default.removeItem(at: outURL)
                await MainActor.run {
                    if let i = self.jobs.firstIndex(where: { $0.id == id }) {
                        self.jobs[i].status = .failed
                        self.jobs[i].errorMessage = String(describing: error)
                    }
                }
            }
            return
        }

        // Real encode path.
        do {
            // Phase 8C-a — resolve trim into a half-open Range<Int>
            // for EncodePipeline. We don't know totalFrames until the
            // pipeline opens the reader; for resolving the trim window
            // we use the user-supplied bounds verbatim, falling back
            // to nil-side defaults inside EncodePipeline (which clamps
            // to totalFrames when known). Swap-tolerant via
            // resolvedTrimRange. Pass nil when no trim is set so the
            // existing full-clip path runs unchanged.
            let pipelineFrameRange: Range<Int>?
            if snapshot.isTrimmed {
                // We don't have totalFrames yet — use Int.max as a
                // sentinel upper bound for the un-set side and let
                // EncodePipeline clamp at run() time.
                let bigN = Int.max / 2  // avoid overflow in min() inside pipeline
                let (lo, hi) = snapshot.resolvedTrimRange(totalFrames: bigN)
                // Half-open exclusive upper.
                pipelineFrameRange = lo..<(hi + 1)
                print("[GlEnc] trim active: encoding source frames \(lo)..\(hi) inclusive")
            } else {
                pipelineFrameRange = nil
            }

            // Shared progress callback — identical across codec paths.
            let progressCb: EncodePipeline.ProgressCallback = { [weak self] p in
                Task { @MainActor in
                    guard let self = self,
                          let i = self.jobs.firstIndex(where: { $0.id == id }) else { return }
                    self.jobs[i].progress = p
                }
            }

            // Phase 4 — read source audio ONCE (track-level, off the video
            // path) when the job carries it. nil → no audio track / stripped
            // / read failed → sinks built with no audio = pre-audio bytes.
            // The DXV path's byte-identity holds because DXVEncoderSink with
            // audio == nil never attaches an audio trak.
            var audioData: (info: AudioStreamInfo, pcm: Data)? = nil
            // Fix-Brief 2 — non-fatal audio warning. Set when audio was
            // enabled and the source HAS a track but audio couldn't be
            // produced correctly; the video still ships and the row surfaces
            // this. Stays nil when the source genuinely has no audio.
            var audioWarning: String? = nil
            if snapshot.audioEnabled, snapshot.sourceHasAudio != false {
                // AAC (.mp4) caps at 48 kHz: clamp the requested rate so audio
                // is RESAMPLED DOWN (via the reader) rather than silently
                // dropped by the AAC sink. Explicit >48k → 48k here; a >48k
                // Original source is caught by the post-read re-clamp below.
                let cap = snapshot.outputContainer.maxAudioSampleRate
                let firstTarget: Int? = snapshot.audioRate.hz.map { min($0, cap) }
                do {
                    // A1 — was `try?` (swallowed). Now surfaced: a track that
                    // passes the existence probe but throws on decode
                    // (corrupt/unsupported ASBD, bad channel count, undetermin-
                    // able rate) becomes a warning, not a silent audio-less file.
                    var read = try await SourceAudioReader.readInterleavedPCM(
                        snapshot.sourceURL, targetRate: firstTarget)
                    if let r = read, r.info.sampleRate > cap {
                        // >cap source for a capped container (AAC/.mp4): must
                        // resample down. A2 — if the re-clamp read fails, the
                        // source-rate audio can't feed the capped sink (it
                        // would trip the canApply hard-error). Drop audio +
                        // warn (keep the video) rather than hard-fail.
                        if let reread = try? await SourceAudioReader.readInterleavedPCM(
                                snapshot.sourceURL, targetRate: cap) {
                            read = reread
                        } else {
                            read = nil
                            audioWarning = "Audio unavailable: couldn't resample \(r.info.sampleRate) Hz down to the container's \(cap) Hz limit"
                        }
                    }
                    if let read = read, !read.pcm.isEmpty {
                        audioData = (read.info, read.pcm)
                        print("[GlEnc] audio: \(read.info.channels)ch @ \(read.info.sampleRate)Hz, \(read.frameCount) frames (container max \(cap == Int.max ? "—" : String(cap)))")
                    }
                    // read == nil (no track) or empty PCM (zero-frame track) →
                    // no audio, no warning: the source genuinely produced none.
                } catch {
                    // A1 / C (unsupported channels) / D (undeterminable rate):
                    // keep the video, surface the reason on the job.
                    audioWarning = "Audio unavailable: \(error)"
                }
            }

            // Multi-format dispatch lives in GlEncCore (CoreEncoder) so the
            // GUI and glenc-cli share ONE encode path — no duplicated encode
            // logic (the GlanceCore-inside-glance pattern). Byte-identical to
            // the pre-extraction inline switch; the 595-test suite is the gate.
            //
            // Fix-Brief 2 (B) — capture the built sink so we can read its
            // post-run `audioWarning` (an audio-write failure the sink
            // recorded while keeping the video). The sink is built during
            // `pipeline.run()`, read after it returns.
            var builtSink: FrameSink?
            let request = EncodeRequest(
                sourceURL: snapshot.sourceURL,
                outputURL: outURL,
                codec: snapshot.outputCodec,
                container: snapshot.outputContainer,
                videoSettings: snapshot.videoSettings,
                // Resize Release Phase E/G + Crop Release Phase F — the
                // per-job transform knobs flow straight through to the
                // pipeline. `.original` / nil are the byte-identical no-ops.
                outputSize: snapshot.outputSize,
                resizeQuality: snapshot.resizeQuality,
                aspectMode: snapshot.aspectMode,
                cropRect: snapshot.cropRect,
                frameRange: pipelineFrameRange,
                // v0.9.2 Phase D.5 — bundle-derived writer-version string for
                // the udta/©swr "Encoding software" atom.
                writerVersion: AppVersion.writerVersion,
                // Slice 4 — per-job HAP chunk count. 1 (default) keeps the
                // single-section path byte-identical; the library ignores it
                // for non-HAP formats.
                hapChunks: snapshot.hapChunks,
                // v1.6.0 — the source's Alpha Type (DXV sources only).
                sourceAlphaType: snapshot.sourceAlphaType)
            let pipeline = try CoreEncoder.makePipeline(
                request,
                audio: audioData,
                progress: progressCb,
                onSinkBuilt: { builtSink = $0 })
            try await pipeline.run()

            // Fix-Brief 2 — merge the read-side warning (A1/A2/C/D) with any
            // write-side warning the sink recorded (B). Read-side takes
            // precedence (it's the earlier failure). Surfaced on the .done job.
            let finalAudioWarning = audioWarning ?? builtSink?.audioWarning
            await MainActor.run {
                if let i = self.jobs.firstIndex(where: { $0.id == id }) {
                    self.jobs[i].status = .done
                    self.jobs[i].progress = 1.0
                    self.jobs[i].outputURL = outURL
                    self.jobs[i].audioWarning = finalAudioWarning
                }
            }
            if let w = finalAudioWarning { print("[GlEnc] done (audio warning): \(w)") }
            print("[GlEnc] done:    \(outURL.path)")
        } catch is CancellationError {
            print("[GlEnc] cancel:  \(snapshot.sourceURL.lastPathComponent)")
            // Phase 7A Finding 5: partial output left after pipeline
            // throw is a corrupt ftyp/wide/mdat-no-moov file (writer.finish()
            // never ran). Delete it so the user sees "Failed" + nothing
            // on disk, not a misleading artifact.
            try? FileManager.default.removeItem(at: outURL)
            await MainActor.run {
                if let i = self.jobs.firstIndex(where: { $0.id == id }) {
                    self.jobs[i].status = .failed
                    self.jobs[i].errorMessage = "Cancelled"
                }
            }
        } catch {
            print("[GlEnc] failed:  \(snapshot.sourceURL.lastPathComponent): \(error)")
            // Phase 7A Finding 5: partial output left after pipeline
            // throw is a corrupt ftyp/wide/mdat-no-moov file (writer.finish()
            // never ran). Delete it so the user sees "Failed" + nothing
            // on disk, not a misleading artifact.
            try? FileManager.default.removeItem(at: outURL)
            await MainActor.run {
                if let i = self.jobs.firstIndex(where: { $0.id == id }) {
                    self.jobs[i].status = .failed
                    self.jobs[i].errorMessage = String(describing: error)
                }
            }
        }
    }

    // MARK: - v0.9.2 Phase G — collision resolution

    /// Outcome of the per-job collision check. Drives the dispatch
    /// inside `encodeOne` AFTER `initialOutURL` is computed and
    /// BEFORE any writer is constructed.
    private enum CollisionResolution {
        /// Proceed with this URL (either the original, or a renamed one).
        case proceed(URL)
        /// Skip this job (user picked Skip from the .ask prompt).
        case skipJob
        /// Cancel the entire batch (user picked Cancel from the prompt).
        case cancelSession
    }

    /// Apply the current CollisionPolicy to a candidate output URL.
    /// For .ask, this awaits the user's choice via the SwiftUI alert
    /// (suspending the encode queue's serial loop until they respond);
    /// other policies resolve synchronously.
    private func resolveCollision(initialOutURL: URL,
                                  policy: AppSettings.CollisionPolicy,
                                  jobID: UUID) async -> CollisionResolution {
        let exists = FileManager.default.fileExists(atPath: initialOutURL.path)
        guard exists else { return .proceed(initialOutURL) }

        // Apply-to-all override set by a previous prompt in this
        // encodeAll session.
        if let override = sessionCollisionOverride {
            return applyDecision(base: override, initialOutURL: initialOutURL)
        }

        switch policy {
        case .overwrite:
            return .proceed(initialOutURL)
        case .autoRename:
            return .proceed(AutoNameEngine.collisionFreeURL(initialOutURL))
        case .ask:
            // Present the SwiftUI alert; suspend the queue's serial
            // loop until the user resolves it. ContentView observes
            // `pendingCollisionPrompt` and renders the alert; the
            // alert's button actions resolve the continuation here.
            let suggested = AutoNameEngine.collisionFreeURL(initialOutURL)
            let (decision, applyToAll) = await withCheckedContinuation {
                (cont: CheckedContinuation<(CollisionDecision, Bool), Never>) in
                let prompt = CollisionPrompt(
                    jobID: jobID,
                    existingURL: initialOutURL,
                    suggestedRename: suggested,
                    continuation: cont)
                Task { @MainActor in
                    self.pendingCollisionPrompt = prompt
                }
            }
            // Clear the prompt now that the user has resolved it.
            await MainActor.run { self.pendingCollisionPrompt = nil }
            // Cache the decision for the rest of this session if the
            // user checked "Apply to all".
            if applyToAll {
                switch decision {
                case .overwrite:    sessionCollisionOverride = .overwrite
                case .rename:       sessionCollisionOverride = .autoRename
                case .skip:         sessionCollisionOverride = .skip
                case .cancel:       break  // cancel doesn't apply-to-all
                }
            }
            switch decision {
            case .overwrite:        return .proceed(initialOutURL)
            case .rename(let url):  return .proceed(url)
            case .skip:             return .skipJob
            case .cancel:           return .cancelSession
            }
        }
    }

    private func applyDecision(base: CollisionDecisionBase,
                               initialOutURL: URL) -> CollisionResolution {
        switch base {
        case .overwrite:  return .proceed(initialOutURL)
        case .autoRename: return .proceed(AutoNameEngine.collisionFreeURL(initialOutURL))
        case .skip:       return .skipJob
        }
    }
}

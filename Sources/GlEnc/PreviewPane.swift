// SPDX-License-Identifier: MIT
import SwiftUI
import AppKit
import GlEncCore

/// Phase 8B-c preview pane. Right side of the main window. Live
/// playback of the currently-selected job's source or output via the
/// Glance `DXVPlayer` + `DXVRenderer` stack.
///
/// State flow:
///   - Selection or previewSide change → `loadKey` changes → the
///     `.task(id:)` modifier on `PreviewArea` reloads the player
///     against the new URL.
///   - `PreviewPlayerModel` decodes frames and posts them to the
///     `PreviewLayerHostingNSView` via outbound closures; the
///     layer's CAOpenGLLayer redraws on each vsync.
///   - `currentFrame` is mirrored to a `@Published` on the model and
///     surfaces in the footer counter.
///
/// Scrub bar + transport buttons + keyboard shortcuts land in 8B-d.
/// For 8B-c, the player auto-plays on load with no user-facing
/// controls (FrameClock handles loop-at-end internally).
struct PreviewPane: View {
    @EnvironmentObject var queue: EncodeQueue
    @StateObject private var model = PreviewPlayerModel()

    var body: some View {
        VStack(spacing: 0) {
            if let job = queue.selectedJob {
                PreviewHeader(job: job)
                PreviewArea(job: job, model: model)
                PreviewTransport(model: model)
            } else {
                emptyState
            }
        }
        .frame(minWidth: 320)
        .background(Color(NSColor.windowBackgroundColor))
        // Phase 8C-a — sync model trim ↔ selected job trim.
        // When selection changes, pull the job's saved trim into the
        // model so the ScrubBar reflects it. When the user edits in/out
        // via the ScrubBar or I/O keys, the model's published values
        // change and we push them back onto the job.
        .onChange(of: queue.selectedJobID) { _, _ in
            syncJobTrimToModel()
        }
        .onChange(of: model.inFrame) { _, newValue in
            syncModelTrimToJob(inFrame: newValue, outFrame: model.outFrame)
        }
        .onChange(of: model.outFrame) { _, newValue in
            syncModelTrimToJob(inFrame: model.inFrame, outFrame: newValue)
        }
        // Phase 8C-b-fix — when the preview player finishes loading,
        // its `frameRate` becomes non-zero. Push that into the
        // selected job so the AutoNameEngine can produce MM-SS.CC
        // time brackets. Refresh the auto-name immediately so trim
        // brackets (if any are set) flip from the `00-00.00`
        // placeholder to real times.
        .onChange(of: model.frameRate) { _, newFPS in
            guard newFPS > 0,
                  let job = queue.selectedJob,
                  let idx = queue.jobs.firstIndex(where: { $0.id == job.id })
            else { return }
            if queue.jobs[idx].sourceFPS != newFPS {
                queue.jobs[idx].sourceFPS = newFPS
                queue.refreshAutoNameIfNeeded(jobID: queue.jobs[idx].id)
            }
        }
        .onAppear {
            // Catch the initial-selection case where the queue already
            // has a selected row before this view first renders.
            syncJobTrimToModel()
        }
    }

    private func syncJobTrimToModel() {
        guard let job = queue.selectedJob else {
            model.inFrame = nil
            model.outFrame = nil
            return
        }
        if model.inFrame != job.inFrame { model.inFrame = job.inFrame }
        if model.outFrame != job.outFrame { model.outFrame = job.outFrame }
    }

    private func syncModelTrimToJob(inFrame: Int?, outFrame: Int?) {
        guard let job = queue.selectedJob,
              let idx = queue.jobs.firstIndex(where: { $0.id == job.id }) else { return }
        var trimChanged = false
        if queue.jobs[idx].inFrame != inFrame {
            queue.jobs[idx].inFrame = inFrame
            trimChanged = true
        }
        if queue.jobs[idx].outFrame != outFrame {
            queue.jobs[idx].outFrame = outFrame
            trimChanged = true
        }
        // Phase 8C-b — refresh auto-name when the trim window changes
        // (unless the user has manually edited it).
        if trimChanged {
            queue.refreshAutoNameIfNeeded(jobID: queue.jobs[idx].id)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "play.rectangle")
                .font(.system(size: 48, weight: .light))
                .foregroundColor(.secondary.opacity(0.4))
            Text("Select a queue row to preview")
                .foregroundColor(.secondary)
                .font(.callout)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Header (file name + Source/Output toggle)

private struct PreviewHeader: View {
    let job: EncodeJob
    @EnvironmentObject var queue: EncodeQueue

    private var outputAvailable: Bool {
        guard job.status == .done else { return false }
        if let url = job.outputURL { return FileManager.default.fileExists(atPath: url.path) }
        return FileManager.default.fileExists(atPath: job.defaultOutputURL.path)
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(displayedFileName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(displayedSubtitle)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Picker("", selection: previewSideBinding) {
                Text("Source").tag(EncodeJob.PreviewSide.source)
                Text("Output").tag(EncodeJob.PreviewSide.output)
            }
            .pickerStyle(.segmented)
            .frame(width: 140)
            .disabled(!outputAvailable)
            .help(outputAvailable
                  ? "Toggle between source and encoded output"
                  : "Output preview becomes available once encoding finishes")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var displayedFileName: String {
        switch effectivePreviewSide {
        case .source: return job.sourceURL.lastPathComponent
        case .output:
            let url = job.outputURL ?? job.defaultOutputURL
            return url.lastPathComponent
        }
    }

    private var displayedSubtitle: String {
        switch effectivePreviewSide {
        case .source: return "Source"
        case .output: return "Encoded output"
        }
    }

    private var effectivePreviewSide: EncodeJob.PreviewSide {
        if job.previewSide == .output && outputAvailable { return .output }
        return .source
    }

    private var previewSideBinding: Binding<EncodeJob.PreviewSide> {
        Binding(
            get: { effectivePreviewSide },
            set: { newValue in
                guard let i = queue.jobs.firstIndex(where: { $0.id == job.id }) else { return }
                if newValue == .output && !outputAvailable { return }
                queue.jobs[i].previewSide = newValue
            }
        )
    }
}

// MARK: - Live-playback area

private struct PreviewArea: View {
    let job: EncodeJob
    @ObservedObject var model: PreviewPlayerModel
    @EnvironmentObject var queue: EncodeQueue
    /// Crop Release Phase E.5 — observed for `showClipBoundary`.
    /// `.shared` access matches ContentView / PreferencesWindow.
    @ObservedObject private var settings: AppSettings = .shared

    /// Crop Release Phase E — keyboard focus of the preview pane.
    /// Acquired by clicking into the pane while crop edit is active;
    /// gates the arrow-key crop nudge and lights the focused-state
    /// border. Mouse drag on the crop overlay is INDEPENDENT of this
    /// — drag works whenever edit mode is active, focused or not.
    @FocusState private var previewFocused: Bool

    /// True when this (selected) job is the row currently in crop-
    /// edit mode — the overlay is interactive.
    private var isCropEditing: Bool {
        queue.cropEditingJobID == job.id
    }

    /// True when this selected job has a committed crop and no edit
    /// is in flight — the overlay renders the passive dim-mask viz
    /// (CROP_PLAN.md Q2).
    private var showsPassiveCrop: Bool {
        queue.cropEditingJobID == nil && job.cropRect != nil
    }

    private var targetURL: URL {
        switch job.previewSide {
        case .source: return job.sourceURL
        case .output: return job.outputURL ?? job.defaultOutputURL
        }
    }

    /// `task(id:)` re-runs when this ID changes — so flipping the
    /// side toggle, selecting a different row, or a previously-failed
    /// encode completing all trigger a fresh `model.load(url:)`.
    private var loadKey: String {
        "\(job.id.uuidString)|\(job.previewSide.rawValue)|\(job.status.rawValue)"
    }

    var body: some View {
        ZStack {
            Color.black
            // GL layer host. Always installed so the layer is in the
            // tree even before the player has a frame.
            PreviewLayerHosting(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            switch model.playState {
            case .loading:
                ProgressView().controlSize(.small)
            case .failed(let msg):
                VStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 24))
                        .foregroundColor(.orange)
                    Text(msg)
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
            case .empty, .playing, .paused:
                EmptyView()
            }

            // Phase 8B-c had a frame-counter overlay here; 8B-d moves
            // it to the transport footer below the preview area for a
            // cleaner image canvas.

            // Crop overlay (Crop Release Phase E / E.5) — layered on
            // top of the GL layer, mounted whenever source dims are
            // known. Phase E.5 widened the mount from "editing OR has
            // a crop" to "source loaded" so the clip-boundary outline
            // can show for every clip. The four flags are independent:
            // isActive (crop edit interactive), showDimMask (passive
            // non-edit viz), showClipBoundary (the faint source-frame
            // outline). In the default case — no crop, no edit — only
            // the clip boundary draws. The CropAspectFit is rebuilt
            // per layout pass from the GeometryReader's size.
            if model.sourceWidth > 0, model.sourceHeight > 0 {
                GeometryReader { geo in
                    let fit = CropAspectFit(
                        sourceWidth: model.sourceWidth,
                        sourceHeight: model.sourceHeight,
                        viewRect: CGRect(origin: .zero, size: geo.size))
                    CropOverlayView(
                        aspectFit: fit,
                        cropRectInSource: isCropEditing
                            ? $queue.pendingCropRect
                            : .constant(job.cropRect),
                        isActive: isCropEditing,
                        alignment: job.outputCodec.dimensionAlignment,
                        showDimMask: showsPassiveCrop,
                        showClipBoundary: settings.showClipBoundary,
                        isFocused: previewFocused,
                        focusedCorner: $queue.focusedCropCorner)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Crop Release Phase E — the pane is focusable only while
        // crop edit is active, so it never steals focus or shadows
        // PreviewTransport's transport keys outside an edit session.
        .focusable(isCropEditing)
        .focused($previewFocused)
        // Suppress AppKit's default focus ring — `.focusable()` would
        // otherwise draw its own system highlight ON TOP of the custom
        // border below (the "two borders"), and that system ring is
        // drawn partly outside the view bounds, so it both clips at
        // the window edge and visibly jumps. The custom overlay is the
        // single, deterministic focus indicator.
        .focusEffectDisabled()
        .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow]) { press in
            handleCropNudge(press)
        }
        // Crop Release Phase E.10 — Escape steps back through nested
        // edit states. With a focused corner, first Escape clears
        // focus and consumes the key (the user stays in edit mode).
        // Without a focused corner, Escape falls through to
        // JobCardView's Cancel button (.keyboardShortcut(.cancelAction))
        // which cancels the edit. Two-step semantic matches macOS
        // convention.
        .onKeyPress(.escape) {
            if queue.focusedCropCorner != nil {
                queue.focusedCropCorner = nil
                return .handled
            }
            return .ignored
        }
        // Crop Release Phase E.5 — the focus cue is the crop rect's
        // accent-colored stroke (passed as `isFocused` to
        // CropOverlayView), not a full-rectangle border. The click-
        // test found the Phase E border too cluttered stacked with
        // the clip-boundary lines. `.focusEffectDisabled()` above
        // still suppresses AppKit's own ring.
        .task(id: loadKey) {
            loadIfNeeded()
        }
        .onDisappear {
            model.unload()
        }
        // Fix-Brief B — the crop editor's numeric clamp now reads the
        // authoritative probe-time dims off `EncodeJob`; the old
        // publish-dims-from-the-live-preview channel is retired (the DRAG
        // overlay still uses `model.sourceWidth`, which it legitimately
        // needs — it operates on the decoded frame).
    }

    /// Arrow-key crop nudge (CROP_PLAN.md Q4) — translates the whole
    /// pending crop rect by 4 px per press, 16 px with Shift held.
    /// Fires only while this job is being crop-edited AND the preview
    /// pane has keyboard focus; returns `.ignored` otherwise so the
    /// key falls through. Left/right arrows are released by
    /// PreviewTransport's frame-step buttons during edit (their
    /// `.keyboardShortcut` goes nil) so there is no routing ambiguity.
    private func handleCropNudge(_ press: KeyPress) -> KeyPress.Result {
        guard isCropEditing, previewFocused,
              model.sourceWidth > 0, model.sourceHeight > 0 else {
            return .ignored
        }
        let step: CGFloat = press.modifiers.contains(.shift) ? 16 : 4
        let c = press.key.character
        let delta: CGSize
        if c == KeyEquivalent.upArrow.character {
            delta = CGSize(width: 0, height: -step)
        } else if c == KeyEquivalent.downArrow.character {
            delta = CGSize(width: 0, height: step)
        } else if c == KeyEquivalent.leftArrow.character {
            delta = CGSize(width: -step, height: 0)
        } else if c == KeyEquivalent.rightArrow.character {
            delta = CGSize(width: step, height: 0)
        } else {
            return .ignored
        }
        // Seed a full-frame rect if the user opened edit on an
        // uncropped job and has not dragged yet — an arrow press in a
        // focused edit session must not silently do nothing.
        // Codec-aware crop snap (1 = pixel-exact for ProRes/DXV/HAP/MJPEG).
        let align = queue.selectedJob?.outputCodec.dimensionAlignment ?? 1
        let base = queue.pendingCropRect
            ?? CropDragMath.fullFrameSeedRect(
                sourceWidth: model.sourceWidth,
                sourceHeight: model.sourceHeight,
                alignment: align)
        // Phase E.10 — dispatch on the queue's focused corner. With
        // a corner focused, arrows resize from that corner (opposite
        // pinned). Without one, arrows translate the whole rect (the
        // existing Phase E behavior).
        if let corner = queue.focusedCropCorner {
            queue.pendingCropRect = CropDragMath.snappedResizeFromCorner(
                rect: base,
                corner: corner,
                delta: CGVector(dx: delta.width, dy: delta.height),
                sourceWidth: model.sourceWidth,
                sourceHeight: model.sourceHeight,
                alignment: align)
        } else {
            queue.pendingCropRect = CropDragMath.snappedTranslatedRect(
                original: base,
                translationInSource: delta,
                sourceWidth: model.sourceWidth,
                sourceHeight: model.sourceHeight,
                alignment: align)
        }
        return .handled
    }

    @MainActor
    private func loadIfNeeded() {
        // Fix-Brief B — a job the add-time probe marked `.failed` (malformed
        // source: zero/oversized dims, no video track, …) must NOT load its
        // source into the live preview — that's exactly the garbage-render
        // we just stopped silently adding. Surface the failure (the row
        // shows its errorMessage), don't render it.
        guard previewShouldLoad(jobStatus: job.status) else {
            model.unload()
            return
        }
        // Guard the output-not-ready race the header gates against.
        let url = targetURL
        if job.previewSide == .output && !FileManager.default.fileExists(atPath: url.path) {
            model.unload()
            return
        }
        // Already loaded with the same URL? Skip the unload-reload
        // cycle to avoid restarting the FrameClock for no reason.
        if model.currentURL == url { return }
        model.load(url: url)
    }
}

// MARK: - Transport (Phase 8B-d): play/pause, step, scrub, loop

private struct PreviewTransport: View {
    @ObservedObject var model: PreviewPlayerModel
    @EnvironmentObject var queue: EncodeQueue

    private var isPlayable: Bool { model.totalFrames > 0 }

    /// Crop Release Phase E — while a crop edit is in flight the
    /// ← / → frame-step shortcuts are released (set nil) so the
    /// focused preview pane's crop nudge (CROP_PLAN.md Q4) owns the
    /// arrow keys with no routing ambiguity. The buttons stay
    /// clickable; only their keyboard equivalents drop out.
    private var stepBackShortcut: KeyboardShortcut? {
        queue.cropEditingJobID == nil
            ? KeyboardShortcut(.leftArrow, modifiers: []) : nil
    }
    private var stepForwardShortcut: KeyboardShortcut? {
        queue.cropEditingJobID == nil
            ? KeyboardShortcut(.rightArrow, modifiers: []) : nil
    }

    var body: some View {
        // v0.9.0.3 — two rows. Row 1: transport buttons + frame counter
        // + loop + trim-set buttons. Row 2: scrub bar at full width.
        // The scrub bar needs room for the trim handles' larger hit
        // targets — cramping it into the same row as the buttons
        // squeezed the handles to where they were hard to grab.
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                // Play / pause
                Button(action: { model.togglePause() }) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 22, height: 18)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.space, modifiers: [])
                .help(isPlaying ? "Pause (Space)" : "Play (Space)")
                .disabled(!isPlayable)

                // Step backward
                Button(action: { model.step(by: -1) }) {
                    Image(systemName: "backward.frame.fill")
                        .font(.system(size: 12))
                        .frame(width: 22, height: 18)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(stepBackShortcut)
                .help("Previous frame (←)")
                .disabled(!isPlayable || model.currentFrame <= 0)

                // Step forward
                Button(action: { model.step(by: 1) }) {
                    Image(systemName: "forward.frame.fill")
                        .font(.system(size: 12))
                        .frame(width: 22, height: 18)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(stepForwardShortcut)
                .help("Next frame (→)")
                .disabled(!isPlayable || model.currentFrame >= model.totalFrames - 1)

                Spacer()

                // Frame counter
                Text(frameLabel)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .monospacedDigit()

                Spacer()

                // Loop toggle
                Button(action: { model.loopEnabled.toggle() }) {
                    Image(systemName: model.loopEnabled ? "repeat" : "repeat.1")
                        .font(.system(size: 13))
                        .foregroundColor(model.loopEnabled ? .accentColor : .secondary)
                        .frame(width: 22, height: 18)
                }
                .buttonStyle(.borderless)
                .help(model.loopEnabled
                      ? "Loop on — playback wraps at end. Click to disable."
                      : "Loop off — playback stops at end. Click to enable.")
                .disabled(!isPlayable)

                // Phase 8C-a trim controls — Set In / Set Out / Clear.
                Divider().frame(height: 16)
                Button(action: { model.setInAtCurrentFrame() }) {
                    Image(systemName: "arrowtriangle.right.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.accentColor)
                        .frame(width: 22, height: 18)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("i", modifiers: [])
                .help("Set in-point at current frame (I)")
                .disabled(!isPlayable)

                Button(action: { model.setOutAtCurrentFrame() }) {
                    Image(systemName: "arrowtriangle.left.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.accentColor)
                        .frame(width: 22, height: 18)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("o", modifiers: [])
                .help("Set out-point at current frame (O)")
                .disabled(!isPlayable)

                Button(action: { model.clearTrim() }) {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .frame(width: 22, height: 18)
                }
                .buttonStyle(.borderless)
                .help("Clear trim (encode full clip)")
                .disabled(!isPlayable || (model.inFrame == nil && model.outFrame == nil))
            }

            // Scrub bar on its own row — full width so the trim handles
            // get all the horizontal space the pane can offer.
            ScrubBar(model: model)
                .frame(maxWidth: .infinity)
                .disabled(!isPlayable)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var isPlaying: Bool {
        if case .playing = model.playState { return true }
        return false
    }

    private var frameLabel: String {
        guard isPlayable else { return "—" }
        // v0.9.0.3 — HH:MM:SS:FF SMPTE timecode (matches the
        // TimecodePopover that the trim-edge double-click opens).
        let now = Timecode.string(frame: model.currentFrame, fps: model.frameRate)
        let total = Timecode.string(frame: max(0, model.totalFrames - 1), fps: model.frameRate)
        return "\(now) / \(total)"
    }
}

// MARK: - Preview-load gate (Fix-Brief B)

/// Whether the live preview should load a job's source. A job the add-time
/// probe marked `.failed` (malformed source) must not be rendered — the row
/// shows its `errorMessage` instead. Pure + file-scope so it is unit-testable
/// without the SwiftUI runtime (mirrors `cropClampSourceDims` / `cropFieldDidEdit`).
func previewShouldLoad(jobStatus: EncodeJob.Status) -> Bool {
    jobStatus != .failed
}

// SPDX-License-Identifier: MIT
import SwiftUI
import AppKit
import GlEncCore

/// v0.9.0.3 — per-job card layout for the queue list. Replaces the
/// previous `Table` (TableColumn × 7) approach. The Table truncated
/// filename + output-name on narrow window widths, which gutted the
/// rename feature's value. This 4-row card renders every field at
/// full width regardless of window size.
///
/// Layout:
///   1. Filename (lineLimit 1 with middle truncation — but the row
///      gets the whole card width, so wrapping rarely fires) + status
///      / progress + action buttons (Cancel / Retry / Show + Remove).
///   2. Codec controls (Quality picker + Alpha picker).
///   3. Trim info (no-trim placeholder or in→out display in the
///      user's chosen format — time or frame indices).
///   4. Output name — full-width OutputNameCell with the existing
///      editable TextField + reset (↻) button.
///
/// Selection: managed by the parent `List(selection: $queue.selectedJobID)`.
/// Disable: codec / output editing locked while `status == .encoding`.
struct JobCardView: View {
    let job: EncodeJob
    @ObservedObject var queue: EncodeQueue
    /// Phase H — observe AppSettings so the per-row Size menu
    /// re-renders when `customPresets` changes (add via Save in the
    /// Custom sheet, remove via Manage Sizes…).
    @ObservedObject private var settings: AppSettings = .shared

    /// Resize Release Phase F — Custom-size sheet presentation flag.
    /// Toggled by the Output Size menu's "Custom…" entry. Reset
    /// when the sheet's Commit / Cancel fires.
    @State private var showingCustomSheet: Bool = false
    /// Phase H — Manage Sizes… sheet flag.
    @State private var showingManageSheet: Bool = false
    /// Multi-Format Phase 1 — per-job Advanced codec popover flag.
    @State private var showingAdvanced: Bool = false

    // MARK: - Crop edit-mode field state (Phase E.9)

    /// Phase E.9 — focus selector for the four rowCrop text fields.
    /// SwiftUI follows view source order for Tab, so the W → H → X →
    /// Y order in `cropFieldsHStack` IS the tab order.
    @FocusState private var focusedCropField: CropField?
    /// Phase E.9 — per-field displayed text. Decoupled from
    /// `queue.pendingCropRect` so that mouse-drag / arrow-nudge
    /// updates to the rect refresh the unfocused fields LIVE without
    /// stomping a focused field the user is mid-typing in (see
    /// `syncCropFieldStringsFromPending`).
    @State private var widthText: String = ""
    @State private var heightText: String = ""
    @State private var xText: String = ""
    @State private var yText: String = ""
    /// Fix-Brief A-2 — the focused crop field's text captured at the
    /// moment it gained focus. On focus-loss, a commit fires only if the
    /// field's text differs from this baseline (a real edit); a
    /// focus-in → focus-out with no typing commits and seeds NOTHING.
    /// `syncCropFieldStringsFromPending` skips the focused field, so this
    /// is the only reliable per-field no-edit reference while focused.
    @State private var cropFieldBaseline: String = ""
    /// Phase E.9 — orange-flash background per field. Set true when
    /// `commitCropFieldValue` returns `wasCorrected`, reverted to
    /// false 300ms later. Single feedback mechanism for all three
    /// correction kinds (round-to-4 / source-bounds / minimum).
    @State private var flashWidth: Bool = false
    @State private var flashHeight: Bool = false
    @State private var flashX: Bool = false
    @State private var flashY: Bool = false

    private var isMutable: Bool {
        job.status == .queued || job.status == .failed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            row1FilenameAndStatus
            row2Codec
            rowAudio
            rowResize
            rowCrop
            row3Trim
            row4Output
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .sheet(isPresented: $showingCustomSheet) {
            ResizeCustomSheet(
                initialWidth: currentCustomWidth ?? 1920,
                initialHeight: currentCustomHeight ?? 1080,
                alignment: job.outputCodec.dimensionAlignment,
                onCommit: { newSize in
                    outputSizeBinding.wrappedValue = newSize
                    showingCustomSheet = false
                },
                onCancel: {
                    showingCustomSheet = false
                })
        }
        .sheet(isPresented: $showingManageSheet) {
            ManageSizesSheet(settings: settings,
                              onClose: { showingManageSheet = false })
        }
    }

    /// Best-guess initial dims for the Custom sheet:
    ///   - If the job already has a .custom, reuse those dims.
    ///   - If the job has a .preset, use the preset's dims.
    ///   - Otherwise nil (sheet defaults to 1920×1080).
    private var currentCustomWidth: Int? {
        switch job.outputSize {
        case .original: return nil
        case .preset(let p): return p.dimensions.width
        case .custom(let w, _): return w
        }
    }
    private var currentCustomHeight: Int? {
        switch job.outputSize {
        case .original: return nil
        case .preset(let p): return p.dimensions.height
        case .custom(_, let h): return h
        }
    }

    // MARK: - Row 1: filename + status + actions

    private var row1FilenameAndStatus: some View {
        HStack(spacing: 8) {
            Text(job.sourceURL.lastPathComponent)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(job.sourceURL.path)
                .frame(maxWidth: .infinity, alignment: .leading)

            statusOrProgress
                .frame(minWidth: 80, maxWidth: 140)

            actionButtons
        }
    }

    @ViewBuilder
    private var statusOrProgress: some View {
        switch job.status {
        case .encoding:
            HStack(spacing: 4) {
                ProgressView(value: job.progress)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                Text(String(format: "%.0f%%", job.progress * 100))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
        case .done:
            // Fix-Brief 2 — a completed job whose AUDIO couldn't be produced
            // (video shipped fine) surfaces a clearly-visible warning here,
            // so the user sees "audio unavailable" without opening the file.
            if let warning = job.audioWarning {
                HStack(spacing: 3) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("Done · no audio")
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .font(.caption)
                .foregroundColor(.orange)
                .help(warning)
                .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                Text("Done")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        case .failed:
            Text(job.errorMessage ?? "Failed")
                .font(.caption)
                .foregroundColor(.red)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(job.errorMessage ?? "Failed")
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .queued:
            Text("Queued")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 4) {
            switch job.status {
            case .queued, .encoding:
                Button("Cancel") { queue.cancel(id: job.id) }
                    .controlSize(.small)
            case .failed:
                Button("Retry") { retry() }
                    .controlSize(.small)
            case .done:
                Button("Show") {
                    if let url = job.outputURL {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
                .controlSize(.small)
                .disabled(job.outputURL == nil)
            }
            Button(role: .destructive) {
                queue.removeJob(id: job.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(.borderless)
            .help("Remove from queue")
            .disabled(job.status == .encoding)
        }
    }

    // MARK: - Row 2: codec controls

    private var row2Codec: some View {
        // Borderless Menus (not Pickers) so the controls render flat
        // — no button-chrome background. Custom up/down chevron icon
        // placed BEFORE the label text; `.menuIndicator(.hidden)`
        // suppresses the system's default trailing indicator so we
        // don't get duplicates. Natural sizing lines the row up with
        // rows 1 / 3 / 4 at the card's left margin.
        // v0.9.3 Phase D: the HAP Q + With Alpha combination is now
        // selectable. Multi-Format Phase 1 restructured this into a
        // family→variant pair: the first menu picks the codec family
        // (DXV3 tiers + HAP + ProRes + H.264 + HEVC + Motion JPEG); the
        // second menu shows Alpha for the
        // DXV/HAP families (unchanged) and the ProRes variant list when
        // ProRes is selected. The outer `.disabled(!isMutable)` per
        // control locks editing while a row is .encoding or .done.
        HStack(spacing: 16) {
            // ── Codec family ──
            Menu {
                ForEach(QualityTier.allCases) { tier in
                    Button(tier.label) { selectDXVTier(tier) }
                }
                Divider()
                Button("ProRes") { selectProRes() }
                Button("H.264") { selectVideoCodec(.h264) }
                Button("HEVC") { selectVideoCodec(.hevc) }
                Button("Motion JPEG") { selectVideoCodec(.mjpeg) }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    Text(codecFamilyLabel)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(!isMutable)

            // ── Second menu: ProRes variant / H.264-HEVC container /
            //    DXV-HAP alpha ──
            if case .prores(let variant) = job.outputCodec {
                Menu {
                    ForEach(ProResVariant.allCases, id: \.self) { v in
                        Button(v.label) { setProResVariant(v) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                        Text(variant.label)
                    }
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(!isMutable)
            } else if job.outputCodec == .h264 || job.outputCodec == .hevc {
                // H.264/HEVC second menu = container (.mov / .mp4).
                Menu {
                    ForEach(job.outputCodec.allowedContainers, id: \.self) { c in
                        Button(c.label) { setContainer(c) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                        Text(job.outputContainer.label)
                    }
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(!isMutable)
            } else if case .dxv = job.outputCodec {
                Menu {
                    ForEach(AlphaMode.allCases) { mode in
                        Button(mode.label) {
                            alphaBinding.wrappedValue = mode
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                        Text(job.format.alphaMode.label)
                    }
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(!isMutable)
            }
            // MJPEG: no second menu (single .mov container, no variant/alpha).

            // ── Advanced popover trigger — text, shown only for codecs
            //    with settings the row doesn't already expose (H.264/HEVC).
            //    Hidden for DXV/HAP (none) and ProRes (variant is the 2nd
            //    menu, container is .mov-locked, alpha note is inline).
            if job.outputCodec.hasAdvancedSettings {
                Button { showingAdvanced = true } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                        Text("Advanced")
                    }
                }
                .buttonStyle(.borderless)
                .fixedSize()
                .help("Advanced codec options")
                .disabled(!isMutable)
                .popover(isPresented: $showingAdvanced, arrowEdge: .bottom) {
                    advancedPopover
                }
            }

            // ── Alpha-flatten note (visible, never silent) ──
            if job.alphaWillBeFlattened {
                HStack(spacing: 3) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                    Text("alpha will be flattened")
                }
                .font(.caption)
                .foregroundColor(.orange)
                .help("This ProRes variant has no alpha channel. Choose ProRes 4444 to keep the source's transparency.")
            }

            Spacer()
        }
        // Negative leading padding compensates for the ~4pt inset the
        // borderlessButton menu style adds before its custom label,
        // pulling row 2 flush with rows 1 / 3 / 4 at the card's left
        // margin.
        .padding(.leading, -4)
    }

    /// Multi-Format Phase 1 — per-job Advanced codec options popover.
    /// The mechanism is built generically (Phase 2/3 will fill it for
    /// HEVC/H.264 bitrate/quality knobs); ProRes fills it lightly with
    /// the variant choice + the (currently .mov-locked) container.
    private var advancedPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Advanced")
                .font(.headline)
            switch job.outputCodec {
            case .prores(let variant):
                Picker("Variant:", selection: proResVariantBinding) {
                    ForEach(ProResVariant.allCases, id: \.self) { v in
                        Text(v.label).tag(v)
                    }
                }
                .pickerStyle(.menu)
                Picker("Container:", selection: .constant(job.outputContainer)) {
                    ForEach(job.outputCodec.allowedContainers, id: \.self) { c in
                        Text(c.label).tag(c)
                    }
                }
                .pickerStyle(.menu)
                .disabled(job.outputCodec.allowedContainers.count <= 1)
                if variant.hasAlpha {
                    Text("Carries the source alpha channel straight through.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else if job.alphaWillBeFlattened {
                    Text("This variant flattens alpha. Choose ProRes 4444 to keep transparency.")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            case .dxv:
                Text("No advanced options for this codec yet.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            case .h264, .hevc:
                videoRateControlControls
            case .mjpeg:
                Text("Coming soon.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
    }

    /// Phase 2a — H.264/HEVC rate-control knobs: a mode toggle
    /// (Quality / Bitrate) + the active control, keyframe interval,
    /// the H.264 profile (H.264 only), and the container. Sane defaults
    /// are pre-filled so an untouched job just encodes well.
    @ViewBuilder
    private var videoRateControlControls: some View {
        Picker("Rate control:", selection: rateControlModeBinding) {
            Text("Quality").tag(RateControlMode.quality)
            Text("Bitrate").tag(RateControlMode.bitrate)
        }
        .pickerStyle(.segmented)

        if job.videoSettings.rateControl.isQuality {
            HStack(spacing: 8) {
                Text("Quality:")
                Slider(value: qualityBinding, in: 0.1...1.0)
                Text(String(format: "%.2f", currentQuality))
                    .font(.caption).monospacedDigit()
                    .frame(width: 34, alignment: .trailing)
            }
        } else {
            HStack(spacing: 8) {
                Text("Bitrate:")
                TextField("Mbps", value: bitrateMbpsBinding, format: .number)
                    .frame(width: 64)
                Text("Mbps")
                    .font(.caption).foregroundColor(.secondary)
            }
        }

        HStack(spacing: 8) {
            Text("Keyframe interval:")
            TextField("frames", value: keyframeBinding, format: .number)
                .frame(width: 56)
            Text("frames (0 = auto)")
                .font(.caption).foregroundColor(.secondary)
        }

        if job.outputCodec == .h264 {
            Picker("Profile:", selection: h264ProfileBinding) {
                ForEach(VideoEncodeSettings.H264Profile.allCases, id: \.self) { p in
                    Text(p.label).tag(p)
                }
            }
            .pickerStyle(.menu)
        }

        Picker("Container:", selection: containerBinding) {
            ForEach(job.outputCodec.allowedContainers, id: \.self) { c in
                Text(c.label).tag(c)
            }
        }
        .pickerStyle(.menu)

        Text(job.outputCodec == .hevc
             ? "HEVC encodes opaque this version (alpha support is upcoming)."
             : "H.264 — the universal-delivery codec.")
            .font(.caption)
            .foregroundColor(.secondary)
    }

    /// UI-only mode discriminator for the rate-control segmented picker.
    enum RateControlMode { case quality, bitrate }

    // MARK: - Audio row (Phase 4): enable/disable (strip) + rate

    /// Audio On/Off (strip) + sample-rate menus, mirroring the codec row's
    /// borderless-Menu idiom. Inert when the source has no audio track
    /// (`sourceHasAudio == false`); the rate menu is disabled when audio
    /// is off. nil sourceHasAudio (probe pending) shows the controls
    /// optimistically.
    private var rowAudio: some View {
        HStack(spacing: 16) {
            if job.sourceHasAudio == false {
                HStack(spacing: 4) {
                    Image(systemName: "speaker.slash")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    Text("No audio track")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            } else {
                Menu {
                    Button("Audio: On") { setAudioEnabled(true) }
                    Button("Audio: Off (strip)") { setAudioEnabled(false) }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                        Text(job.audioEnabled ? "Audio: On" : "Audio: Off")
                    }
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(!isMutable)

                Menu {
                    ForEach(AudioRate.allCases, id: \.self) { r in
                        // AAC (.mp4) caps at 48 kHz — disable >48k so the
                        // impossible choice isn't offered (the encode would
                        // otherwise resample down; never silently dropped).
                        Button(r.label) { setAudioRate(r) }
                            .disabled(audioRateUnavailable(r))
                    }
                    if job.outputContainer.usesAACAudio {
                        Divider()
                        Text("MPEG-4 (AAC) caps at 48 kHz")
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                        Text(job.audioRate.label)
                    }
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(!isMutable || !job.audioEnabled)
            }
            Spacer()
        }
        .padding(.leading, -4)
    }

    private func setAudioEnabled(_ on: Bool) {
        guard let i = queue.jobs.firstIndex(where: { $0.id == job.id }) else { return }
        queue.jobs[i].audioEnabled = on
    }
    private func setAudioRate(_ rate: AudioRate) {
        guard let i = queue.jobs.firstIndex(where: { $0.id == job.id }) else { return }
        queue.jobs[i].audioRate = rate
    }

    /// A rate the current container can't carry (AAC/.mp4 > 48 kHz) — the
    /// menu greys it out rather than offering a choice that would be
    /// resampled down at encode.
    private func audioRateUnavailable(_ rate: AudioRate) -> Bool {
        guard let hz = rate.hz else { return false }   // Original always ok
        return hz > job.outputContainer.maxAudioSampleRate
    }

    /// Clamp the job's audio rate to the container's max when it can't
    /// carry the current selection (e.g. a 96k job switched to H.264/.mp4).
    /// Keeps displayed == actual instead of showing 96k while encoding 48k.
    private func clampAudioRateToContainer(_ i: Int) {
        if let hz = queue.jobs[i].audioRate.hz,
           hz > queue.jobs[i].outputContainer.maxAudioSampleRate {
            queue.jobs[i].audioRate = .hz48000
        }
    }

    private var codecFamilyLabel: String {
        switch job.outputCodec {
        case .dxv:    return job.format.qualityTier.label
        case .prores: return "ProRes"
        case .h264:   return "H.264"
        case .hevc:   return "HEVC"
        case .mjpeg:  return "Motion JPEG"
        }
    }

    // MARK: - Resize row: Output Size + Resize Quality (v0.9.4-pending Phase F)

    /// Output Size menu + Resize Quality menu. Mirrors row2Codec's
    /// borderless-Menu pattern. Output Size lists `.original` + the
    /// 15 StandardResolution presets (grouped by category in
    /// Sections) + a "Custom…" entry that opens the sheet. Quality
    /// is always visible but disabled when `outputSize == .original`
    /// (resizing nothing has no quality — judgment call where the
    /// plan was silent).
    private var rowResize: some View {
        HStack(spacing: 16) {
            // ─── Output Size ──────────────────────────────────────
            Menu {
                Button("Original") {
                    outputSizeBinding.wrappedValue = .original
                }
                // Phase H — user-named presets at the top of the
                // menu (per RESIZE_PLAN.md Q5). Only when non-empty.
                if !settings.customPresets.isEmpty {
                    Section("My Sizes") {
                        ForEach(settings.customPresets) { preset in
                            Button(preset.displayLabel) {
                                outputSizeBinding.wrappedValue =
                                    .custom(width: preset.width, height: preset.height)
                            }
                        }
                    }
                }
                Section("HD / UHD") {
                    presetButton(.hd_1280_720)
                    presetButton(.fhd_1920_1080)
                    presetButton(.qhd_2560_1440)
                    presetButton(.uhd_3840_2160)
                }
                Section("DCI Cinema") {
                    presetButton(.dci_2048_1080)
                    presetButton(.dci_4096_2160)
                }
                Section("Square") {
                    presetButton(.sq_1024)
                    presetButton(.sq_1080)
                    presetButton(.sq_2048)
                }
                Section("Vertical") {
                    presetButton(.v_720_1280)
                    presetButton(.v_1080_1920)
                    presetButton(.v_1440_2560)
                }
                Divider()
                Button("Custom…") {
                    showingCustomSheet = true
                }
                // Phase H — Manage Sizes only when there's something
                // to manage. Keeps the menu lean for users who haven't
                // saved anything yet.
                if !settings.customPresets.isEmpty {
                    Button("Manage Sizes…") {
                        showingManageSheet = true
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    Text("Size: \(outputSizeMenuLabel)")
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(!isMutable)

            // ─── Resize Quality ───────────────────────────────────
            Menu {
                ForEach(ResizeQuality.allCases, id: \.self) { q in
                    Button(q.displayLabel) {
                        resizeQualityBinding.wrappedValue = q
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    Text("Quality: \(job.resizeQuality.displayLabel)")
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            // Disabled when outputSize == .original (no resize → no
            // quality choice) OR while the row is locked.
            .disabled(!isMutable || isOriginalSize)
            .help("Auto picks Lanczos for downscale, Bilinear for upscale. Auto is NOT content-aware — pick Nearest for pixel-art / hard-edge content.")

            // ─── Aspect (Phase G) ─────────────────────────────────
            Menu {
                ForEach(AspectMode.allCases, id: \.self) { mode in
                    Button(mode.displayLabel) {
                        aspectModeBinding.wrappedValue = mode
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    Text("Aspect: \(job.aspectMode.displayLabel)")
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            // Only meaningful when outputSize != .original. Kept
            // visible-but-disabled in the .original case so the row
            // layout is stable; tooltip explains the no-op state.
            .disabled(!isMutable || isOriginalSize)
            .help("Fit (letterbox): preserve source aspect, fill remainder with black bars. Distort: stretch to target dims. No effect when source aspect already matches output.")

            Spacer()
        }
        // Same negative-leading-padding trick row2Codec uses to flush-
        // align with rows 1, 3, 4 at the card's left margin.
        .padding(.leading, -4)
    }

    /// Helper: build a Button for one StandardResolution preset.
    @ViewBuilder
    private func presetButton(_ preset: StandardResolution) -> some View {
        Button(preset.displayLabel) {
            outputSizeBinding.wrappedValue = .preset(preset)
        }
    }

    /// Compact label for the Output Size menu's collapsed view. Full
    /// preset displayLabels ("Full HD — 1920×1080") are too long for
    /// the row; the menu items show the full label, the row shows
    /// just the dims.
    private var outputSizeMenuLabel: String {
        switch job.outputSize {
        case .original:
            return "Original"
        case .preset(let p):
            let (w, h) = p.dimensions
            return "\(w)×\(h)"
        case .custom(let w, let h):
            return "Custom \(w)×\(h)"
        }
    }

    private var isOriginalSize: Bool {
        if case .original = job.outputSize { return true }
        return false
    }

    // MARK: - Crop row (Crop Release Phase E)

    /// Crop badge + Edit / Apply / Cancel. Sits between rowResize and
    /// row3Trim per CROP_PLAN.md §4e. Mirrors row3Trim's leading-
    /// caption shape. Crop editing is preview-pane-hosted (the
    /// `CropOverlayView` on PreviewArea) — there is no sheet.
    ///
    /// Phase E.9 — during edit mode this row's middle column shows
    /// four TextFields (`[W] × [H] @ [X], [Y]`) instead of the
    /// static dims badge. Mouse-drag / arrow-nudge / typing are all
    /// equivalent input modalities for the same in-flight rect.
    private var rowCrop: some View {
        HStack(spacing: 8) {
            Text("Crop:")
                .font(.caption)
                .foregroundColor(.secondary)
            if isEditingThisRow {
                cropFieldsHStack
            } else {
                Text(cropBadge)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(job.cropRect != nil ? .primary : .secondary)
                    .monospacedDigit()
            }
            Spacer()
            if isEditingThisRow {
                // This row is being edited — inline Clear / Cancel /
                // Apply. Reading order is destructive | cancel |
                // default: Clear unconditionally removes the
                // committed cropRect, Cancel takes .cancelAction
                // (Escape), Apply takes .defaultAction (Return) —
                // the standard SwiftUI cancellation idiom, window-
                // wide so Escape works before the user has clicked
                // into the preview pane. Clear (Phase E.8) has NO
                // keyboard shortcut by design — destructive
                // operations require an explicit click.
                Button(role: .destructive) {
                    queue.clearCropEdit()
                } label: {
                    Text("Clear")
                }
                .controlSize(.small)
                Button("Cancel") { queue.cancelCropEdit() }
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
                Button("Apply") { queue.applyCropEdit() }
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
            } else {
                // Edit gated by isMutable (only .queued / .failed
                // rows) AND by serialized edit — disabled while
                // another row is mid-edit (Q3).
                Button("Edit…") { queue.beginCropEdit(jobID: job.id) }
                    .controlSize(.small)
                    .disabled(!isMutable || queue.cropEditingJobID != nil)
            }
        }
        // Phase E.9 — keep field strings in sync with the in-flight
        // rect. `initial: true` seeds the strings the first time the
        // user enters edit mode on this row; later changes (mouse
        // drag, arrow nudge, applyCropEdit's setter) propagate
        // automatically. The sync helper preserves the focused
        // field's text so the user isn't interrupted mid-typing.
        .onChange(of: queue.cropEditingJobID, initial: true) { _, _ in
            if isEditingThisRow { syncCropFieldStringsFromPending() }
        }
        .onChange(of: queue.pendingCropRect) { _, _ in
            if isEditingThisRow { syncCropFieldStringsFromPending() }
        }
        // Focus-loss commits the field the user just left — but ONLY if
        // its text actually changed since it gained focus (Fix-Brief A-2).
        // A focus-in → focus-out with no typing must commit and seed
        // NOTHING (otherwise commitCropField's `if base == nil` branch
        // seeds a full-frame rect and writes a crop the user never made).
        // An explicit Return still commits via each field's `.onSubmit`.
        .onChange(of: focusedCropField) { oldField, newField in
            // Focus-loss commits the field the user just left — but ONLY
            // if its text changed since it gained focus (Fix-Brief A-2).
            // A focus-in → focus-out with no typing must mutate NOTHING:
            // no commitCropField (whose `if base == nil` branch would seed
            // a full-frame rect), AND no field re-sync (which would
            // repopulate all four fields — surfacing late-arrived source
            // dims and looking like a crop was set). An explicit Return
            // still commits via each field's `.onSubmit`.
            if let oldField, oldField != newField,
               cropFieldDidEdit(current: cropFieldText(oldField),
                                baseline: cropFieldBaseline) {
                commitCropField(oldField)
            }
            // Capture the baseline for the field that just gained focus.
            if let newField {
                cropFieldBaseline = cropFieldText(newField)
            }
        }
    }

    /// The current displayed text for one crop field. Used to capture and
    /// compare the focus-gain baseline (Fix-Brief A-2 dirty check).
    private func cropFieldText(_ field: CropField) -> String {
        switch field {
        case .width:  return widthText
        case .height: return heightText
        case .x:      return xText
        case .y:      return yText
        }
    }

    private var isEditingThisRow: Bool {
        queue.cropEditingJobID == job.id
    }

    // MARK: - Crop edit-mode text fields (Phase E.9)

    /// The four W H X Y text fields that replace Phase E.7's static
    /// `1280x720 @ (320, 180)` badge while this row is in edit mode.
    /// Each field is preceded by a one-letter visible label that
    /// identifies it (`W`, `H`, `X`, `Y`); these labels REPLACE
    /// Phase E.9's first-pass `× @ ,` separators after the click-
    /// test found the explicit labels read better than the symbol
    /// chain. `.accessibilityLabel` on each field carries the
    /// spoken form for VoiceOver / Accessibility Inspector (Width,
    /// Height, X, Y) — separate concern from the visible label.
    /// Four W/H/X/Y label-field pairs that replace Phase E.7's
    /// static `1280x720 @ (320, 180)` badge while this row is in
    /// edit mode. Inlined (no @ViewBuilder helpers) after the
    /// previous two attempts produced labels that did not render
    /// at all in the rebuilt app — eliminating the abstraction
    /// rules out a SwiftUI view-builder quirk as the cause.
    /// Labels: 11pt bold, system .primary color, monospaced. The
    /// flash background per field animates from clear → orange
    /// (30% opacity) → clear over 300ms via `.animation(value:)`.
    private var cropFieldsHStack: some View {
        HStack(spacing: 10) {
            HStack(spacing: 3) {
                Text("W:")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(minWidth: 18, alignment: .trailing)
                TextField("", text: $widthText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 50)
                    .focused($focusedCropField, equals: .width)
                    .accessibilityLabel("Width")
                    .onSubmit { commitCropField(.width) }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 1)
            .background(cropFlashBackground(flashWidth))
            .animation(.easeInOut(duration: 0.6), value: flashWidth)
            HStack(spacing: 3) {
                Text("H:")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(minWidth: 18, alignment: .trailing)
                TextField("", text: $heightText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 50)
                    .focused($focusedCropField, equals: .height)
                    .accessibilityLabel("Height")
                    .onSubmit { commitCropField(.height) }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 1)
            .background(cropFlashBackground(flashHeight))
            .animation(.easeInOut(duration: 0.6), value: flashHeight)
            HStack(spacing: 3) {
                Text("X:")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(minWidth: 18, alignment: .trailing)
                TextField("", text: $xText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 40)
                    .focused($focusedCropField, equals: .x)
                    .accessibilityLabel("X")
                    .onSubmit { commitCropField(.x) }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 1)
            .background(cropFlashBackground(flashX))
            .animation(.easeInOut(duration: 0.6), value: flashX)
            HStack(spacing: 3) {
                Text("Y:")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(minWidth: 18, alignment: .trailing)
                TextField("", text: $yText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 40)
                    .focused($focusedCropField, equals: .y)
                    .accessibilityLabel("Y")
                    .onSubmit { commitCropField(.y) }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 1)
            .background(cropFlashBackground(flashY))
            .animation(.easeInOut(duration: 0.6), value: flashY)
        }
    }

    /// Flash background for a corrected field. Sits BEHIND the
    /// label+field HStack (so it surrounds them rather than being
    /// hidden by `.roundedBorder`'s opaque NSTextField backing).
    /// 60% orange on flash, transparent at rest; 600ms easeInOut
    /// fade tied to the @State Bool via `.animation(value:)`.
    @ViewBuilder
    private func cropFlashBackground(_ flash: Bool) -> some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(flash ? Color.orange.opacity(0.60) : Color.clear)
    }

    /// Refresh the four field strings from `queue.pendingCropRect`.
    /// The focused field is NOT overwritten — the user could be
    /// mid-typing and a passing mouse-drag update would otherwise
    /// stomp their text. If `pendingCropRect` is nil (the user has
    /// not dragged or typed since clicking Edit on an uncropped
    /// row), display the source dims as the "what the rect would
    /// be if seeded" placeholder.
    private func syncCropFieldStringsFromPending() {
        let r = queue.pendingCropRect
        // Fix-Brief B — read the authoritative probe-time source dims off
        // the job (works before the preview decodes), not the retired
        // live-preview channel.
        let sw = job.sourceWidth
        let sh = job.sourceHeight
        let w = Int((r?.width  ?? CGFloat(sw ?? 0)).rounded())
        let h = Int((r?.height ?? CGFloat(sh ?? 0)).rounded())
        let x = Int((r?.minX ?? 0).rounded())
        let y = Int((r?.minY ?? 0).rounded())
        if focusedCropField != .width  { widthText  = String(w) }
        if focusedCropField != .height { heightText = String(h) }
        if focusedCropField != .x      { xText      = String(x) }
        if focusedCropField != .y      { yText      = String(y) }
    }

    /// Parse the field's text, run `commitCropFieldValue`, write the
    /// resulting rect back onto `queue.pendingCropRect`. Triggers
    /// the orange flash on `wasCorrected`. If the typed text doesn't
    /// parse (the user typed garbage), the field re-syncs to the
    /// current pending value silently — no flash, no crash.
    ///
    /// First-touch case: if pending is nil (user clicked Edit on an
    /// uncropped row and typed before dragging), seed a full-frame
    /// rect from source dims, then apply the typed value. Mirrors
    /// the overlay's first-drag seed behavior (Phase D's
    /// `fullFrameSeedRect`).
    private func commitCropField(_ field: CropField) {
        let text: String
        switch field {
        case .width:  text = widthText
        case .height: text = heightText
        case .x:      text = xText
        case .y:      text = yText
        }
        guard let typed = Int(text) else {
            syncCropFieldStringsFromPending()
            return
        }
        // Fix-Brief A/B — clamp against the authoritative probe-time source
        // dims on the job. While the add-time probe hasn't resolved (rare:
        // drop → instant Edit; beginCropEdit re-triggers it) these are nil,
        // and we refuse the edit (revert the field, same reject-and-resync
        // idiom as the unparseable-text guard above) rather than letting a
        // crop exceed the frame. Never substitutes Int.max.
        guard let dims = cropClampSourceDims(
            sourceWidth: job.sourceWidth,
            sourceHeight: job.sourceHeight) else {
            syncCropFieldStringsFromPending()
            return
        }
        let sw = dims.width
        let sh = dims.height
        var base = queue.pendingCropRect
        if base == nil {
            base = CropDragMath.fullFrameSeedRect(
                sourceWidth: sw, sourceHeight: sh,
                alignment: job.outputCodec.dimensionAlignment)
        }
        guard let baseRect = base else { return }
        let result = commitCropFieldValue(
            field: field,
            typedValue: typed,
            currentRect: baseRect,
            sourceWidth: sw,
            sourceHeight: sh,
            alignment: job.outputCodec.dimensionAlignment)
        queue.pendingCropRect = result.updatedRect
        // Write the corrected value directly onto this field's
        // @State. The `.onChange(of: queue.pendingCropRect)`
        // observer only fires when the rect actually changes; if
        // the clamp landed on the rect's existing value (e.g.
        // typing X=2000 when W already fills source — final X is
        // still 0), the rect is byte-equal and no observer fires.
        // Without this direct write the field would keep showing
        // the typed-but-clamped value ("2000" instead of "0") even
        // though the math correctly corrected it. We also bypass
        // the "skip focused field" guard in
        // syncCropFieldStringsFromPending — on a Return-commit the
        // field is still focused but the user has committed and
        // wants to see the result.
        let correctedString = String(result.correctedValue)
        switch field {
        case .width:  widthText  = correctedString
        case .height: heightText = correctedString
        case .x:      xText      = correctedString
        case .y:      yText      = correctedString
        }
        // Fix-Brief A-2 — after a deliberate commit (Return, or a real
        // edit then blur), the field now displays the committed value;
        // keep the dirty-check baseline in step so a following no-edit
        // blur on the still-focused field doesn't redundantly re-commit.
        cropFieldBaseline = correctedString
        if result.wasCorrected {
            triggerFlash(for: field)
        }
        // The `.onChange(of: queue.pendingCropRect)` above fires
        // syncCropFieldStringsFromPending() so the field text
        // refreshes to the corrected value automatically.
    }

    private func triggerFlash(for field: CropField) {
        switch field {
        case .width:  flashWidth  = true
        case .height: flashHeight = true
        case .x:      flashX      = true
        case .y:      flashY      = true
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            switch field {
            case .width:  flashWidth  = false
            case .height: flashHeight = false
            case .x:      flashX      = false
            case .y:      flashY      = false
            }
        }
    }

    /// Compact crop-state badge for rowCrop. Two modes:
    ///   - Passive (this row is NOT the editing row): static dims-only
    ///     "WxH", or "—  (no crop)" placeholder.
    ///   - Live (this row IS the editing row, Phase E.7): dims +
    ///     position "WxH @ (X, Y)" read from `queue.pendingCropRect`,
    ///     updating on every drag tick / keyboard nudge, or
    ///     "—  (no crop yet)" between Edit click and first placement.
    /// Format dispatches to the static helper so the formatter is
    /// unit-testable without mounting the view (v0.9.4 Phase H Bug 5
    /// rule: factor view-embedded logic into pure functions).
    private var cropBadge: String {
        Self.formatCropBadge(
            pendingCropRect: queue.pendingCropRect,
            committedCropRect: job.cropRect,
            isEditing: queue.cropEditingJobID == job.id)
    }

    static func formatCropBadge(
        pendingCropRect: CGRect?,
        committedCropRect: CGRect?,
        isEditing: Bool
    ) -> String {
        if isEditing {
            guard let r = pendingCropRect else { return "—  (no crop yet)" }
            let w = Int(r.width.rounded())
            let h = Int(r.height.rounded())
            let x = Int(r.minX.rounded())
            let y = Int(r.minY.rounded())
            return "\(w)x\(h) @ (\(x), \(y))"
        } else {
            guard let r = committedCropRect else { return "—  (no crop)" }
            let w = Int(r.width.rounded())
            let h = Int(r.height.rounded())
            return "\(w)x\(h)"
        }
    }

    // MARK: - Row 3: trim info

    private var row3Trim: some View {
        HStack(spacing: 6) {
            Text("Trim:")
                .font(.caption)
                .foregroundColor(.secondary)
            Text(trimDisplay)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(job.isTrimmed ? .primary : .secondary)
                .monospacedDigit()
            Spacer()
        }
    }

    private var trimDisplay: String {
        guard job.isTrimmed else { return "—  (full clip)" }
        let inF = job.inFrame
        let outF = job.outFrame
        let fps = job.sourceFPS ?? 0
        switch AppSettings.shared.trimFilenameFormat {
        case .time:
            let inStr  = inF.map  { formatTime(frame: $0, fps: fps) } ?? "start"
            let outStr = outF.map { formatTime(frame: $0, fps: fps) } ?? "end"
            return "\(inStr) → \(outStr)"
        case .frameIndices:
            let inStr  = inF.map  { String($0) } ?? "0"
            let outStr = outF.map { String($0) } ?? "end"
            return "frame \(inStr) → \(outStr)"
        }
    }

    /// Local copy of AutoNameEngine's formatTime, displayed with `:`
    /// separators since the trim-info row is on-screen (not in a
    /// filename — Finder substitutes `/` for `:` in displayed names
    /// but the on-screen text is unconstrained).
    private func formatTime(frame: Int, fps: Double) -> String {
        guard fps > 0 else { return "?" }
        let totalSeconds = max(0.0, Double(frame) / fps)
        let minutes = Int(totalSeconds) / 60
        let secondsPart = totalSeconds - Double(minutes * 60)
        let seconds = Int(secondsPart)
        let centiseconds = Int((secondsPart - Double(seconds)) * 100)
        return String(format: "%02d:%02d.%02d", minutes, seconds, centiseconds)
    }

    // MARK: - Row 4: output name

    private var row4Output: some View {
        OutputNameCell(
            name: job.outputName,
            overridden: job.outputNameOverridden,
            onEdit: { newName in
                guard let i = queue.jobs.firstIndex(where: { $0.id == job.id }) else { return }
                queue.jobs[i].outputName = newName
                queue.jobs[i].outputNameOverridden = true
            },
            onReset: {
                guard let i = queue.jobs.firstIndex(where: { $0.id == job.id }) else { return }
                queue.jobs[i].resetOutputNameToAuto(
                    trimFormat: AppSettings.shared.trimFilenameFormat)
            }
        )
        .frame(maxWidth: .infinity)
        .disabled(!isMutable)
    }

    // MARK: - Bindings + Retry

    /// Multi-Format Phase 1 — select a DXV/HAP family tier. Preserves
    /// the current alpha mode (read from `format`, which still holds the
    /// last DXV selection even while ProRes is active) and re-points
    /// `outputCodec` at the `.dxv` path so dispatch routes correctly.
    private func selectDXVTier(_ tier: QualityTier) {
        guard let i = queue.jobs.firstIndex(where: { $0.id == job.id }) else { return }
        let currentAlpha = queue.jobs[i].format.alphaMode
        let newFormat = DXVFormat(tier: tier, alpha: currentAlpha)
        queue.jobs[i].format = newFormat
        queue.jobs[i].outputCodec = .dxv(newFormat)
        queue.jobs[i].outputContainer = .mov
        queue.refreshAutoNameIfNeeded(jobID: job.id)
    }

    /// Switch the job to ProRes. Alpha steering: default to the variant
    /// `steeredProResVariant` picks (4444 for an alpha source, else 422).
    private func selectProRes() {
        guard let i = queue.jobs.firstIndex(where: { $0.id == job.id }) else { return }
        let variant = queue.jobs[i].steeredProResVariant
        queue.jobs[i].outputCodec = .prores(variant)
        queue.jobs[i].outputContainer = .mov
        queue.refreshAutoNameIfNeeded(jobID: job.id)
    }

    private func setProResVariant(_ v: ProResVariant) {
        guard let i = queue.jobs.firstIndex(where: { $0.id == job.id }) else { return }
        queue.jobs[i].outputCodec = .prores(v)
        queue.refreshAutoNameIfNeeded(jobID: job.id)
    }

    private var proResVariantBinding: Binding<ProResVariant> {
        Binding(
            get: { job.outputCodec.proResVariant ?? .proRes422 },
            set: { setProResVariant($0) }
        )
    }

    // MARK: - Phase 2a — H.264 / HEVC handlers + rate-control bindings

    /// Switch to H.264 or HEVC. Defaults the container to `.mp4` — the
    /// broad-delivery target that distinguishes these codecs from the
    /// QuickTime-native DXV/HAP/ProRes families; the user can switch to
    /// `.mov` in the second menu / Advanced popover. videoSettings keeps
    /// its current/default values.
    private func selectVideoCodec(_ codec: OutputCodec) {
        guard let i = queue.jobs.firstIndex(where: { $0.id == job.id }) else { return }
        queue.jobs[i].outputCodec = codec
        // Default container: .mp4 for the broad-delivery codecs that allow
        // it (H.264/HEVC); .mov for MJPEG (its only allowed container).
        queue.jobs[i].outputContainer =
            codec.allowedContainers.contains(.mp4) ? .mp4 : .mov
        clampAudioRateToContainer(i)   // AAC/.mp4 caps audio at 48 kHz
        queue.refreshAutoNameIfNeeded(jobID: job.id)
    }

    private func setContainer(_ c: OutputContainer) {
        guard let i = queue.jobs.firstIndex(where: { $0.id == job.id }) else { return }
        queue.jobs[i].outputContainer = c
        clampAudioRateToContainer(i)   // AAC/.mp4 caps audio at 48 kHz
        // Extension changes with the container — refresh the auto-name.
        queue.refreshAutoNameIfNeeded(jobID: job.id)
    }

    private func updateJob(_ mutate: (inout EncodeJob) -> Void) {
        guard let i = queue.jobs.firstIndex(where: { $0.id == job.id }) else { return }
        mutate(&queue.jobs[i])
    }

    private var currentQuality: Double {
        if case .quality(let q) = job.videoSettings.rateControl { return q }
        return 0.6
    }
    private var currentBitrateMbps: Double {
        if case .bitrate(let m) = job.videoSettings.rateControl { return m }
        return 10
    }

    private var rateControlModeBinding: Binding<RateControlMode> {
        Binding(
            get: { job.videoSettings.rateControl.isQuality ? .quality : .bitrate },
            set: { mode in
                updateJob { j in
                    switch mode {
                    case .quality: j.videoSettings.rateControl = .quality(0.6)
                    case .bitrate: j.videoSettings.rateControl = .bitrate(10)
                    }
                }
            })
    }
    private var qualityBinding: Binding<Double> {
        Binding(get: { currentQuality },
                set: { v in updateJob { $0.videoSettings.rateControl = .quality(v) } })
    }
    private var bitrateMbpsBinding: Binding<Double> {
        Binding(get: { currentBitrateMbps },
                set: { v in updateJob { $0.videoSettings.rateControl = .bitrate(max(0.1, v)) } })
    }
    private var keyframeBinding: Binding<Int> {
        Binding(get: { job.videoSettings.keyframeIntervalFrames },
                set: { v in updateJob { $0.videoSettings.keyframeIntervalFrames = max(0, v) } })
    }
    private var h264ProfileBinding: Binding<VideoEncodeSettings.H264Profile> {
        Binding(get: { job.videoSettings.h264Profile },
                set: { p in updateJob { $0.videoSettings.h264Profile = p } })
    }
    private var containerBinding: Binding<OutputContainer> {
        Binding(get: { job.outputContainer },
                set: { c in setContainer(c) })
    }

    private var alphaBinding: Binding<AlphaMode> {
        Binding(
            get: { job.format.alphaMode },
            set: { newAlpha in
                guard let i = queue.jobs.firstIndex(where: { $0.id == job.id }) else { return }
                let currentTier = queue.jobs[i].format.qualityTier
                queue.jobs[i].format = DXVFormat(tier: currentTier, alpha: newAlpha)
                queue.refreshAutoNameIfNeeded(jobID: job.id)
            }
        )
    }

    /// Resize Release Phase F — writes the row's outputSize.
    /// AutoNameEngine is NOT refreshed here: RESIZE_PLAN.md does not
    /// specify a filename token for resize, so a size change does
    /// not alter the auto-name (judgment call where the plan was
    /// silent — Phase F report flags it).
    private var outputSizeBinding: Binding<OutputSize> {
        Binding(
            get: { job.outputSize },
            set: { newSize in
                guard let i = queue.jobs.firstIndex(where: { $0.id == job.id }) else { return }
                queue.jobs[i].outputSize = newSize
            }
        )
    }

    /// Resize Release Phase F — writes the row's resizeQuality.
    private var resizeQualityBinding: Binding<ResizeQuality> {
        Binding(
            get: { job.resizeQuality },
            set: { newQuality in
                guard let i = queue.jobs.firstIndex(where: { $0.id == job.id }) else { return }
                queue.jobs[i].resizeQuality = newQuality
            }
        )
    }

    /// Resize Release Phase G — writes the row's aspectMode.
    private var aspectModeBinding: Binding<AspectMode> {
        Binding(
            get: { job.aspectMode },
            set: { newMode in
                guard let i = queue.jobs.firstIndex(where: { $0.id == job.id }) else { return }
                queue.jobs[i].aspectMode = newMode
            }
        )
    }

    private func retry() {
        guard let i = queue.jobs.firstIndex(where: { $0.id == job.id }) else { return }
        queue.jobs[i].status = .queued
        queue.jobs[i].progress = 0
        queue.jobs[i].errorMessage = nil
        queue.jobs[i].outputURL = nil
    }
}

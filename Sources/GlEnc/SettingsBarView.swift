// SPDX-License-Identifier: MIT
import SwiftUI
import GlEncCore

/// Batch-edit — the top settings bar. Replaces the old defaults row and
/// offers EVERY option a job card offers (codec family incl. ProRes /
/// H.264 / HEVC / Motion JPEG, alpha / ProRes variant / container, the
/// H.264/HEVC Advanced knobs, HAP chunks, audio, size incl. Custom…,
/// resize quality, aspect).
///
/// Target:
///   - 0 or 1 row selected → the defaults for newly-dropped files.
///   - ≥2 rows selected (Cmd/Shift-click, Cmd-A) → those rows. Each
///     setting is apply-where-applicable (JobSettings rules): e.g. Chunks
///     only touches the HAP clips in the selection; locked (encoding /
///     done) rows are skipped.
///
/// Crop, trim and output name are per-source and stay card/preview-only.
struct SettingsBarView: View {
    @ObservedObject var queue: EncodeQueue
    @ObservedObject private var settings: AppSettings = .shared

    @State private var showingCustomSheet = false
    @State private var showingManageSheet = false
    @State private var showingAdvanced = false

    // MARK: - Target

    private var isBatch: Bool { queue.isBatchSelection }

    /// The settings being displayed: the selected rows' (batch) or the
    /// defaults (one element).
    private var targets: [JobSettings] {
        isBatch ? queue.selectedJobs.map(\.settings) : [queue.defaultSettings]
    }

    private func apply(_ e: EncodeQueue.SettingsEdit) {
        queue.applyFromSettingsBar(e)
    }

    /// The value shared by every element of `list`, or nil when mixed.
    private func common<T: Equatable>(_ list: [JobSettings], _ f: (JobSettings) -> T) -> T? {
        guard let first = list.first.map(f) else { return nil }
        return list.allSatisfy { f($0) == first } ? first : nil
    }

    /// " · 3/5" when a setting applies to only some of the selection.
    private func partial(_ applicable: Int) -> String {
        guard isBatch, applicable < targets.count else { return "" }
        return "  \(applicable)/\(targets.count)"
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            codecRow
            audioRow
            resizeRow
        }
        .sheet(isPresented: $showingCustomSheet) {
            let dims = customSheetInitialDims
            ResizeCustomSheet(
                initialWidth: dims.w,
                initialHeight: dims.h,
                alignment: targets.map(\.outputCodec.dimensionAlignment).max() ?? 1,
                onCommit: { newSize in
                    apply { s, _ in s.setOutputSize(newSize) }
                    showingCustomSheet = false
                },
                onCancel: { showingCustomSheet = false })
        }
        .sheet(isPresented: $showingManageSheet) {
            ManageSizesSheet(settings: settings,
                             onClose: { showingManageSheet = false })
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            if isBatch {
                let locked = queue.selectedJobs.filter {
                    $0.status != .queued && $0.status != .failed
                }.count
                Image(systemName: "square.stack.3d.up")
                    .foregroundColor(.accentColor)
                Text("Editing \(targets.count) selected clips"
                     + (locked > 0 ? " (\(locked) locked, skipped)" : ""))
                    .foregroundColor(.accentColor)
            } else {
                Text("Defaults for new files")
                    .foregroundColor(.secondary)
                Text("— select 2+ clips (⌘-click, ⇧-click, ⌘A) to edit them together")
                    .foregroundColor(.secondary.opacity(0.7))
            }
            Spacer()
        }
        .font(.caption)
        .lineLimit(1)
        .truncationMode(.tail)
    }

    // MARK: - Codec row

    private var codecRow: some View {
        let t = targets
        let dxv = t.filter(\.isDXVFamily)
        let prores = t.filter(\.isProRes)
        let video = t.filter(\.isH264OrHEVC)
        let hap = t.filter(\.isHAP)

        return HStack(spacing: 16) {
            // ── Codec family ──
            barMenu(common(t, \.codecFamilyLabel) ?? "Mixed codecs") {
                ForEach(QualityTier.allCases) { tier in
                    Button(tier.label) { apply { s, _ in s.selectDXVTier(tier) } }
                }
                Divider()
                Button("ProRes") { apply { s, alpha in s.selectProRes(sourceHasAlpha: alpha) } }
                Button("H.264") { apply { s, _ in s.selectVideoCodec(.h264) } }
                Button("HEVC") { apply { s, _ in s.selectVideoCodec(.hevc) } }
                Button("Motion JPEG") { apply { s, _ in s.selectVideoCodec(.mjpeg) } }
            }
            .help(isBatch ? "Codec for the selected clips." : "Default codec for newly-dropped files.")

            // ── DXV/HAP alpha ──
            if !dxv.isEmpty {
                barMenu((common(dxv, \.format.alphaMode)?.label ?? "Mixed alpha") + partial(dxv.count)) {
                    ForEach(AlphaMode.allCases) { mode in
                        Button(mode.label) { apply { s, _ in s.setAlpha(mode) } }
                    }
                }
                .help("Alpha for the DXV/HAP clips.")
            }

            // ── ProRes variant ──
            if !prores.isEmpty {
                barMenu((common(prores, { $0.outputCodec.proResVariant ?? .proRes422 })?.label ?? "Mixed variant")
                        + partial(prores.count)) {
                    ForEach(ProResVariant.allCases, id: \.self) { v in
                        Button(v.label) { apply { s, _ in s.setProResVariant(v) } }
                    }
                }
                .help("ProRes variant for the ProRes clips.")
            }

            // ── H.264/HEVC container + Advanced ──
            if !video.isEmpty {
                barMenu((common(video, \.outputContainer)?.label ?? "Mixed container")
                        + partial(video.count)) {
                    ForEach(OutputContainer.allCases, id: \.self) { c in
                        Button(c.label) { apply { s, _ in s.setContainer(c) } }
                    }
                }
                .help("Container for the H.264/HEVC clips.")

                Button { showingAdvanced = true } label: {
                    HStack(spacing: 4) {
                        chevron
                        Text("Advanced" + partial(video.count))
                    }
                }
                .buttonStyle(.borderless)
                .fixedSize()
                .help("Advanced H.264/HEVC options")
                .popover(isPresented: $showingAdvanced, arrowEdge: .bottom) {
                    advancedPopover(video)
                }
            }

            // ── HAP chunks ──
            if !hap.isEmpty {
                let c = common(hap, \.hapChunks)
                let base = c ?? hap.map(\.hapChunks).min() ?? 1
                HStack(spacing: 4) {
                    HapChunksStepper(
                        valueText: c.map(String.init) ?? "–",
                        onIncrement: { apply { s, _ in s.setHapChunks(base + 1) } },
                        onDecrement: { apply { s, _ in s.setHapChunks(base - 1) } })
                    if !partial(hap.count).isEmpty {
                        Text(partial(hap.count)).foregroundColor(.secondary)
                    }
                }
                .fixedSize()
            }

            Spacer()
        }
        .padding(.leading, -4)
    }

    private func advancedPopover(_ video: [JobSettings]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Advanced")
                .font(.headline)
            if let rep = video.first {
                VideoAdvancedControls(settings: rep, apply: { e in apply(e) })
            }
            if isBatch {
                Text("Changes apply to the \(video.count) H.264/HEVC clip\(video.count == 1 ? "" : "s") in the selection"
                     + (common(video, \.videoSettings) == nil ? " (values differ — showing the first)." : "."))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
    }

    // MARK: - Audio row

    private var audioRow: some View {
        let t = targets
        let enabled = common(t, \.audioEnabled)
        return HStack(spacing: 16) {
            barMenu(enabled.map { $0 ? "Audio: On" : "Audio: Off" } ?? "Audio: Mixed") {
                Button("Audio: On") { apply { s, _ in s.setAudioEnabled(true) } }
                Button("Audio: Off (strip)") { apply { s, _ in s.setAudioEnabled(false) } }
            }
            .help("Clips without an audio track are unaffected.")

            barMenu(common(t, \.audioRate)?.label ?? "Mixed rate") {
                ForEach(AudioRate.allCases, id: \.self) { r in
                    Button(r.label) { apply { s, _ in s.setAudioRate(r) } }
                        .disabled(t.allSatisfy { $0.audioRateUnavailable(r) })
                }
                if t.contains(where: { $0.outputContainer.usesAACAudio }) {
                    Divider()
                    Text("MPEG-4 (AAC) caps at 48 kHz")
                }
            }
            .disabled(enabled == false)
            Spacer()
        }
        .padding(.leading, -4)
    }

    // MARK: - Resize row

    private var resizeRow: some View {
        let t = targets
        let allOriginal = t.allSatisfy(\.isOriginalSize)
        return HStack(spacing: 16) {
            barMenu("Size: " + (common(t, \.outputSize).map(OutputSizeMenuItems.label) ?? "Mixed")) {
                OutputSizeMenuItems(
                    settings: settings,
                    onSelect: { size in apply { s, _ in s.setOutputSize(size) } },
                    onCustom: { showingCustomSheet = true },
                    onManage: { showingManageSheet = true })
            }

            barMenu("Quality: " + (common(t, \.resizeQuality)?.displayLabel ?? "Mixed")) {
                ForEach(ResizeQuality.allCases, id: \.self) { q in
                    Button(q.displayLabel) { apply { s, _ in s.setResizeQuality(q) } }
                }
            }
            .disabled(allOriginal)
            .help("Auto picks Lanczos for downscale, Bilinear for upscale. Auto is NOT content-aware — pick Nearest for pixel-art / hard-edge content.")

            barMenu("Aspect: " + (common(t, \.aspectMode)?.displayLabel ?? "Mixed")) {
                ForEach(AspectMode.allCases, id: \.self) { m in
                    Button(m.displayLabel) { apply { s, _ in s.setAspectMode(m) } }
                }
            }
            .disabled(allOriginal)
            .help("Fit (letterbox): preserve source aspect, fill remainder with black bars. Distort: stretch to target dims. No effect when source aspect already matches output.")

            Spacer()
        }
        .padding(.leading, -4)
    }

    private var customSheetInitialDims: (w: Int, h: Int) {
        switch common(targets, \.outputSize) {
        case .preset(let p)?: return (p.dimensions.width, p.dimensions.height)
        case .custom(let w, let h)?: return (w, h)
        default: return (1920, 1080)
        }
    }

    // MARK: - Menu idiom (matches the job card: borderless, chevron first)

    private var chevron: some View {
        Image(systemName: "chevron.up.chevron.down")
            .font(.system(size: 9))
            .foregroundColor(.secondary)
    }

    private func barMenu<Content: View>(_ label: String,
                                        @ViewBuilder _ content: () -> Content) -> some View {
        Menu {
            content()
        } label: {
            HStack(spacing: 4) {
                chevron
                Text(label)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

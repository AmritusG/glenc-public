// SPDX-License-Identifier: MIT
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import GlEncCore

struct ContentView: View {
    @EnvironmentObject var queue: EncodeQueue
    @State private var isTargeted = false
    /// Phase H — Manage Sizes… sheet, presented from the defaults-row
    /// Size menu when customPresets is non-empty.
    @State private var showingManageSheet: Bool = false
    // v0.9.2 Phase G.1: the Advanced section's @State properties
    // (clusterFitEnabled, refinedBC4Enabled) and its DisclosureGroup
    // body relocated to PreferencesWindow.advancedSection. Same
    // session-only behavior (toggles BC1Config.useClusterFit /
    // BC4Config.useRefinement on the GlEncCore globals; no
    // persistence). Lives in Preferences instead of cluttering the
    // queue column.


    /// Phase 7B-a — preview-pane visibility tracks
    /// `AppSettings.shared.previewPaneVisibleByDefault`. Observing the
    /// settings @ObservableObject means the View menu's toggle (which
    /// flips the setting) lights up the pane immediately AND persists
    /// for the next launch. Single source of truth.
    @ObservedObject private var settings: AppSettings = .shared

    var body: some View {
        // Phase 8B + 7B-a: HSplitView swaps in/out based on the
        // user's preview-pane visibility preference.
        // v0.9.0.3 — bumped widths +30pt so the HH:MM:SS:FF timecode
        // counter in the preview transport row fits on a single line
        // alongside the transport buttons + trim controls.
        Group {
            if settings.previewPaneVisibleByDefault {
                HSplitView {
                    queueColumn
                        .frame(minWidth: 480, idealWidth: 640)
                    PreviewPane()
                        .frame(minWidth: 370, idealWidth: 530)
                }
                .frame(minWidth: 850, idealWidth: 1170)
            } else {
                queueColumn
                    .frame(minWidth: 480, idealWidth: 640)
            }
        }
        // v0.9.2 Phase G — output-filename collision prompt. When
        // EncodeQueue detects a collision under CollisionPolicy .ask,
        // it suspends its serial encode loop on a CheckedContinuation
        // and surfaces this prompt; the user's button choice resumes
        // the continuation and the loop proceeds.
        .modifier(CollisionPromptModifier(queue: queue))
        // Phase H — Manage Sizes… sheet for the defaults-row Size menu.
        .sheet(isPresented: $showingManageSheet) {
            ManageSizesSheet(settings: settings,
                              onClose: { showingManageSheet = false })
        }
    }

    /// The pre-Phase-8B single-pane layout, now the left column of the
    /// HSplitView. Drop zone on top, queue table in the middle,
    /// advanced disclosure at the bottom.
    private var queueColumn: some View {
        VStack(spacing: 0) {
            // v0.9.2 Phase G.1 (post-smoke fix): global Codec/Alpha
            // defaults moved out of the system toolbar because macOS
            // 14+ groups multiple .navigation-placement items into a
            // single pill-shaped container — that chrome can't be
            // styled away from item-level modifiers. Rendered here as
            // a plain HStack at the top of the queue column, flat,
            // no background, matching JobCardView row-2's existing
            // borderless menu style.
            defaultsRow
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 4)
            dropZone
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .padding(.bottom, 8)
            Divider()
            queueSection
            // v0.9.2 Phase G.1: the "Advanced" DisclosureGroup moved
            // to PreferencesWindow's advancedSection. The queue
            // column is now cleaner; experimental encoder toggles
            // live with the rest of the preferences.
        }
    }

    // MARK: - Defaults row (global Codec + Alpha menus)

    /// Flat HStack of two borderless Menus controlling the queue's
    /// Resize Release Phase F — compact menu label for the defaults-
    /// row Output Size menu. Mirrors JobCardView.outputSizeMenuLabel
    /// but lives on the defaults row (no Custom… case here, since
    /// the defaults row doesn't offer Custom…).
    private var defaultOutputSizeMenuLabel: String {
        switch queue.defaultOutputSize {
        case .original:
            return "Original"
        case .preset(let p):
            let (w, h) = p.dimensions
            return "\(w)×\(h)"
        case .custom(let w, let h):
            return "Custom \(w)×\(h)"
        }
    }

    /// `defaultTier` / `defaultAlpha` bindings — applied to NEW jobs
    /// at enqueue time. Existing rows keep their own settings.
    private var defaultsRow: some View {
        HStack(spacing: 16) {
            Menu {
                ForEach(QualityTier.allCases) { tier in
                    Button(tier.label) { queue.defaultTier = tier }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    Text(queue.defaultTier.label)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Default codec for newly-dropped files. Existing queue rows keep their own settings.")

            Menu {
                ForEach(AlphaMode.allCases) { mode in
                    Button(mode.label) { queue.defaultAlpha = mode }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    Text(queue.defaultAlpha.label)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Default alpha mode for newly-dropped files. Existing queue rows keep their own settings.")

            // ─── Resize Release Phase F — Output Size + Quality
            // defaults. Same `borderlessButton + chevron-before-label`
            // pattern. Output Size offers Original + the 15 presets
            // grouped by category; Custom… is intentionally NOT in
            // the defaults row (judgment call where the plan was
            // silent — custom-as-default is a per-job edge case).
            // Quality is always visible; Auto's not-content-aware
            // limitation is in the help string.
            Menu {
                Button("Original") {
                    queue.defaultOutputSize = .original
                }
                // Phase H — user-named presets at the top.
                if !settings.customPresets.isEmpty {
                    Section("My Sizes") {
                        ForEach(settings.customPresets) { preset in
                            Button(preset.displayLabel) {
                                queue.defaultOutputSize =
                                    .custom(width: preset.width, height: preset.height)
                            }
                        }
                    }
                }
                Section("HD / UHD") {
                    Button(StandardResolution.hd_1280_720.displayLabel)   { queue.defaultOutputSize = .preset(.hd_1280_720) }
                    Button(StandardResolution.fhd_1920_1080.displayLabel) { queue.defaultOutputSize = .preset(.fhd_1920_1080) }
                    Button(StandardResolution.qhd_2560_1440.displayLabel) { queue.defaultOutputSize = .preset(.qhd_2560_1440) }
                    Button(StandardResolution.uhd_3840_2160.displayLabel) { queue.defaultOutputSize = .preset(.uhd_3840_2160) }
                }
                Section("DCI Cinema") {
                    Button(StandardResolution.dci_2048_1080.displayLabel) { queue.defaultOutputSize = .preset(.dci_2048_1080) }
                    Button(StandardResolution.dci_4096_2160.displayLabel) { queue.defaultOutputSize = .preset(.dci_4096_2160) }
                }
                Section("Square") {
                    Button(StandardResolution.sq_1024.displayLabel) { queue.defaultOutputSize = .preset(.sq_1024) }
                    Button(StandardResolution.sq_1080.displayLabel) { queue.defaultOutputSize = .preset(.sq_1080) }
                    Button(StandardResolution.sq_2048.displayLabel) { queue.defaultOutputSize = .preset(.sq_2048) }
                }
                Section("Vertical") {
                    Button(StandardResolution.v_720_1280.displayLabel)  { queue.defaultOutputSize = .preset(.v_720_1280) }
                    Button(StandardResolution.v_1080_1920.displayLabel) { queue.defaultOutputSize = .preset(.v_1080_1920) }
                    Button(StandardResolution.v_1440_2560.displayLabel) { queue.defaultOutputSize = .preset(.v_1440_2560) }
                }
                // Phase H — Manage Sizes…; only when there's something
                // to manage. Defaults row has no Custom… (existing
                // judgment call from Phase F).
                if !settings.customPresets.isEmpty {
                    Divider()
                    Button("Manage Sizes…") {
                        showingManageSheet = true
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    Text("Size: \(defaultOutputSizeMenuLabel)")
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Default output size for newly-dropped files. Existing queue rows keep their own settings.")

            Menu {
                ForEach(ResizeQuality.allCases, id: \.self) { q in
                    Button(q.displayLabel) { queue.defaultResizeQuality = q }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    Text("Quality: \(queue.defaultResizeQuality.displayLabel)")
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Default resize quality for newly-dropped files. Auto picks Lanczos for downscale, Bilinear for upscale. Auto is NOT content-aware — pick Nearest for pixel-art / hard-edge content.")

            Menu {
                ForEach(AspectMode.allCases, id: \.self) { mode in
                    Button(mode.displayLabel) { queue.defaultAspectMode = mode }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    Text("Aspect: \(queue.defaultAspectMode.displayLabel)")
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Default aspect handling for newly-dropped files. Fit (letterbox) preserves source aspect with black bars; Distort to fill stretches non-uniformly. No effect on .original or matched-aspect resizes.")

            Spacer()
        }
        // Negative leading padding compensates for the ~4pt inset the
        // borderlessButton menu style adds before the custom label —
        // same trick JobCardView row-2 uses to align flush left.
        .padding(.leading, -4)
    }

    // MARK: - Drop zone

    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(isTargeted
                      ? Color.accentColor.opacity(0.15)
                      : Color.gray.opacity(0.06))
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(0.5),
                    style: StrokeStyle(lineWidth: 2, dash: [6, 4])
                )
            VStack(spacing: 6) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 28, weight: .regular))
                Text("Drop video files to queue")
                    .font(.headline)
                Text(".mov  .mp4  .m4v  .qt  (anything public.movie)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .foregroundColor(isTargeted ? .accentColor : .secondary)
        }
        .frame(height: 130)
        // Accept fileURL only. Adding .movie here causes SwiftUI to
        // match providers via the content UTI (e.g. com.apple.quicktime-movie)
        // and strip public.file-url from the provider, breaking
        // loadDataRepresentation(forTypeIdentifier: UTType.fileURL).
        // Finder file drags always carry public.file-url; we filter to
        // public.movie-conforming files AFTER URL resolution below.
        .onDrop(
            of: [.fileURL],
            isTargeted: $isTargeted,
            perform: handleDrop
        )
    }

    // MARK: - Queue section (header + table)

    private var queueSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            queueHeader
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            if queue.jobs.isEmpty {
                emptyState
            } else {
                queueTable
            }
        }
    }

    private var queueHeader: some View {
        HStack(spacing: 12) {
            Text("\(queue.jobs.count) job\(queue.jobs.count == 1 ? "" : "s")")
                .font(.callout)
                .foregroundColor(.secondary)

            if let progress = overallProgress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .frame(maxWidth: 220)
                Text(String(format: "%.0f%%", progress * 100))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundColor(.secondary)
            }

            Spacer()

            if hasCompletedJobs {
                Button("Clear Completed") {
                    queue.clearCompleted()
                }
                .controlSize(.small)
            }
        }
    }

    /// Overall queue progress: average of all jobs' progress where
    /// .done counts as 1.0, .failed and .queued count as 0. Returns
    /// `nil` when the queue is empty (suppresses the bar entirely).
    private var overallProgress: Double? {
        guard !queue.jobs.isEmpty else { return nil }
        let total = queue.jobs.reduce(0.0) { acc, job in
            switch job.status {
            case .done: return acc + 1.0
            case .encoding: return acc + job.progress
            default: return acc
            }
        }
        return total / Double(queue.jobs.count)
    }

    private var hasCompletedJobs: Bool {
        queue.jobs.contains { $0.status == .done || $0.status == .failed }
    }

    private var emptyState: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            Text("No jobs queued.")
                .foregroundColor(.secondary)
                .font(.callout)
                .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
        }
        .frame(minHeight: 120)
    }

    private var queueTable: some View {
        // v0.9.0.3 — replaced the Table column-per-field layout with a
        // List of 4-row JobCards. The Table truncated filename + output
        // name at narrow window widths; the card layout renders every
        // field at full card width. Selection still binds to
        // `queue.selectedJobID` (drives the preview pane).
        List(selection: $queue.selectedJobID) {
            ForEach(queue.jobs) { job in
                VStack(spacing: 0) {
                    JobCardView(job: job, queue: queue)
                    Divider()
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .tag(job.id)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Drop handling

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }

        let group = DispatchGroup()
        let lock = NSLock()
        var collected: [URL] = []

        for provider in providers {
            guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else {
                continue
            }
            group.enter()
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                defer { group.leave() }
                guard let data = data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                lock.lock()
                collected.append(url)
                lock.unlock()
            }
        }

        group.notify(queue: .main) {
            // Filter to public.movie-conforming files. Anything else
            // gets dropped silently — e.g. dragging a folder or text
            // file in by accident shouldn't add a row.
            let movies = collected.filter { url in
                guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
                return type.conforms(to: .movie)
            }

            if movies.count != collected.count {
                let skipped = collected.count - movies.count
                print("[GlEnc] dropped \(collected.count) URL(s); skipped \(skipped) non-movie")
            }
            for url in movies {
                print("[GlEnc] dropped: \(url.path)")
            }
            queue.addJobs(urls: movies)
        }

        return true
    }
}

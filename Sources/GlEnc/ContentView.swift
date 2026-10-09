// SPDX-License-Identifier: MIT
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import GlEncCore

struct ContentView: View {
    @EnvironmentObject var queue: EncodeQueue
    @State private var isTargeted = false
    // v0.9.2 Phase G.1: the Advanced section's @State properties
    // (refinedBC4Enabled; v1.5.0 dropped ClusterFit) and its DisclosureGroup
    // body relocated to PreferencesWindow.advancedSection. Same
    // session-only behavior (toggles BC4Config.useRefinement on the
    // GlEncCore global; no
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

    // MARK: - Settings bar

    /// Batch-edit — the top settings bar (SettingsBarView): every option a
    /// job card offers. Edits the defaults for new files, or — with ≥2
    /// rows selected — those rows.
    private var defaultsRow: some View {
        SettingsBarView(queue: queue)
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

            // Batch-edit — explicit select-all / collapse so batch editing
            // doesn't depend on the List having keyboard focus.
            if queue.jobs.count >= 2 {
                if queue.selectedJobIDs.count == queue.jobs.count {
                    Button("Select One") { queue.collapseSelectionToPrimary() }
                        .controlSize(.small)
                        .help("Back to a single clip — the top bar edits the defaults again.")
                } else {
                    Button("Select All") { queue.selectAllJobs() }
                        .controlSize(.small)
                        .help("Select every clip so the top bar edits them all (⇧⌘A).")
                }
            }

            if hasCompletedJobs {
                // v1.5.0 (G1) — queue finished clips again (re-run names
                // collide-free as <name>_2, _3, …). ⇧⌘R.
                Button("Reset Finished") {
                    queue.resetAllFinished()
                }
                .controlSize(.small)
                .disabled(queue.isEncoding)
                .help("Queue every finished clip again with its current settings (⇧⌘R). Existing outputs are kept; re-runs write name_2, name_3, …")
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
        // Batch-edit — multi-select: the List binds the full selection
        // set; `selectedJobID` stays the primary row the preview follows.
        List(selection: $queue.selectedJobIDs) {
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
        // v1.5.0 (G1/G2) — right-click on a clip (or the selection).
        .contextMenu(forSelectionType: EncodeJob.ID.self) { ids in
            Button("Reset for Re-run") { queue.resetJobs(ids) }
                .disabled(queue.isEncoding
                          || !queue.jobs.contains { ids.contains($0.id) && $0.isFinished })
        }
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

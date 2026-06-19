// SPDX-License-Identifier: MIT
import SwiftUI
import AppKit
import GlEncCore

/// Phase 7B-a — single-pane Preferences window. Sections grouped by
/// concern: Defaults / Output / Collisions / Format / View / Advanced.
/// Opened via Cmd+, from the app menu (wired in GlEncApp.swift's
/// `.commands` block).
struct PreferencesWindow: View {
    @ObservedObject private var settings: AppSettings = .shared

    // v0.9.2 Phase G.1: mirrors of the two GlEncCore static config
    // flags (BC1Config.useClusterFit / BC4Config.useRefinement),
    // relocated from ContentView. Session-only — these are NOT
    // persisted in AppSettings (the underlying flags are GlEncCore
    // globals that reset to their defaults each app launch, and
    // adding persistence is a separate scope decision).
    @State private var clusterFitEnabled: Bool = BC1Config.useClusterFit
    @State private var refinedBC4Enabled: Bool = BC4Config.useRefinement

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                defaultsSection
                Divider()
                outputSection
                Divider()
                collisionSection
                Divider()
                formatSection
                Divider()
                viewSection
                Divider()
                advancedSection
                Divider()
                resetSection
            }
            .padding(20)
            .frame(width: 520)
        }
        // Phase 7B-b — give the ScrollView an explicit minHeight so the
        // Settings scene (non-resizable, sizes to content's intrinsic
        // height) opens tall enough to show all 5 sections. Without a
        // min, ScrollView reports a small intrinsic height and View +
        // Reset sections fall below the fold.
        .frame(minHeight: 620, maxHeight: 720)
    }

    // MARK: - Sections

    private var defaultsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Defaults for New Jobs")
                .font(.headline)
            Picker("Quality:", selection: $settings.defaultQuality) {
                ForEach(QualityTier.allCases) { tier in
                    Text(tier.label).tag(tier)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 240, alignment: .leading)
            Picker("Alpha:", selection: $settings.defaultAlpha) {
                ForEach(AlphaMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 240, alignment: .leading)
            // Phase 4 — audio defaults for new jobs.
            Toggle("Carry source audio", isOn: $settings.defaultAudioEnabled)
            Picker("Audio rate:", selection: $settings.defaultAudioRate) {
                ForEach(AudioRate.allCases, id: \.self) { r in
                    Text(r.label).tag(r)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 240, alignment: .leading)
            .disabled(!settings.defaultAudioEnabled)
            Text("Applied to new jobs as they're added to the queue. Existing rows keep their own settings.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Output Location")
                .font(.headline)
            Picker("Save to:", selection: $settings.outputLocation) {
                Text("Same folder as source").tag(AppSettings.OutputLocation.sameAsSource)
                Text("Fixed directory").tag(AppSettings.OutputLocation.fixed)
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 280, alignment: .leading)

            if settings.outputLocation == .fixed {
                HStack(spacing: 8) {
                    Text("Folder:")
                    Text(settings.fixedOutputPath.isEmpty
                         ? "(none chosen — encode will fall back to same-as-source)"
                         : settings.fixedOutputPath)
                        .font(.system(size: 12))
                        .foregroundColor(settings.fixedOutputPath.isEmpty ? .orange : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Choose…") { chooseDirectory() }
                }
            }

            Text("If the chosen folder is missing or unwritable at encode time, GlEnc falls back to the source's folder for that job.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    /// v0.9.2 Phase G — what happens when an output filename
    /// collides with an existing file on disk.
    private var collisionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Output File Collisions")
                .font(.headline)
            Picker("When output file exists:",
                   selection: $settings.collisionPolicy) {
                ForEach(AppSettings.CollisionPolicy.allCases) { policy in
                    Text(policy.label).tag(policy)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 360, alignment: .leading)
            Text(collisionPolicyDescription)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var collisionPolicyDescription: String {
        switch settings.collisionPolicy {
        case .ask:
            return "Pause the encode and ask each time a job's output filename already exists. The prompt offers Overwrite / Rename / Skip / Cancel and an option to apply the same choice to every remaining collision in the batch."
        case .overwrite:
            return "Silently replace the existing file. Fastest workflow but lossy if the existing file matters — pick Auto-rename or Ask if you ever care about prior outputs."
        case .autoRename:
            return "Append _2, _3, … before the extension to make a unique filename. Repeated encodes of the same source produce _2, _3, _4 — never overwrites."
        }
    }

    private var formatSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Trim Filename Format")
                .font(.headline)
            Picker("Brackets:", selection: $settings.trimFilenameFormat) {
                Text("Time  [00.00.83-00.03.33]")
                    .tag(AppSettings.TrimFilenameFormat.time)
                Text("Frames  [20-80]")
                    .tag(AppSettings.TrimFilenameFormat.frameIndices)
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 320, alignment: .leading)
            Text("How trim markers render in auto-generated output filenames. Time format reads naturally; frame indices are exact source positions.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var viewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("View")
                .font(.headline)
            Toggle("Show preview pane by default", isOn: $settings.previewPaneVisibleByDefault)
            Text("Applied on app launch. Toggling the pane in-session doesn't change this preference.")
                .font(.caption)
                .foregroundColor(.secondary)
            Toggle("Show clip boundary in preview", isOn: $settings.showClipBoundary)
            Text("Outlines the source frame's edge in the preview — useful for clips whose content extends to a black border.")
                .font(.caption)
                .foregroundColor(.secondary)
            Picker("HAP checkerboard:", selection: $settings.checkerboardScope) {
                ForEach(AppSettings.CheckerboardScope.allCases) { scope in
                    Text(scope.label).tag(scope)
                }
            }
            Text("Transparency checker behind HAP previews. ‘Behind video only’ confines it to the video rect, keeping letterbox bars black.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    /// v0.9.2 Phase G.1 — Advanced encoder tuning, relocated from
    /// the queue column's bottom DisclosureGroup. Session-only flags
    /// that flip GlEncCore's BC1/BC4 endpoint-search algorithms.
    /// Useful for A/B testing or VJs who don't mind a 3-12× encode
    /// slowdown for sub-perceptual quality improvement on saturated
    /// content. Defaults (per v0.5.0 / Phase 5C.5) are FALSE — the
    /// simpler/faster paths.
    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Advanced")
                .font(.headline)
            Toggle("Experimental: ClusterFit BC1 endpoint search",
                   isOn: $clusterFitEnabled)
                .onChange(of: clusterFitEnabled) { _, newValue in
                    BC1Config.useClusterFit = newValue
                }
            Text("Sub-perceptual quality change with significant encode slowdown (4–12× on the BC1 path).")
                .font(.caption)
                .foregroundColor(.secondary)
            Toggle("Experimental: Refined BC4 endpoint search",
                   isOn: $refinedBC4Enabled)
                .onChange(of: refinedBC4Enabled) { _, newValue in
                    BC4Config.useRefinement = newValue
                }
                .padding(.top, 4)
            Text("Sub-perceptual quality change with significant encode slowdown (3× on HQ variants).")
                .font(.caption)
                .foregroundColor(.secondary)
            Text("Session-only — these toggles reset to their defaults when GlEnc relaunches.")
                .font(.caption)
                .foregroundColor(.orange)
                .padding(.top, 2)
        }
    }

    private var resetSection: some View {
        HStack {
            Spacer()
            Button("Reset to Defaults") {
                settings.resetToDefaults()
            }
            .controlSize(.small)
        }
    }

    // MARK: - Helpers

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.title = "Choose Output Folder"
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            settings.fixedOutputPath = url.path
        }
    }
}

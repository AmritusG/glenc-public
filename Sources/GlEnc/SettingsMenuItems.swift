// SPDX-License-Identifier: MIT
import SwiftUI
import GlEncCore

/// v1.5.0 (G2) — the settings menus' items, shared VERBATIM by the top
/// settings bar and the menu bar's Queue ▸ Change Selected / All Clips
/// submenus. Each takes an `apply` closure that routes the edit to its
/// target through `EncodeQueue.applySettings` (the batch-edit path):
/// one place defines the options, two surfaces show them.
struct CodecFamilyMenuItems: View {
    let apply: (EncodeQueue.SettingsEdit) -> Void
    var body: some View {
        ForEach(QualityTier.allCases) { tier in
            Button(tier.label) { apply { s, _ in s.selectDXVTier(tier) } }
        }
        Divider()
        Button("ProRes") { apply { s, alpha in s.selectProRes(sourceHasAlpha: alpha) } }
        Button("H.264") { apply { s, _ in s.selectVideoCodec(.h264) } }
        Button("HEVC") { apply { s, _ in s.selectVideoCodec(.hevc) } }
        Button("Motion JPEG") { apply { s, _ in s.selectVideoCodec(.mjpeg) } }
    }
}

struct AlphaMenuItems: View {
    let apply: (EncodeQueue.SettingsEdit) -> Void
    var body: some View {
        ForEach(AlphaMode.allCases) { mode in
            Button(mode.label) { apply { s, _ in s.setAlpha(mode) } }
        }
    }
}

/// v1.6.0 — the source's "Alpha Type" (Arena's names). Acts on DXV sources
/// with alpha only; stored on every job.
struct SourceAlphaTypeMenuItems: View {
    let apply: (EncodeQueue.SettingsEdit) -> Void
    var body: some View {
        ForEach(SourceAlphaType.allCases, id: \.self) { t in
            Button(t.label) { apply { s, _ in s.setSourceAlphaType(t) } }
        }
    }
}

struct ProResVariantMenuItems: View {
    let apply: (EncodeQueue.SettingsEdit) -> Void
    var body: some View {
        ForEach(ProResVariant.allCases, id: \.self) { v in
            Button(v.label) { apply { s, _ in s.setProResVariant(v) } }
        }
    }
}

struct ContainerMenuItems: View {
    let apply: (EncodeQueue.SettingsEdit) -> Void
    var body: some View {
        ForEach(OutputContainer.allCases, id: \.self) { c in
            Button(c.label) { apply { s, _ in s.setContainer(c) } }
        }
    }
}

struct AudioEnabledMenuItems: View {
    let apply: (EncodeQueue.SettingsEdit) -> Void
    var body: some View {
        Button("Audio: On") { apply { s, _ in s.setAudioEnabled(true) } }
        Button("Audio: Off (strip)") { apply { s, _ in s.setAudioEnabled(false) } }
    }
}

struct AudioRateMenuItems: View {
    let targets: [JobSettings]
    let apply: (EncodeQueue.SettingsEdit) -> Void
    var body: some View {
        ForEach(AudioRate.allCases, id: \.self) { r in
            Button(r.label) { apply { s, _ in s.setAudioRate(r) } }
                .disabled(!targets.isEmpty && targets.allSatisfy { $0.audioRateUnavailable(r) })
        }
        if targets.contains(where: { $0.outputContainer.usesAACAudio }) {
            Divider()
            Text("MPEG-4 (AAC) caps at 48 kHz")
        }
    }
}

struct ResizeQualityMenuItems: View {
    let apply: (EncodeQueue.SettingsEdit) -> Void
    var body: some View {
        ForEach(ResizeQuality.allCases, id: \.self) { q in
            Button(q.displayLabel) { apply { s, _ in s.setResizeQuality(q) } }
        }
    }
}

struct AspectMenuItems: View {
    let apply: (EncodeQueue.SettingsEdit) -> Void
    var body: some View {
        ForEach(AspectMode.allCases, id: \.self) { m in
            Button(m.displayLabel) { apply { s, _ in s.setAspectMode(m) } }
        }
    }
}

/// The whole settings menu set as submenus — Queue ▸ Change Selected Clips
/// / Change All Clips. Edits go to `ids` through `applySettings`, which
/// skips locked rows (encoding / done) and applies each setting only where
/// it applies, exactly as the settings bar's batch edit.
struct QueueSettingsSubmenus: View {
    @ObservedObject var queue: EncodeQueue
    @ObservedObject var settings: AppSettings
    let ids: [EncodeJob.ID]

    private var targets: [JobSettings] {
        let set = Set(ids)
        return queue.jobs.filter { set.contains($0.id) }.map(\.settings)
    }
    private func apply(_ e: EncodeQueue.SettingsEdit) { queue.applySettings(to: ids, e) }

    var body: some View {
        Menu("Codec") { CodecFamilyMenuItems(apply: apply) }
        Menu("Alpha (DXV / HAP)") { AlphaMenuItems(apply: apply) }
        Menu("Source Alpha Type (DXV sources)") { SourceAlphaTypeMenuItems(apply: apply) }
        Menu("ProRes Variant") { ProResVariantMenuItems(apply: apply) }
        Menu("Container (H.264 / HEVC)") { ContainerMenuItems(apply: apply) }
        Divider()
        Menu("Audio") { AudioEnabledMenuItems(apply: apply) }
        Menu("Audio Rate") { AudioRateMenuItems(targets: targets, apply: apply) }
        Divider()
        Menu("Size") {
            OutputSizeMenuItems(settings: settings,
                                originalLabel: OutputSizeMenuItems.originalLabel(for: queue.jobs.filter { ids.contains($0.id) }),
                                onSelect: { size in apply { s, _ in s.setOutputSize(size) } })
        }
        Menu("Resize Quality") { ResizeQualityMenuItems(apply: apply) }
        Menu("Aspect") { AspectMenuItems(apply: apply) }
    }
}

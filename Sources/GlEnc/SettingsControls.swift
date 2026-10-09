// SPDX-License-Identifier: MIT
import SwiftUI
import GlEncCore

/// Batch-edit — control pieces shared VERBATIM by the job card and the
/// top settings bar, so the two surfaces offer the same options with the
/// same look. Each takes the settings it displays plus an `apply`
/// closure that routes an edit to its target (one job, the selection,
/// or the defaults for new files).

/// H.264/HEVC rate-control knobs: a mode toggle (Quality / Bitrate) +
/// the active control, keyframe interval, the H.264 profile (H.264
/// only), and the container. Emits sibling rows (no container) so it
/// lays out inside the caller's VStack exactly as before.
struct VideoAdvancedControls: View {
    let settings: JobSettings
    let apply: (EncodeQueue.SettingsEdit) -> Void

    private enum RateControlMode { case quality, bitrate }

    private var currentQuality: Double {
        if case .quality(let q) = settings.videoSettings.rateControl { return q }
        return 0.6
    }
    private var currentBitrateMbps: Double {
        if case .bitrate(let m) = settings.videoSettings.rateControl { return m }
        return 10
    }

    var body: some View {
        Picker("Rate control:", selection: Binding(
            get: { settings.videoSettings.rateControl.isQuality ? RateControlMode.quality : .bitrate },
            set: { mode in apply { s, _ in s.setRateControlMode(quality: mode == .quality) } })) {
            Text("Quality").tag(RateControlMode.quality)
            Text("Bitrate").tag(RateControlMode.bitrate)
        }
        .pickerStyle(.segmented)

        if settings.videoSettings.rateControl.isQuality {
            HStack(spacing: 8) {
                Text("Quality:")
                Slider(value: Binding(get: { currentQuality },
                                      set: { v in apply { s, _ in s.setQuality(v) } }),
                       in: 0.1...1.0)
                Text(String(format: "%.2f", currentQuality))
                    .font(.caption).monospacedDigit()
                    .frame(width: 34, alignment: .trailing)
            }
        } else {
            HStack(spacing: 8) {
                Text("Bitrate:")
                TextField("Mbps", value: Binding(get: { currentBitrateMbps },
                                                 set: { v in apply { s, _ in s.setBitrateMbps(v) } }),
                          format: .number)
                    .frame(width: 64)
                Text("Mbps")
                    .font(.caption).foregroundColor(.secondary)
            }
        }

        HStack(spacing: 8) {
            Text("Keyframe interval:")
            TextField("frames", value: Binding(get: { settings.videoSettings.keyframeIntervalFrames },
                                               set: { v in apply { s, _ in s.setKeyframeInterval(v) } }),
                      format: .number)
                .frame(width: 56)
            Text("frames (0 = auto)")
                .font(.caption).foregroundColor(.secondary)
        }

        if settings.outputCodec == .h264 {
            Picker("Profile:", selection: Binding(
                get: { settings.videoSettings.h264Profile },
                set: { p in apply { s, _ in s.setH264Profile(p) } })) {
                ForEach(VideoEncodeSettings.H264Profile.allCases, id: \.self) { p in
                    Text(p.label).tag(p)
                }
            }
            .pickerStyle(.menu)
        }

        Picker("Container:", selection: Binding(
            get: { settings.outputContainer },
            set: { c in apply { s, _ in s.setContainer(c) } })) {
            ForEach(settings.outputCodec.allowedContainers, id: \.self) { c in
                Text(c.label).tag(c)
            }
        }
        .pickerStyle(.menu)

        Text(settings.outputCodec == .hevc
             ? "HEVC encodes opaque this version (alpha support is upcoming)."
             : "H.264 — the universal-delivery codec.")
            .font(.caption)
            .foregroundColor(.secondary)
    }
}

/// The Output Size menu's items: Original, My Sizes, the preset
/// sections, Custom…, Manage Sizes…. Used inside a `Menu { }`.
struct OutputSizeMenuItems: View {
    @ObservedObject var settings: AppSettings
    /// v1.5.0 (G3) — the Original item's text: "Original (1920×1080)",
    /// "Original (mixed)" or plain "Original" (see `originalLabel(for:)`).
    var originalLabel: String = "Original"
    let onSelect: (OutputSize) -> Void
    /// Custom… / Manage Sizes… open sheets; nil hides them (the menu bar's
    /// Queue ▸ Change … ▸ Size has no sheet to open).
    var onCustom: (() -> Void)? = nil
    var onManage: (() -> Void)? = nil

    var body: some View {
        Button(originalLabel) { onSelect(.original) }
        // Phase H — user-named presets at the top of the menu (per
        // RESIZE_PLAN.md Q5). Only when non-empty.
        if !settings.customPresets.isEmpty {
            Section("My Sizes") {
                ForEach(settings.customPresets) { preset in
                    Button(preset.displayLabel) {
                        onSelect(.custom(width: preset.width, height: preset.height))
                    }
                }
            }
        }
        Section("HD / UHD") {
            preset(.hd_1280_720)
            preset(.fhd_1920_1080)
            preset(.qhd_2560_1440)
            preset(.uhd_3840_2160)
        }
        Section("DCI Cinema") {
            preset(.dci_2048_1080)
            preset(.dci_4096_2160)
        }
        Section("Square") {
            preset(.sq_1024)
            preset(.sq_1080)
            preset(.sq_2048)
        }
        Section("Vertical") {
            preset(.v_720_1280)
            preset(.v_1080_1920)
            preset(.v_1440_2560)
        }
        if let onCustom {
            Divider()
            Button("Custom…") { onCustom() }
        }
        // Phase H — Manage Sizes only when there's something to manage.
        if let onManage, !settings.customPresets.isEmpty {
            Button("Manage Sizes…") { onManage() }
        }
    }

    private func preset(_ p: StandardResolution) -> some View {
        Button(p.displayLabel) { onSelect(.preset(p)) }
    }

    /// Compact collapsed-menu label ("1920×1080" rather than the full
    /// preset displayLabel).
    static func label(_ size: OutputSize, original: String = "Original") -> String {
        switch size {
        case .original:
            return original
        case .preset(let p):
            let (w, h) = p.dimensions
            return "\(w)×\(h)"
        case .custom(let w, let h):
            return "Custom \(w)×\(h)"
        }
    }
}

extension OutputSizeMenuItems {
    /// v1.5.0 (G3) — "Original (W×H)" with the size `.original` encodes at
    /// (`EncodeJob.effectiveSourceSize`: the crop rect when cropped, else
    /// the probed source). Several jobs: their common size, or
    /// "Original (mixed)" when they differ. No job, or none probed yet:
    /// plain "Original" (the defaults for new files have no source).
    static func originalLabel(for jobs: [EncodeJob]) -> String {
        let sizes = jobs.compactMap(\.effectiveSourceSize)
        guard let first = sizes.first else { return "Original" }
        if sizes.contains(where: { $0 != first }) { return "Original (mixed)" }
        return "Original (\(first.width)×\(first.height))"
    }
}

/// Custom 1–64 HAP chunk tap-stepper. Draws the SAME combined
/// `chevron.up.chevron.down` glyph the codec row's menus use.
///
/// To inherit the menu's control box by construction rather than faking
/// it with a tuned frame/font, the chevron is the label of a borderless
/// `Button` — the same borderless-control context (controlSize
/// `.regular`) the codec `Menu` (`.menuStyle(.borderlessButton)`)
/// renders in. The Button is `.allowsHitTesting(false)`, so it
/// contributes ONLY layout (the box) and can never swallow the tap; the
/// two `onTapGesture` zones live in an `.overlay` added afterwards, so
/// they stay hit-testable and drive +1 / -1. The number sits in a
/// fixed-width monospaced-digit slot so the chevron doesn't shift
/// sideways (1 vs 64).
struct HapChunksStepper: View {
    /// "4", or "–" for a mixed selection.
    let valueText: String
    let onIncrement: () -> Void
    let onDecrement: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text("Chunks:")
            Text(valueText)
                .monospacedDigit()
                .frame(width: 18, alignment: .trailing)
            Button(action: {}) {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 12))
                    .foregroundColor(.white)
            }
            .buttonStyle(.borderless)
            .allowsHitTesting(false)        // box only — never grabs the tap
            .overlay(
                VStack(spacing: 0) {
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture { onIncrement() }
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture { onDecrement() }
                }
            )
        }
        .fixedSize()
        .help("HAP chunked-section count (1–64). 1 = single section. Higher splits each frame into more independently-decodable chunks for parallel GPU upload.")
    }
}

// SPDX-License-Identifier: MIT
import Foundation
import GlEncCore

/// Batch-edit — the complete set of per-clip encode settings a job card
/// (and the top settings bar) can change. One value type, one set of
/// rules: the job card, the batch "apply to selection" path, and the
/// defaults for new files all mutate a `JobSettings` through the SAME
/// mutating methods below, so single-edit, batch-edit and defaults
/// can't diverge.
///
/// Deliberately excluded (per-source, not batchable, no default):
/// crop, trim, output name.
///
/// Every method is "apply where applicable": a setting that doesn't
/// make sense for the current codec (HAP chunks on a DXV3 clip, ProRes
/// variant on an H.264 clip, …) is a no-op, so a batch over a
/// mixed-codec selection only touches the clips it applies to.
struct JobSettings: Equatable, Codable {
    var format: DXVFormat = .dxt1
    var outputCodec: OutputCodec = .dxv(.dxt1)
    var outputContainer: OutputContainer = .mov
    var videoSettings: VideoEncodeSettings = .default
    var hapChunks: Int = 1
    var audioEnabled: Bool = true
    var audioRate: AudioRate = .original
    var outputSize: OutputSize = .original
    var resizeQuality: ResizeQuality = .auto
    var aspectMode: AspectMode = .letterbox
    /// v1.6.0 — what a DXV source's colour is (Arena's "Alpha Type",
    /// default Premultiplied). Stored for every job; it only acts on DXV
    /// sources with alpha (their files do not say) — the reader
    /// un-premultiplies on read. Other sources are read as their format
    /// states and show the control disabled.
    var sourceAlphaType: SourceAlphaType = .default

    // MARK: - Applicability predicates (drive both UI gating and no-ops)

    var isDXVFamily: Bool { if case .dxv = outputCodec { return true }; return false }
    var isHAP: Bool { isDXVFamily && format.family == .hap }
    var isProRes: Bool { outputCodec.proResVariant != nil }
    var isH264OrHEVC: Bool { outputCodec == .h264 || outputCodec == .hevc }
    var isOriginalSize: Bool { if case .original = outputSize { return true }; return false }

    /// UI family label shared by the card and the settings bar.
    var codecFamilyLabel: String {
        switch outputCodec {
        case .dxv:    return format.qualityTier.label
        case .prores: return "ProRes"
        case .h264:   return "H.264"
        case .hevc:   return "HEVC"
        case .mjpeg:  return "Motion JPEG"
        }
    }

    // MARK: - Codec family

    /// Select a DXV/HAP family tier. Keeps the current alpha mode (read
    /// from `format`, which still holds the last DXV selection even while
    /// another codec is active) and re-points `outputCodec` at `.dxv`.
    mutating func selectDXVTier(_ tier: QualityTier) {
        let newFormat = DXVFormat(tier: tier, alpha: format.alphaMode)
        format = newFormat
        outputCodec = .dxv(newFormat)
        outputContainer = .mov
    }

    /// Switch to ProRes. Alpha steering: an alpha source → 4444, else
    /// 422. When the source-alpha probe hasn't resolved (`nil`) fall back
    /// to the DXV alpha intent.
    mutating func selectProRes(sourceHasAlpha: Bool?) {
        let alpha = sourceHasAlpha ?? format.hasAlpha
        outputCodec = .prores(alpha ? .proRes4444 : .proRes422)
        outputContainer = .mov
    }

    /// Switch to H.264 / HEVC / Motion JPEG. Container defaults to `.mp4`
    /// where allowed (broad delivery), else `.mov`.
    mutating func selectVideoCodec(_ codec: OutputCodec) {
        outputCodec = codec
        outputContainer = codec.allowedContainers.contains(.mp4) ? .mp4 : .mov
        clampAudioRateToContainer()
    }

    // MARK: - Second menu: alpha / ProRes variant / container

    /// DXV/HAP only. Keeps `outputCodec` in lockstep with `format` — the
    /// encoder dispatches on `outputCodec`'s `.dxv(format)` payload.
    mutating func setAlpha(_ alpha: AlphaMode) {
        guard isDXVFamily else { return }
        let newFormat = DXVFormat(tier: format.qualityTier, alpha: alpha)
        format = newFormat
        outputCodec = .dxv(newFormat)
    }

    /// ProRes only.
    mutating func setProResVariant(_ v: ProResVariant) {
        guard isProRes else { return }
        outputCodec = .prores(v)
    }

    /// Only containers the codec allows (H.264/HEVC: .mov/.mp4).
    mutating func setContainer(_ c: OutputContainer) {
        guard outputCodec.allowedContainers.contains(c) else { return }
        outputContainer = c
        clampAudioRateToContainer()
    }

    // MARK: - H.264 / HEVC advanced

    mutating func setRateControlMode(quality: Bool) {
        guard isH264OrHEVC else { return }
        guard quality != videoSettings.rateControl.isQuality else { return }
        videoSettings.rateControl = quality ? .quality(0.6) : .bitrate(10)
    }
    mutating func setQuality(_ q: Double) {
        guard isH264OrHEVC else { return }
        videoSettings.rateControl = .quality(min(1, max(0.1, q)))
    }
    mutating func setBitrateMbps(_ mbps: Double) {
        guard isH264OrHEVC else { return }
        videoSettings.rateControl = .bitrate(max(0.1, mbps))
    }
    mutating func setKeyframeInterval(_ frames: Int) {
        guard isH264OrHEVC else { return }
        videoSettings.keyframeIntervalFrames = max(0, frames)
    }
    /// H.264 only (HEVC has no profile knob).
    mutating func setH264Profile(_ p: VideoEncodeSettings.H264Profile) {
        guard outputCodec == .h264 else { return }
        videoSettings.h264Profile = p
    }

    // MARK: - HAP chunks

    /// HAP family only; clamped 1…64.
    mutating func setHapChunks(_ n: Int) {
        guard isHAP else { return }
        hapChunks = min(64, max(1, n))
    }

    // MARK: - Audio

    mutating func setAudioEnabled(_ on: Bool) { audioEnabled = on }

    /// A rate the container can't carry (AAC/.mp4 > 48 kHz) is clamped
    /// to 48 kHz rather than silently stored.
    mutating func setAudioRate(_ r: AudioRate) {
        audioRate = r
        clampAudioRateToContainer()
    }

    /// Keeps displayed == actual: a >48 kHz rate on an AAC container
    /// becomes 48 kHz.
    mutating func clampAudioRateToContainer() {
        if let hz = audioRate.hz, hz > outputContainer.maxAudioSampleRate {
            audioRate = .hz48000
        }
    }

    func audioRateUnavailable(_ r: AudioRate) -> Bool {
        guard let hz = r.hz else { return false }
        return hz > outputContainer.maxAudioSampleRate
    }

    // MARK: - Source alpha type

    mutating func setSourceAlphaType(_ t: SourceAlphaType) { sourceAlphaType = t }

    // MARK: - Resize

    mutating func setOutputSize(_ s: OutputSize) { outputSize = s }
    mutating func setResizeQuality(_ q: ResizeQuality) { resizeQuality = q }
    mutating func setAspectMode(_ m: AspectMode) { aspectMode = m }

    /// True when a change to these settings alters the AutoName output
    /// (codec / format / container feed the filename; the rest don't).
    func affectsAutoName(comparedTo other: JobSettings) -> Bool {
        format != other.format
            || outputCodec != other.outputCodec
            || outputContainer != other.outputContainer
    }
}

extension EncodeJob {
    /// The batchable settings subset, read/written as one value.
    var settings: JobSettings {
        get {
            JobSettings(format: format,
                        outputCodec: outputCodec,
                        outputContainer: outputContainer,
                        videoSettings: videoSettings,
                        hapChunks: hapChunks,
                        audioEnabled: audioEnabled,
                        audioRate: audioRate,
                        outputSize: outputSize,
                        resizeQuality: resizeQuality,
                        aspectMode: aspectMode,
                        sourceAlphaType: sourceAlphaType)
        }
        set {
            format = newValue.format
            outputCodec = newValue.outputCodec
            outputContainer = newValue.outputContainer
            videoSettings = newValue.videoSettings
            hapChunks = newValue.hapChunks
            audioEnabled = newValue.audioEnabled
            audioRate = newValue.audioRate
            outputSize = newValue.outputSize
            resizeQuality = newValue.resizeQuality
            aspectMode = newValue.aspectMode
            sourceAlphaType = newValue.sourceAlphaType
        }
    }
}

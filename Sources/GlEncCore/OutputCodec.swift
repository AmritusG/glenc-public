// SPDX-License-Identifier: MIT
import Foundation
import AVFoundation

/// The parent codec type the queue/UI select.
/// `.dxv` routes through the legacy `FrameEncoder` + VariantMOVWriter
/// path (byte-identical — `EncodeJob.outputCodec` defaults to
/// `.dxv(format)` so existing behavior is untouched). `.prores`,
/// `.h264`, `.hevc`, and `.mjpeg` all route through
/// `AVAssetWriterVideoSink` (VideoToolbox). Every codec is implemented
/// and reaches dispatch.
public enum OutputCodec: Hashable, Sendable, Codable {
    /// DXV3 (DXT1/DXT5/YCG6/YG10) or HAP (Hap1/Hap5/HapY/HapM) — both
    /// carried by `DXVFormat`; both use the hand-rolled MOV writer.
    case dxv(DXVFormat)
    case prores(ProResVariant)
    case h264
    case hevc
    case mjpeg

    /// True for the codecs wired to an encoder. Phase 3 made Motion JPEG
    /// live — every codec in the model is now implemented.
    public var isImplemented: Bool {
        switch self {
        case .dxv, .prores, .h264, .hevc, .mjpeg: return true
        }
    }

    /// True when the codec has tunable Advanced-popover settings the
    /// job card's codec row does NOT already expose. H.264/HEVC carry
    /// rate-control / keyframe / profile / container knobs → true.
    /// DXV/HAP have none; ProRes's only choice (variant) is already the
    /// row's 2nd menu and its container is .mov-locked → false. Drives
    /// whether the "Advanced" trigger is shown.
    public var hasAdvancedSettings: Bool {
        switch self {
        case .h264, .hevc: return true
        case .dxv, .prores, .mjpeg: return false
        }
    }

    /// Caller-side dimension alignment a crop/resize must satisfy for
    /// this codec — verified empirically (an odd-vs-even-non-4 probe):
    ///   - H.264 / HEVC → 2 (4:2:0 chroma needs even dims; VideoToolbox
    ///     SILENTLY rounds odd dims down, e.g. 1921→1920, so we require
    ///     even to keep output == requested).
    ///   - DXV3 / HAP → 1 (pad their coded raster internally + zero-fill;
    ///     presentation dims are exact for any value).
    ///   - ProRes / MJPEG → 1 (VideoToolbox produces the exact dims).
    /// The uniform 4-px rule the pipeline used before over-constrained
    /// every codec; this replaces it. Crop OFFSET needs no alignment for
    /// any codec (FrameCropper extracts exact pixels).
    public var dimensionAlignment: Int {
        switch self {
        case .h264, .hevc: return 2
        case .dxv, .prores, .mjpeg: return 1
        }
    }

    /// AVVideoCodecType for the VideoToolbox-routed codecs (ProRes is
    /// carried by the variant; this covers H.264 / HEVC / Motion JPEG).
    /// nil for the DXV/HAP path.
    public var videoToolboxCodec: AVVideoCodecType? {
        switch self {
        case .h264:  return .h264
        case .hevc:  return .hevc
        case .mjpeg: return .jpeg
        default:     return nil
        }
    }

    /// The DXV/HAP format when this is a `.dxv` codec, else nil. Lets
    /// the existing `format`-keyed code (preview, AutoName DXV branch,
    /// the DXV submenu) keep working unchanged on the `.dxv` path.
    public var dxvFormat: DXVFormat? {
        if case .dxv(let f) = self { return f }
        return nil
    }

    public var proResVariant: ProResVariant? {
        if case .prores(let v) = self { return v }
        return nil
    }

    /// Whether the selected codec carries an alpha channel in its
    /// output. Drives the alpha-steering note.
    public var hasAlpha: Bool {
        switch self {
        case .dxv(let f):     return f.hasAlpha
        case .prores(let v):  return v.hasAlpha
        case .h264, .hevc, .mjpeg: return false
        }
    }

    /// Containers the codec may be muxed into. ProRes (and DXV/HAP, and
    /// MJPEG) → QuickTime only; H.264/HEVC also allow `.mp4`. The picker
    /// offers only these; ProRes never offers .mp4.
    public var allowedContainers: [OutputContainer] {
        switch self {
        case .dxv, .prores, .mjpeg: return [.mov]
        case .h264, .hevc:          return [.mov, .mp4]
        }
    }
}

/// Output container choice. DXV/HAP, ProRes, and MJPEG use `.mov`;
/// H.264/HEVC can also target `.mp4`.
public enum OutputContainer: String, CaseIterable, Hashable, Sendable, Codable {
    case mov
    case mp4

    public var fileType: AVFileType { self == .mov ? .mov : .mp4 }
    public var ext: String { rawValue }
    public var label: String {
        self == .mov ? "QuickTime (.mov)" : "MPEG-4 (.mp4)"
    }

    /// `.mp4` muxes audio as AAC (AVAssetWriter); `.mov` uses LPCM. The
    /// AVFoundation AAC encoder rejects sample rates > 48 kHz on this
    /// platform (`canApply` returns false), so the audio rate must be
    /// capped to 48 kHz for AAC — the single source of truth used by both
    /// the rate-menu UI (disable >48k) and the encode clamp (resample down).
    public var usesAACAudio: Bool { self == .mp4 }

    /// Max audio sample rate this container can carry (AAC caps at 48 kHz;
    /// LPCM/.mov has no practical cap here).
    public var maxAudioSampleRate: Int { usesAACAudio ? 48_000 : Int.max }
}
